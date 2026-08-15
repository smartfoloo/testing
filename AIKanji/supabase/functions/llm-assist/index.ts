// llm-assist — two modes:
//   parse   normalizes a participant's free-text MUST/WANT into a typed constraint.
//   explain writes a grounded explanation for one recommended restaurant.
//
// The LLM key never leaves the server: set it with `supabase secrets set LLM_API_KEY=...`.
// The client only ever calls this function.
//
// Nothing the model says about a *category the engine gates on* is taken on trust: the
// response shape is validated fail-closed, `sensitivity` / `verification_requirement` are
// derived server-side, and the three safety categories are filtered to closed vocabularies —
// accessibility `needs` to migration 0022's (ACCESSIBILITY_NEEDS below), allergy `allergens`
// and dietary `tags` to migration 0026's (ALLERGENS / DIETARY_TAGS). An unmatchable value would
// otherwise make a never-relaxable MUST unsatisfiable by every venue in Tokyo: that is not
// hypothetical, it is what 「えびとかにのアレルギーがあります」 did — the model mirrored the
// writer's language ({"allergens":["えび","かに"]}), venues record 'shellfish_free', and the
// engine's containment test looked for 'えび_free' forever. Allergy is deliberately never
// relaxable, so there was no negotiation to escape through either.
//
// The prompt states each closed list AND the server enforces it, in that order of trust: the
// prompt is a hint, this file is the contract. The two `_free` shapes the live model actually
// invented for 「卵と乳製品がだめです」 (dietary {"tags":["egg-free","dairy-free"]}) are exactly
// what a prompt-only rule fails to prevent.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { canonicalCuisineTag, CUISINE_TAGS } from "../_shared/cuisine.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const LLM_API_KEY = Deno.env.get("LLM_API_KEY") ?? "";
// This project talks to OpenAI through OpenRouter, so the defaults name that route rather
// than api.openai.com: a default nobody uses is a default nobody notices is wrong, and the
// failure mode is a 401 that reads like a bad key rather than a wrong endpoint. OpenRouter is
// OpenAI-compatible — same POST /chat/completions, same Bearer auth, same response shape — so
// only the endpoint and the model id differ, and the request built below is unchanged.
const LLM_BASE_URL = Deno.env.get("LLM_BASE_URL") ??
  "https://openrouter.ai/api/v1";
// OpenAI GPT-5.6 Luna. The `openai/` prefix is OpenRouter's vendor namespace and is required:
// the bare OpenAI name is not a slug there and 404s. Overridable, because the choice of model
// is a product decision that should not need a redeploy.
const LLM_MODEL = Deno.env.get("LLM_MODEL") ?? "openai/gpt-5.6-luna";
// Sent only to OpenRouter, which uses them to attribute usage to an app. Neither is required
// and neither carries anything private — the title is the product name, and the referer is the
// repository rather than a user-facing URL, since this call is made server-side on behalf of a
// group and no participant's address belongs in a provider's logs.
const OPENROUTER_REFERER = "https://github.com/smartfoloo/testing";
const OPENROUTER_TITLE = "AI Kanji (matomeshi)";

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

/// The CLOSED accessibility vocabulary. It is exactly the four nullable booleans the Google
/// Places API (New) returns in `accessibilityOptions` — wheelchairAccessibleEntrance /
/// Parking / Restroom / Seating — named after them, so the venue side maps onto it 1:1 with no
/// inference (functions/restaurant-search records a member if and only if the matching boolean
/// came back true).
///
/// It is defined once in migration 0022 (fn_accessibility_vocabulary, plus the CHECK on
/// restaurant_features.accessibility_tags) and mirrored here and in web/src/backend/engine.ts.
/// Feasibility is exact array containment (fn_candidate_blocking_types), so a need outside this
/// list can never be matched by any venue — and because an accessibility MUST is deliberately
/// never relaxable, storing one would mean zero candidates forever. That is why the prompt
/// states the list AND the validator enforces it: the model is not trusted with the vocabulary
/// any more than it is trusted with `sensitivity`.
const ACCESSIBILITY_NEEDS = [
  "wheelchair_accessible_entrance",
  "wheelchair_accessible_parking",
  "wheelchair_accessible_restroom",
  "wheelchair_accessible_seating",
] as const;

