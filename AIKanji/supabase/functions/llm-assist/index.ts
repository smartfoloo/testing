// llm-assist — two modes:
//   parse   normalizes a participant's free-text MUST/WANT into a typed constraint.
//   explain writes a grounded explanation for one recommended restaurant.
//
// The LLM key never leaves the server: set it with `supabase secrets set LLM_API_KEY=...`.
// The client only ever calls this function.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const LLM_API_KEY = Deno.env.get("LLM_API_KEY") ?? "";
const LLM_BASE_URL = Deno.env.get("LLM_BASE_URL") ??
  "https://api.openai.com/v1";
const LLM_MODEL = Deno.env.get("LLM_MODEL") ?? "gpt-4o-mini";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const NORMALIZED_TYPES = [
  "budget",
  "cuisine",
  "dietary",
  "allergy",
  "smoking",
  "room",
  "travel_time",
  "accessibility",
  "atmosphere",
  "other",
] as const;

const SENSITIVE_TYPES = ["allergy", "dietary", "accessibility"] as const;

type NormalizedType = (typeof NORMALIZED_TYPES)[number];
type Visibility = "PUBLIC" | "ANONYMOUS";

interface ParseResult {
  normalized_type: NormalizedType;
  normalized_value: Record<string, unknown>;
  suggested_visibility: Visibility;
  confidence: number;
  needs_clarification: boolean;
}

/// Returned whenever the model output cannot be trusted; the human corrects it in the UI.
const FALLBACK: ParseResult = {
  normalized_type: "other",
  normalized_value: {},
  suggested_visibility: "PUBLIC",
  confidence: 0,
  needs_clarification: true,
};

const SYSTEM_PROMPT =
  `You normalize a single restaurant-outing requirement written by a member of a Tokyo coworker group.

Reply with JSON only, exactly these five keys and nothing else:
{"normalized_type": one of ${NORMALIZED_TYPES.join("|")},
 "normalized_value": object,
 "suggested_visibility": "PUBLIC" or "ANONYMOUS",
 "confidence": number between 0 and 1,
 "needs_clarification": boolean}

normalized_value shape by type:
  budget       {"max_yen": number} or {"min_yen": number, "max_yen": number}
  cuisine      {"include": string[], "exclude": string[]}
  dietary      {"tags": string[]}          e.g. ["vegetarian","halal"]
  allergy      {"allergens": string[]}
  smoking      {"preference": "non_smoking"|"smoking_ok"}
  room         {"type": "private"|"semi_private"|"open"}
  travel_time  {"max_minutes": number}
  accessibility{"needs": string[]}         e.g. ["step_free","wheelchair"]
  atmosphere   {"tags": string[]}          e.g. ["quiet","lively"]
  other        {}

Set needs_clarification true when the text is empty, ambiguous, or you cannot fill the shape.
Suggest ANONYMOUS for allergy, dietary and accessibility; PUBLIC otherwise.
The text may be Japanese or English.`;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// Fail-closed validator: wrong types, missing keys or hallucinated extra keys all reject.
function validate(candidate: unknown): ParseResult | null {
  if (!isPlainObject(candidate)) return null;

  const expected = [
    "normalized_type",
    "normalized_value",
    "suggested_visibility",
    "confidence",
    "needs_clarification",
  ];
  const keys = Object.keys(candidate);
  if (keys.length !== expected.length) return null;
  if (!expected.every((key) => keys.includes(key))) return null;

  const {
    normalized_type,
    normalized_value,
    suggested_visibility,
    confidence,
    needs_clarification,
  } = candidate;

  if (typeof normalized_type !== "string") return null;
  if (!(NORMALIZED_TYPES as readonly string[]).includes(normalized_type)) {
    return null;
  }
  if (!isPlainObject(normalized_value)) return null;
  if (
    suggested_visibility !== "PUBLIC" && suggested_visibility !== "ANONYMOUS"
  ) return null;
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) {
    return null;
  }
  if (confidence < 0 || confidence > 1) return null;
  if (typeof needs_clarification !== "boolean") return null;

  return {
    normalized_type: normalized_type as NormalizedType,
    normalized_value,
    suggested_visibility,
    confidence,
    needs_clarification,
  };
}

