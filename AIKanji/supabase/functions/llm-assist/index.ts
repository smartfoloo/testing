// llm-assist — normalizes a participant's free-text MUST/WANT into a typed constraint.
//
// The LLM key never leaves the server: set it with `supabase secrets set LLM_API_KEY=...`.
// The client only ever calls this function.

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

async function callModel(
  rawText: string,
  kind: string,
  language: string,
): Promise<unknown> {
  const response = await fetch(`${LLM_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${LLM_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        {
          role: "user",
          content: `kind: ${kind}\nlanguage: ${language}\ntext: ${rawText}`,
        },
      ],
    }),
  });

  if (!response.ok) throw new Error(`LLM HTTP ${response.status}`);

  const body = await response.json();
  const content = body?.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new Error("LLM returned no content");
  return JSON.parse(content);
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

  const { mode, raw_text, kind, language } = request;
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