/// The two values the pre-0022 prompt used as its open-ended examples, so they are the ones
/// already in the wild (and the ones a model that saw the old spec will still emit). Both are
/// about GETTING IN, which is precisely what wheelchairAccessibleEntrance certifies, so they
/// map onto it and onto nothing more — aliasing them never invents a restroom or a seating
/// requirement nobody stated. Migration 0022 applies the identical map when it canonicalises
/// rows written before the vocabulary existed.
/// A Map rather than an object literal so a need called "constructor" or "__proto__" resolves
/// to nothing instead of to something inherited from Object.prototype.
const ACCESSIBILITY_ALIASES = new Map<string, string>([
  ["step_free", "wheelchair_accessible_entrance"],
  ["wheelchair", "wheelchair_accessible_entrance"],
]);

/// The CLOSED allergen vocabulary — six members, defined once in migration 0026
/// (fn_allergen_vocabulary, plus the CHECK on restaurant_features.allergy_safe_tags) and
/// mirrored here, in web/src/backend/engine.ts and in web/src/backend/mock.ts.
///
/// They are not invented: allergenLabel() in web/src/design/copy.ts, AppCopy.allergen in
/// AppCopy.swift and ALLERGEN_WORDS in mock.ts already enumerate exactly these, so every member
/// has a Japanese label a fully Japanese UI can print (甲殻類・卵・乳・落花生・小麦・そば). Five
/// are 消費者庁の特定原材料 and `shellfish` covers えび・かに as one crustacean tag, which is the
/// granularity the venue side records.
///
/// Feasibility is exact array containment against '<allergen>_free' tags
/// (fn_allergy_allergens_met), and an allergy MUST is NEVER relaxable, so a member outside this
/// list can never be matched by any venue and would mean zero candidates forever.
const ALLERGENS = [
  "buckwheat",
  "egg",
  "milk",
  "peanut",
  "shellfish",
  "wheat",
] as const;

/// The CLOSED dietary vocabulary — four members (fn_dietary_vocabulary, 0026), read off
/// DIETARY_WORDS in mock.ts and dietaryLabel() in copy.ts, matched against
/// restaurant_features.dietary_tags by the same containment test. Unlike allergens these are
/// *patterns a kitchen claims to cater for*, which is why gluten_free lives here while 小麦 is an
/// allergen.
const DIETARY_TAGS = ["gluten_free", "halal", "vegan", "vegetarian"] as const;

/// Every spelling of an allergen we are willing to translate, and the member it means. Maps
/// rather than object literals so a value called "constructor" or "__proto__" resolves to
/// nothing instead of to something inherited from Object.prototype.
///
/// Each alias names the SAME ingredient as its member, so mapping it preserves the requirement
/// and invents nothing. Kept in step with fn_allergen_canonical in migration 0026 — the two are
/// asserted against each other by tests/backend_tests.sql and scripts/verify-engine.ts.
///
/// WHAT IS DELIBERATELY ABSENT, because a wrong mapping here is a health risk:
///   貝 / 貝類 / あさり / 牡蠣  molluscs. `shellfish` is this schema's CRUSTACEAN tag (甲殻類),
///        and a venue that confirmed itself shellfish_free has said nothing about oysters.
///   グルテン  is a dietary tag (gluten_free); rewriting it to `wheat` would answer a coeliac
///        requirement with a label that does not cover barley or rye.
///   大豆 / ナッツ / 魚 / マンゴー  real allergens with no member and no venue tag. They are never
///        approximated and never silently dropped: applyAllergenVocabulary keeps the writer's
///        own wording and forces needs_clarification.
const ALLERGEN_ALIASES = new Map<string, string>([
  ["shellfish", "shellfish"],
  ["えび", "shellfish"],
  ["エビ", "shellfish"],
  ["海老", "shellfish"],
  ["かに", "shellfish"],
  ["カニ", "shellfish"],
  ["蟹", "shellfish"],
  ["甲殻類", "shellfish"],
  ["甲殻", "shellfish"],
  ["shrimp", "shellfish"],
  ["prawn", "shellfish"],
  ["crab", "shellfish"],
  ["crustacean", "shellfish"],
  ["crustaceans", "shellfish"],
  ["egg", "egg"],
  ["eggs", "egg"],
  ["卵", "egg"],
  ["たまご", "egg"],
  ["タマゴ", "egg"],
  ["玉子", "egg"],
  ["鶏卵", "egg"],
  ["milk", "milk"],
  ["dairy", "milk"],
  ["乳", "milk"],
  ["牛乳", "milk"],
  ["ミルク", "milk"],
  ["乳製品", "milk"],
  ["乳成分", "milk"],
  ["チーズ", "milk"],
  ["バター", "milk"],
  ["peanut", "peanut"],
  ["peanuts", "peanut"],
  ["落花生", "peanut"],
  ["ピーナッツ", "peanut"],
  ["ピーナツ", "peanut"],
  ["wheat", "wheat"],
  ["小麦", "wheat"],
  ["こむぎ", "wheat"],
  ["コムギ", "wheat"],
  ["小麦粉", "wheat"],
  ["buckwheat", "buckwheat"],
  ["soba", "buckwheat"],
  ["そば", "buckwheat"],
  ["蕎麦", "buckwheat"],
  ["ソバ", "buckwheat"],
  ["そば粉", "buckwheat"],
]);