/// Sensitive categories default to ANONYMOUS; the client can still override before saving.
function applyDefaultVisibility(result: ParseResult): ParseResult {
  if ((SENSITIVE_TYPES as readonly string[]).includes(result.normalized_type)) {
    return { ...result, suggested_visibility: "ANONYMOUS" };
  }
  return result;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function chat(
  systemPrompt: string,
  userPrompt: string,
  jsonMode = false,
): Promise<string> {
  const response = await fetch(`${LLM_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${LLM_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      temperature: 0,
      ...(jsonMode ? { response_format: { type: "json_object" } } : {}),
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
    }),
  });

  if (!response.ok) throw new Error(`LLM HTTP ${response.status}`);
  const body = await response.json();
  const content = body?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || content.trim() === "") {
    throw new Error("LLM returned no content");
  }
  return content.trim();
}

async function callModel(
  rawText: string,
  kind: string,
  language: string,
): Promise<unknown> {
  return JSON.parse(
    await chat(
      SYSTEM_PROMPT,
      `kind: ${kind}\nlanguage: ${language}\ntext: ${rawText}`,
      true,
    ),
  );
}

// --- explain mode ----------------------------------------------------------

const EXPLAIN_SYSTEM_PROMPT =
  `You write one short recommendation blurb for a Tokyo coworker group choosing a restaurant.

You are given a JSON object of verified facts about one candidate. Use only those facts:
never invent a name, dish, price, review, station, cuisine or amenity that is not in the JSON.
An empty tag array means "unverified", never "confirmed". Do not restate raw score numbers.
Reply with 1-2 plain sentences, at most 45 words, no markdown, no quotes.`;

interface Grounding {
  label: string | null;
  fairness_score: number | null;
  satisfaction_score: number | null;
  quality_score: number | null;
  price_yen_estimate: number | null;
  room_type: string | null;
  cuisine_tags: string[];
  dietary_tags: string[];
  allergy_safe_tags: string[];
  atmosphere_tags: string[];
  travel_minutes: number[];
  group_wants: { normalized_type: string; normalized_value: unknown }[];
}

interface ScoreRow {
  id: string;
  label: string | null;
  fairness_score: number | null;
  satisfaction_score: number | null;
  quality_score: number | null;
}

interface FeatureRow {
  price_yen_estimate: number | null;
  room_type: string | null;
  cuisine_tags: string[] | null;
  dietary_tags: string[] | null;
  allergy_safe_tags: string[] | null;
  atmosphere_tags: string[] | null;
  travel_minutes_by_participant: Record<string, unknown> | null;
}

interface WantRow {
  normalized_type: string;
  normalized_value: unknown;
}

const LABEL_PHRASES: Record<string, string> = {
  fairest: "the most balanced choice for the group",
  best_access: "the easiest to reach for everyone",
  best_value: "the best value for the budget",
  best_experience: "the most memorable setting",
  crowd_pleaser: "the option matching the most preferences",
};

/// Deterministic blurb from the same grounding data, used when the model is
/// unavailable so a card never renders without an explanation.
function fallbackExplanation(g: Grounding): string {
  const parts: string[] = [];
  if (g.price_yen_estimate !== null) {
    parts.push(`around ¥${g.price_yen_estimate} per person`);
  }
  if (g.room_type) parts.push(`${g.room_type.replace("_", " ")} seating`);
  if (g.atmosphere_tags.length > 0) {
    parts.push(`${g.atmosphere_tags.join(", ")} atmosphere`);
  }
  if (g.travel_minutes.length > 0) {
    parts.push(`${Math.max(...g.travel_minutes)} min at worst to get there`);
  }

  const lead = g.label && LABEL_PHRASES[g.label]
    ? `Picked as ${LABEL_PHRASES[g.label]}`
    : "Meets every stated requirement";
  return parts.length > 0 ? `${lead}: ${parts.join(", ")}.` : `${lead}.`;
}

/// Grounding is fetched server-side with the service-role key. The request body
/// contributes only identifiers — a client-supplied evidence blob could make the
/// model assert anything, which would defeat the point of a grounded explanation.
async function loadGrounding(
  admin: SupabaseClient,
  runId: string,
  placeId: string,
): Promise<{ grounding: Grounding; scoreId: string } | null> {
  const { data: score } = await admin
    .from("recommendation_scores")
    .select("id, label, fairness_score, satisfaction_score, quality_score")
    .eq("run_id", runId)
    .eq("restaurant_place_id", placeId)
    .returns<ScoreRow[]>()
    .maybeSingle();
  if (!score) return null;

  const { data: run } = await admin
    .from("recommendation_runs")
    .select("event_id")
    .eq("id", runId)
    .returns<{ event_id: string }[]>()
    .maybeSingle();
  if (!run) return null;

  const { data: features } = await admin
    .from("restaurant_features")
    .select(
      "price_yen_estimate, room_type, cuisine_tags, dietary_tags, allergy_safe_tags, atmosphere_tags, travel_minutes_by_participant",
    )
    .eq("place_id", placeId)
    .returns<FeatureRow[]>()
    .maybeSingle();
  if (!features) return null;

  // WANT rows only: a MUST is already guaranteed by feasibility, and its raw text
  // can carry the private detail (allergy, diet) that must not reach the model.
  const { data: wants } = await admin
    .from("participant_constraints")
    .select("normalized_type, normalized_value")
    .eq("event_id", run.event_id)
    .eq("kind", "WANT")
    .returns<WantRow[]>();

  const travel = features.travel_minutes_by_participant ?? {};
  return {
    scoreId: score.id,
    grounding: {
      label: score.label,
      fairness_score: score.fairness_score,
      satisfaction_score: score.satisfaction_score,
      quality_score: score.quality_score,
      price_yen_estimate: features.price_yen_estimate,
      room_type: features.room_type,
      cuisine_tags: features.cuisine_tags ?? [],
      dietary_tags: features.dietary_tags ?? [],
      allergy_safe_tags: features.allergy_safe_tags ?? [],
      atmosphere_tags: features.atmosphere_tags ?? [],
      travel_minutes: Object.values(travel).map(Number).filter(
        Number.isFinite,
      ),
      group_wants: (wants ?? []).filter((want) =>
        want.normalized_type === "cuisine" ||
        want.normalized_type === "atmosphere"
      ),
    },
  };
}

async function handleExplain(
  req: Request,
  runId: string,
  placeId: string,
): Promise<Response> {
  const authorization = req.headers.get("Authorization") ?? "";
  if (authorization === "") {
    return json({ error: "missing authorization" }, 401);
  }

  // The caller must be able to see the run under RLS, i.e. be a participant of its event.
  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: visibleRun } = await caller
    .from("recommendation_runs")
    .select("id")
    .eq("id", runId)
    .maybeSingle();
  if (!visibleRun) return json({ error: "run not found" }, 403);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const loaded = await loadGrounding(admin, runId, placeId);
  if (!loaded) return json({ error: "no score row for this run" }, 404);

  let explanation = fallbackExplanation(loaded.grounding);
  if (LLM_API_KEY !== "") {
    try {
      explanation = await chat(
        EXPLAIN_SYSTEM_PROMPT,
        JSON.stringify(loaded.grounding),
      );
    } catch (error) {
      console.error("llm-assist explain failed", error);
    }
  }

  await admin
    .from("recommendation_scores")
    .update({ explanation })
    .eq("id", loaded.scoreId);

  return json({ explanation });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let request: Record<string, unknown>;
  try {
    request = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const { mode, raw_text, kind, language, run_id, restaurant_place_id } =
    request;

  if (mode === "explain") {
    if (typeof run_id !== "string" || typeof restaurant_place_id !== "string") {
      return json(
        { error: "run_id and restaurant_place_id are required" },
        400,
      );
    }
    return await handleExplain(req, run_id, restaurant_place_id);
  }

  if (mode !== "parse") return json({ error: "unsupported mode" }, 400);
  if (typeof raw_text !== "string") {
    return json({ error: "raw_text must be a string" }, 400);
  }
  if (kind !== "MUST" && kind !== "WANT") {
    return json({ error: "kind must be MUST or WANT" }, 400);
  }
  if (language !== "ja" && language !== "en") {
    return json({ error: "language must be ja or en" }, 400);
  }

  if (raw_text.trim() === "" || LLM_API_KEY === "") return json(FALLBACK);

  // A malformed model response is a parsing outcome, not a server error: always answer 200
  // with the fallback so the client can ask the human instead of crashing or retrying blindly.
  try {
    const validated = validate(await callModel(raw_text, kind, language));
    return json(validated ? applyDefaultVisibility(validated) : FALLBACK);
  } catch (error) {
    console.error("llm-assist parse failed", error);
    return json(FALLBACK);
  }
});
