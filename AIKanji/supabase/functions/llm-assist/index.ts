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
type Kind = "MUST" | "WANT";
type Sensitivity = "normal" | "sensitive" | "highly_sensitive";
type VerificationRequirement = "none" | "recommended" | "required";

/// How personal the requirement is. Advisory metadata only: it never touches
/// suggested_visibility, because the participant owns that decision (PRD §5).
/// Mirrors fn_constraint_sensitivity in migration 0018 — keep the two in step.
const SENSITIVITY_BY_TYPE: Record<NormalizedType, Sensitivity> = {
  allergy: "highly_sensitive",
  dietary: "highly_sensitive",
  accessibility: "highly_sensitive",
  budget: "sensitive", // money talk between coworkers is awkward, but it is not health data
  cuisine: "normal",
  smoking: "normal",
  room: "normal",
  travel_time: "normal",
  atmosphere: "normal",
  other: "normal",
};

/// Amenities we only know from provider data, which goes stale: worth a phone call, but a
/// wrong answer disappoints rather than harms.
const VERIFY_RECOMMENDED_TYPES = ["room", "smoking"] as const;

interface ParseResult {
  normalized_type: NormalizedType;
  normalized_value: Record<string, unknown>;
  suggested_visibility: Visibility;
  semantic_remainder: string | null;
  sensitivity: Sensitivity;
  verification_requirement: VerificationRequirement;
  confidence: number;
  needs_clarification: boolean;
}

/// What the model is allowed to decide. The two server-owned fields are excluded by
/// construction, so nothing can slip a model-authored sensitivity into the response.
type ModelParse = Omit<ParseResult, "sensitivity" | "verification_requirement">;

/// Mirrors fn_constraint_verification_requirement in migration 0018. Only a MUST gates a
/// venue, so only a MUST can demand confirmation; safety categories always do (PRD §11:
/// "Unknown ≠ supported"). Derived here, never read from the model.
function verificationFor(
  normalizedType: NormalizedType,
  kind: Kind,
): VerificationRequirement {
  if (kind !== "MUST") return "none";
  if ((SENSITIVE_TYPES as readonly string[]).includes(normalizedType)) {
    return "required";
  }
  if (
    (VERIFY_RECOMMENDED_TYPES as readonly string[]).includes(normalizedType)
  ) {
    return "recommended";
  }
  return "none";
}

/// Returned whenever the model output cannot be trusted; the human corrects it in the UI.
/// 'other' is neither sensitive nor gating for either kind, so the metadata is constant here.
const FALLBACK: ParseResult = {
  normalized_type: "other",
  normalized_value: {},
  suggested_visibility: "PUBLIC",
  semantic_remainder: null,
  sensitivity: SENSITIVITY_BY_TYPE.other,
  verification_requirement: "none",
  confidence: 0,
  needs_clarification: true,
};

const SYSTEM_PROMPT =
  `You normalize a single restaurant-outing requirement written by a member of a Tokyo coworker group.

Reply with JSON only, exactly these six keys and nothing else:
{"normalized_type": one of ${NORMALIZED_TYPES.join("|")},
 "normalized_value": object,
 "suggested_visibility": "PUBLIC" or "ANONYMOUS",
 "semantic_remainder": string or null,
 "confidence": number between 0 and 1,
 "needs_clarification": boolean}

normalized_value shape by type:
  budget       {"max_yen": number} or {"min_yen": number, "max_yen": number}
  cuisine      {"include": string[], "exclude": string[]}
  dietary      {"tags": string[]}          e.g. ["vegetarian","halal"]
  allergy      {"allergens": string[]}
  smoking      {"preference": "non_smoking"|"smoking_ok"}
  room         {"room": "private"|"semi_private"|"open"}
  travel_time  {"max_minutes": number}
  accessibility{"needs": string[]}         e.g. ["step_free","wheelchair"]
  atmosphere   {"tags": string[]}          e.g. ["quiet","lively"]
  other        {}

semantic_remainder: the part of the writer's own wording that normalized_value does not
express — copy their words, in their language, and nothing else. Use null when the shape
already covers the whole text. Never invent words that are not in the text, never paraphrase,
and never put the whole text there just because you are unsure.
  "個室で、日本酒が充実してるところ" as room -> "日本酒が充実してる"
  "budget under 4000 yen" as budget -> null

Set needs_clarification true when the text is empty, ambiguous, or you cannot fill the shape.
Suggest ANONYMOUS for allergy, dietary and accessibility; PUBLIC otherwise.
Do not output sensitivity or verification fields; the server derives those itself.
The text may be Japanese or English.`;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// Fail-closed validator: wrong types, missing keys or hallucinated extra keys all reject.
/// sensitivity and verification_requirement are deliberately absent from the contract — the
/// server derives them, so a model that volunteers them is answering the wrong question and
/// gets rejected like any other extra key.
function validate(candidate: unknown, rawText: string): ModelParse | null {
  if (!isPlainObject(candidate)) return null;

  const expected = [
    "normalized_type",
    "normalized_value",
    "suggested_visibility",
    "semantic_remainder",
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
    semantic_remainder,
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
  if (semantic_remainder !== null && typeof semantic_remainder !== "string") {
    return null;
  }
  if (typeof confidence !== "number" || !Number.isFinite(confidence)) {
    return null;
  }
  if (confidence < 0 || confidence > 1) return null;
  if (typeof needs_clarification !== "boolean") return null;

  // The remainder is a slice of what the participant wrote, so it cannot be longer than the
  // text itself; anything longer is the model composing prose and is not trustworthy.
  const remainder = semantic_remainder === null
    ? ""
    : semantic_remainder.trim();
  if (remainder.length > rawText.trim().length) return null;

  return {
    normalized_type: normalized_type as NormalizedType,
    normalized_value,
    suggested_visibility,
    // Empty means "the taxonomy captured everything"; store NULL rather than an empty string
    // so P1's semantic matching has nothing to embed for these rows.
    semantic_remainder: remainder === "" ? null : remainder,
    confidence,
    needs_clarification,
  };
}

/// Sensitive categories default to ANONYMOUS; the client can still override before saving.
function applyDefaultVisibility(result: ModelParse): ModelParse {
  if ((SENSITIVE_TYPES as readonly string[]).includes(result.normalized_type)) {
    return { ...result, suggested_visibility: "ANONYMOUS" };
  }
  return result;
}

/// The two server-owned fields, assigned from normalized_type (and kind) rather than from the
/// model: a hallucinated "not sensitive" allergy or "no confirmation needed" MUST would be a
/// safety bug, and both fields are pure functions of the taxonomy anyway. Sensitivity stays out
/// of the visibility decision on purpose — that one belongs to the participant.
function applyServerMetadata(result: ModelParse, kind: Kind): ParseResult {
  return {
    ...result,
    sensitivity: SENSITIVITY_BY_TYPE[result.normalized_type],
    verification_requirement: verificationFor(result.normalized_type, kind),
  };
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
    const validated = validate(
      await callModel(raw_text, kind, language),
      raw_text,
    );
    return json(
      validated
        ? applyServerMetadata(applyDefaultVisibility(validated), kind)
        : FALLBACK,
    );
  } catch (error) {
    console.error("llm-assist parse failed", error);
    return json(FALLBACK);
  }
});