/// The same table for dietary tags (fn_dietary_canonical, 0026). 菜食 IS vegetarian, ハラール IS
/// halal, グルテンフリー IS gluten_free. Nothing ingredient-shaped is here: 'egg-free' and
/// 'dairy-free' — which the live model produced for 「卵と乳製品がだめです」 — are allergens wearing
/// a dietary shape, so they are dropped and flagged rather than guessed at, and the prompt now
/// routes ingredient-level exclusions to `allergy` where the engine can actually check them.
const DIETARY_ALIASES = new Map<string, string>([
  ["vegan", "vegan"],
  ["ヴィーガン", "vegan"],
  ["ビーガン", "vegan"],
  ["完全菜食", "vegan"],
  ["vegetarian", "vegetarian"],
  ["veggie", "vegetarian"],
  ["ベジタリアン", "vegetarian"],
  ["菜食", "vegetarian"],
  ["菜食主義", "vegetarian"],
  ["halal", "halal"],
  ["ハラル", "halal"],
  ["ハラール", "halal"],
  ["gluten_free", "gluten_free"],
  ["glutenfree", "gluten_free"],
  ["グルテンフリー", "gluten_free"],
  ["グルテン", "gluten_free"],
]);

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

/// What each vocabulary member covers, in the language the writer will have used. Typed as
/// `Record<member, string>` on purpose: TypeScript then refuses to compile if a member is added
/// to ALLERGENS / DIETARY_TAGS without being explained in the prompt, or explained without
/// existing — the prompt and the enforced list cannot drift apart silently, which is the exact
/// failure this whole file is fixing (allergy was the only gating category the prompt did not
/// exemplify, so the model mirrored the writer's language).
const ALLERGEN_COVERAGE: Record<(typeof ALLERGENS)[number], string> = {
  shellfish: "えび・かに・甲殻類 (CRUSTACEANS ONLY)",
  egg: "卵・たまご・玉子・鶏卵",
  milk: "乳・牛乳・乳製品・チーズ・バター",
  peanut: "落花生・ピーナッツ",
  wheat: "小麦",
  buckwheat: "そば・蕎麦",
};

const DIETARY_COVERAGE: Record<(typeof DIETARY_TAGS)[number], string> = {
  vegan: "ヴィーガン・完全菜食",
  vegetarian: "ベジタリアン・菜食",
  halal: "ハラル・ハラール",
  gluten_free: "グルテンフリー",
};

/// Renders one closed list for the prompt: `  member    what it covers`, in the vocabulary's own
/// order so the prompt, the validator and the SQL all present the members identically.
function promptVocabulary(
  members: readonly string[],
  coverage: Record<string, string>,
): string {
  return members
    .map((member) => `  ${member.padEnd(12)} ${coverage[member]}`)
    .join("\n");
}

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
  dietary      {"tags": string[]}          CLOSED LIST, see below
  allergy      {"allergens": string[]}     CLOSED LIST, see below
  smoking      {"preference": "non_smoking"|"smoking_ok"}
  room         {"room": "private"|"semi_private"|"open"}
  travel_time  {"max_minutes": number}
  accessibility{"needs": string[]}         CLOSED LIST, see below
  atmosphere   {"tags": string[]}          e.g. ["quiet","lively"]
  other        {}

Every value in a closed list below is written in English EVEN WHEN THE TEXT IS JAPANESE. These
are database identifiers, not words shown to anyone: the app prints its own Japanese label for
each one. A Japanese value can never be matched against a restaurant's recorded data.

allergy "allergens" is a CLOSED list of exactly these six values. The Japanese after each one
is what it covers, not an alternative spelling to output:
${promptVocabulary(ALLERGENS, ALLERGEN_COVERAGE)}
  「えびとかにのアレルギーがあります」 -> {"allergens":["shellfish"]}
  「そばアレルギーです」            -> {"allergens":["buckwheat"]}
  「卵と乳製品がだめです」          -> allergy, {"allergens":["egg","milk"]}
  "peanut allergy"                  -> {"allergens":["peanut"]}
An allergen this list CANNOT express — マンゴー, 大豆, ナッツ, 魚, and 貝 (molluscs: shellfish
above is crustaceans only) — goes in semantic_remainder in the writer's own words, and
normalized_type STAYS allergy. NEVER approximate it with a different allergen, and never leave
it out of semantic_remainder: someone else has to confirm it with the restaurant by phone.

cuisine "include" and "exclude" are a CLOSED list of exactly these eleven values, in English even
when the text is Japanese, for the same reason as the other lists — they are compared against a
venue's recorded tags and a Japanese word can never match one:
${CUISINE_TAGS.join(" ")}
  「イタリアンがいい、中華は嫌」 -> {"include":["italian"],"exclude":["chinese"]}
A cuisine outside the list (タパス, ビストロ, ベトナム料理) goes in semantic_remainder in the
writer's own words. Unlike the lists below this does NOT need clarification on its own: cuisine
only nudges the ranking, it never excludes a venue.

dietary "tags" is a CLOSED list of exactly these four values:
${promptVocabulary(DIETARY_TAGS, DIETARY_COVERAGE)}
  「ベジタリアンです」 -> dietary, {"tags":["vegetarian"]}
dietary is for a way of eating. A SPECIFIC INGREDIENT the writer cannot eat is an ALLERGY, not a
dietary tag: never write "egg-free", "dairy-free", "no-shellfish" or any other invented tag —
use allergy with the list above. Anything the four values cannot express (pescatarian, 五葷抜き,
no pork on its own) goes in semantic_remainder in the writer's own words.

accessibility "needs" is a CLOSED list. Use only these values, exactly as written, and never
invent another one:
${ACCESSIBILITY_NEEDS.map((need) => `  ${need}`).join("\n")}
They are the only four things a venue's accessibility can be verified against, so a value
outside the list can never be checked and is worse than useless. Pick every member the writer
clearly needs and nothing more: 「車椅子で入れる」/「段差がない」 is
wheelchair_accessible_entrance, 「車椅子対応のトイレ」 adds
wheelchair_accessible_restroom, 「車椅子席」 adds wheelchair_accessible_seating,
「車椅子で使える駐車場」 adds wheelchair_accessible_parking.
An accessibility need this list CANNOT express — an elevator, a wide aisle, braille, a guide
dog, sign language — goes in semantic_remainder in the writer's own words, and normalized_type
stays accessibility if any member above still applies. Never approximate it with a member that
means something else.

semantic_remainder: the part of the writer's own wording that normalized_value does not
express — copy their words, in their language, and nothing else. Use null when the shape
already covers the whole text. Never invent words that are not in the text, never paraphrase,
and never put the whole text there just because you are unsure.
  "個室で、日本酒が充実してるところ" as room -> "日本酒が充実してる"
  "budget under 4000 yen" as budget -> null
  "車椅子で入れて、エレベーターがあるところ" as accessibility ->
    {"needs":["wheelchair_accessible_entrance"]}, semantic_remainder "エレベーターがある"

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

/// The accessibility vocabulary, enforced on the model's answer rather than trusted.
///
/// The prompt states the closed list, but a prompt is a request and this is a safety category,
/// so `needs` is filtered here the same way a hallucinated extra key is rejected in validate().
/// Three outcomes, and NONE of them silently drops a stated requirement:
///
///   1. every need is a vocabulary member (after aliasing) -> untouched.
///   2. some are, some are not -> the members are kept and gate the search, the rest are
///      removed from `needs`, the writer's OWN WORDING is preserved in semantic_remainder
///      (falling back to their whole text when the model offered no remainder), and
///      needs_clarification is forced true so the human is asked before this is saved. Keeping
///      an unmatched member instead would be worse than dropping it: feasibility is exact array
///      containment and an accessibility MUST is never relaxable, so ONE unknown value means
///      zero candidates forever with no way out — the bug 0022 exists to remove.
///   3. NOTHING is expressible (「エレベーターがある店」) -> the row becomes an `other` note with
///      the same remainder and clarification flag, deliberately NOT an accessibility MUST with
///      an empty `needs`, because that shape fails closed for every venue and cannot be
///      negotiated. A note the group's 幹事 can act on is honest about the engine being unable
///      to verify the requirement; an unsatisfiable MUST would pretend to enforce it while
///      quietly excluding all of Tokyo. The ANONYMOUS default is kept regardless: it is still
///      disability information, and the participant still owns the final visibility choice
///      (which is why this runs AFTER applyDefaultVisibility).
///
/// `sensitivity` and `verification_requirement` are derived afterwards from whatever type
/// survives, so they always match what 0018's trigger would compute for the stored row.
function applyAccessibilityVocabulary(
  result: ModelParse,
  rawText: string,
): ModelParse {
  if (result.normalized_type !== "accessibility") return result;

  const stated = Array.isArray(result.normalized_value.needs)
    ? result.normalized_value.needs
    : [];
  const canonical: string[] = [];
  let dropped = stated.length === 0;
  for (const need of stated) {
    const mapped = typeof need === "string"
      ? ACCESSIBILITY_ALIASES.get(need) ?? need
      : null;
    if (
      mapped !== null &&
      (ACCESSIBILITY_NEEDS as readonly string[]).includes(mapped)
    ) {
      if (!canonical.includes(mapped)) canonical.push(mapped);
      // An alias is a rename, but 'wheelchair' -> entrance is still narrower than what the
      // participant may have meant, so it counts as something a human should confirm.
      if (mapped !== need) dropped = true;
    } else {
      dropped = true;
    }
  }
  // Sorted so the stored value matches fn_accessibility_canonical_tags' output.
  canonical.sort();
  if (!dropped) {
    return {
      ...result,
      normalized_value: { ...result.normalized_value, needs: canonical },
    };
  }

  const remainder = result.semantic_remainder ?? (rawText.trim() || null);
  if (canonical.length === 0) {
    return {
      ...result,
      normalized_type: "other",
      normalized_value: {},
      semantic_remainder: remainder,
      needs_clarification: true,
    };
  }
  return {
    ...result,
    normalized_value: { ...result.normalized_value, needs: canonical },
    semantic_remainder: remainder,
    needs_clarification: true,
  };
}

/// Spelling normalization shared by the allergen and dietary tables, mirroring
/// fn_taxonomy_token in migration 0026: case-folded, and space / ideographic space / ASCII
/// hyphen / fullwidth hyphen / U+2010 hyphen folded to '_', so 'Gluten-Free', 'gluten free' and
/// 'gluten_free' are one token. The katakana prolonged sound mark 'ー' is deliberately NOT folded
/// — it is a letter in ピーナッツ and ミルク, not punctuation.
function taxonomyToken(raw: string): string {
  return raw.toLowerCase().replace(/[ 　\-－‐]/g, "_").trim();
}

/// One allergen word -> one ALLERGENS member, or null. A trailing '_free' is stripped first so a
/// model that echoes the venue side's 'shellfish_free' still lands on 'shellfish' rather than
/// being dropped. Mirrors fn_allergen_canonical (0026).
function canonicalAllergen(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  return ALLERGEN_ALIASES.get(taxonomyToken(raw).replace(/_?free$/, "")) ??
    null;
}

/// One dietary word -> one DIETARY_TAGS member, or null. No '_free' stripping here: 'gluten_free'
/// IS a member. Mirrors fn_dietary_canonical (0026).
function canonicalDietaryTag(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  return DIETARY_ALIASES.get(taxonomyToken(raw)) ?? null;
}

/// The closed vocabulary of ONE safety category, enforced on the model's answer rather than
/// trusted — the same treatment applyAccessibilityVocabulary gives `needs`, and the same three
/// outcomes, with ONE DELIBERATE DIFFERENCE spelled out below.
///
///   1. every value maps onto the vocabulary -> the canonical (sorted, deduped) list is stored,
///      and the row is only left unflagged when the taxonomy also captured the WHOLE text (see
///      the note on needs_clarification below).
///   2. some map and some do not -> the ones that do are kept AND GATE THE SEARCH, the rest are
///      removed from the value, the writer's OWN WORDING is preserved in semantic_remainder
///      (falling back to their whole text when the model offered no remainder), and
///      needs_clarification is forced true so a human is asked before this is saved. Keeping an
///      unmapped value instead would be worse than dropping it: feasibility is exact array
///      containment and neither of these MUSTs is relaxable, so one unknown value means zero
///      candidates forever with no way out — the bug 0026 exists to remove.
///   3. NOTHING is expressible (「マンゴーアレルギー」) -> the type STAYS `allergy` (or `dietary`)
///      with an empty list, the wording is preserved and clarification is forced.
///
/// THAT THIRD CASE IS THE ASYMMETRY WITH ACCESSIBILITY, and it is intentional. 0022 re-types an
/// inexpressible accessibility need to a non-gating `other` note, because the engine genuinely
/// cannot check 「エレベーターがある店」 and a note a 幹事 can act on is more honest than a MUST
/// that excludes all of Tokyo. Doing that to an allergy would drop a MEDICAL requirement out of
/// the gate entirely and let the group be recommended a venue nobody has checked — the worst
/// failure available here. So it stays gating and fails closed; what stops the resulting zero
/// from being silent is migration 0026's `allergy_unverified_count`, which reports those
/// candidates as unverified (they are: allergy_safe_tags records only positive claims, so absence
/// is never a contradiction), plus verification_requirement = 'required', which is the cue to
/// phone the venue. Reporting, never consent.
///
/// `sensitivity` and `verification_requirement` are derived afterwards from whatever type
/// survives, so they always match what 0018's trigger would compute for the stored row.
function applyClosedTagVocabulary(
  result: ModelParse,
  rawText: string,
  type: "allergy" | "dietary",
  key: "allergens" | "tags",
  canonicalize: (raw: unknown) => string | null,
): ModelParse {
  if (result.normalized_type !== type) return result;

  const stated = Array.isArray(result.normalized_value[key])
    ? result.normalized_value[key] as unknown[]
    : [];
  const canonical: string[] = [];
  // An unreadable or absent list is itself something to ask about: a safety MUST whose own value
  // we cannot read must never be saved as if it had been understood.
  let dropped = stated.length === 0;
  for (const value of stated) {
    const mapped = canonicalize(value);
    if (mapped === null) {
      dropped = true;
      continue;
    }
    if (!canonical.includes(mapped)) canonical.push(mapped);
    // A synonym is a rename, not a loss — but 「乳製品」 -> milk and 「甲殻類」 -> shellfish are
    // both broader-to-narrower in places, so a human still confirms what we understood.
    if (mapped !== value) dropped = true;
  }
  // Sorted so the stored value matches fn_allergen_canonical_allergens' output.
  canonical.sort();

  const remainder = dropped
    ? result.semantic_remainder ?? (rawText.trim() || null)
    : result.semantic_remainder;
  return {
    ...result,
    normalized_value: { ...result.normalized_value, [key]: canonical },
    semantic_remainder: remainder,
    // ANY leftover wording on one of these two categories forces the question, even when the
    // server dropped nothing — because the MODEL may have done the dropping. Verified live:
    // 「えびアレルギーとマンゴーアレルギーです」 came back as {"allergens":["shellfish"]} with
    // "マンゴーアレルギー" already in semantic_remainder and needs_clarification false, i.e. a
    // correctly-shaped answer that still records a WEAKER requirement than the participant
    // stated. Nothing about that row is wrong except its silence, so this is the one place the
    // flag is raised on the model's behalf.
    // Accessibility deliberately keeps 0022's rule instead (a remainder there is an amenity the
    // engine cannot verify, not an ingredient somebody could react to).
    needs_clarification: result.needs_clarification || dropped ||
      remainder !== null,
  };
}

/// Cuisine gets the same "enforce it, do not trust it" treatment, and for the same reason: the
/// value is compared against restaurant_features.cuisine_tags with `&&`, so "Italian" and
/// "italian" are simply two different strings and the first one matches nothing.
///
/// It is NOT one of the safety categories, and the difference is deliberate.
/// fn_candidate_blocking_types does not list cuisine, so an unmapped value costs a little ranking
/// accuracy and can never empty the shortlist the way an unmapped allergen would. So the writer's
/// wording is still preserved when something is dropped — 「タパスが食べたい」 must not vanish in
/// silence — but needs_clarification is left exactly as the model set it rather than forced.
/// Interrupting somebody to confirm a preference that only nudges an ordering would train them to
/// dismiss the question that matters, which is the allergy one.
///
/// A rename is not a loss: "Italian" -> "italian" leaves nothing unexpressed, so only a value that
/// maps to nothing at all counts as dropped.
function applyCuisineVocabulary(
  result: ModelParse,
  rawText: string,
): ModelParse {
  if (result.normalized_type !== "cuisine") return result;

  let dropped = false;
  const canonicalList = (key: "include" | "exclude"): string[] => {
    const stated = Array.isArray(result.normalized_value[key])
      ? result.normalized_value[key] as unknown[]
      : [];
    const canonical: string[] = [];
    for (const value of stated) {
      const mapped = canonicalCuisineTag(value);
      if (mapped === null) {
        dropped = true;
        continue;
      }
      if (!canonical.includes(mapped)) canonical.push(mapped);
    }
    return canonical.sort();
  };

  const include = canonicalList("include");
  const exclude = canonicalList("exclude");
  return {
    ...result,
    normalized_value: { ...result.normalized_value, include, exclude },
    semantic_remainder: dropped
      ? result.semantic_remainder ?? (rawText.trim() || null)
      : result.semantic_remainder,
  };
}

/// The four closed vocabularies, applied in one place. Accessibility runs FIRST because it is
/// the only one that can re-type a row (to `other`); the others then see a type that is no
/// longer theirs and no-op, so the order cannot produce a half-converted row.
function applyClosedVocabularies(
  result: ModelParse,
  rawText: string,
): ModelParse {
  return applyCuisineVocabulary(
    applyClosedTagVocabulary(
      applyClosedTagVocabulary(
        applyAccessibilityVocabulary(result, rawText),
        rawText,
        "dietary",
        "tags",
        canonicalDietaryTag,
      ),
      rawText,
      "allergy",
      "allergens",
      canonicalAllergen,
    ),
    rawText,
  );
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
      // Ignored by an OpenAI-compatible endpoint that does not know them, so this stays
      // correct if LLM_BASE_URL is pointed straight at OpenAI or a local model.
      "HTTP-Referer": OPENROUTER_REFERER,
      "X-Title": OPENROUTER_TITLE,
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

  // Scoped to THIS event's participants. restaurant_features is a global pool keyed by place_id,
  // so travel_minutes_by_participant accumulates an entry for every participant of every event
  // that ever considered this venue. Handing the model all of them made it state a travel time
  // belonging to a different group — verified: a fresh single-member event was told a venue was
  // "about 25 minutes away", which was one of the seeded demo event's participants' figures, while
  // this event's own fairness_score correctly read 0 because it has no travel data at all. The
  // card contradicted itself, and one group's numbers surfaced in another group's text. Every
  // other field here is already event-scoped (group_wants filters on run.event_id, and MUST rows
  // are withheld entirely); this was the one that escaped.
  const { data: members } = await admin
    .from("participants")
    .select("id")
    .eq("event_id", run.event_id)
    .returns<{ id: string }[]>();
  const memberIds = new Set((members ?? []).map((member) => member.id));
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
      travel_minutes: Object.entries(travel)
        .filter(([participantId]) => memberIds.has(participantId))
        .map(([, minutes]) => Number(minutes))
        .filter(Number.isFinite),
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
    // Order matters: the ANONYMOUS default is chosen while the type is still one of the three
    // sensitive ones, so a value the vocabulary cannot express keeps that default even when an
    // accessibility need degrades to a note; the server-owned metadata is then derived from
    // whatever type survived.
    return json(
      validated
        ? applyServerMetadata(
          applyClosedVocabularies(
            applyDefaultVisibility(validated),
            raw_text,
          ),
          kind,
        )
        : FALLBACK,
    );
  } catch (error) {
    console.error("llm-assist parse failed", error);
    return json(FALLBACK);
  }
});
