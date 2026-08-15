/**
 * TypeScript port of the deterministic feasibility / scoring / relaxation engine
 * defined in AIKanji/supabase/migrations/0009_review_function_replacements.sql,
 * 0016_scoring_and_objective.sql, 0021_must_coverage_and_proposal_integrity.sql,
 * 0022_accessibility_vocabulary_and_room_unknown.sql and
 * 0026_allergen_vocabulary_and_unverified_coverage.sql (which together supersede
 * 0005_feasibility.sql).
 *
 * This exists so the mock backend behaves the same as the real Postgres one: the LLM
 * never decides feasibility or which MUST gets relaxed, it is all deterministic here too.
 *
 * SQL semantics that are deliberately reproduced:
 *  - every MUST type that can gate a venue has a branch: budget, room, dietary, allergy,
 *    accessibility, smoking, travel_time. Before 0021 the last two fell through the
 *    `if/elsif` chain and were SILENTLY MET, so 「車椅子で入れる店」 was ignored as a hard
 *    requirement. Only the non-gating types (cuisine, atmosphere, other — they are scored,
 *    not filtered) still pass by default;
 *  - `candidateBlockingTypes` is the single implementation of that chain and
 *    `candidateIsFeasible` is a wrapper over it (`fn_candidate_blocking_types`, 0022), so the
 *    gate and the explanation of a zero-candidate result cannot drift apart;
 *  - absent venue data is never satisfaction (PRD §11 "unknown ≠ supported"): dietary,
 *    allergy, accessibility and smoking all fail closed on a venue we know nothing about,
 *    and on a MUST whose own normalized_value cannot be read. Since 0022 an unreadable
 *    `room` value does too, and a venue whose room_type is unknown is admissible only after
 *    the participant has accepted `accept_unknown`;
 *  - accessibility needs and recorded venue tags share ONE closed vocabulary
 *    (`ACCESSIBILITY_VOCABULARY`, 0022): four members mapped 1:1 from the four booleans
 *    Google Places' `accessibilityOptions` can return;
 *  - allergens and `<allergen>_free` venue claims share ONE closed vocabulary too
 *    (`ALLERGEN_VOCABULARY`, 0026), as do dietary tags (`DIETARY_VOCABULARY`). Before 0026 the
 *    live model answered 「えびとかにのアレルギーがあります」 in Japanese, so the containment test
 *    looked for `えび_free` and no venue ever matched — permanently, since an allergy MUST is
 *    never relaxable. Feasibility is unchanged; the vocabularies are enforced at the boundaries
 *    (`llm-assist`, `mock.ts`'s parser) and reported on by `recomputeFeasibility`;
 *  - `(value->>'key')::int` on a missing key yields SQL NULL, and `x > NULL` is NULL,
 *    which `if` treats as false — so the MUST passes. `nullableInt` + `exceeds` model that;
 *    since 0021 SQL reads those keys through fn_jsonb_int, which also yields NULL for a
 *    non-numeric value instead of raising — i.e. SQL now matches `nullableInt`;
 *  - `is distinct from` is null-safe inequality;
 *  - `@>` is array containment, `&&` is array overlap;
 *  - travel minutes are read through one helper with the cache-then-feature precedence of
 *    `fn_travel_minutes` (0016), so an event never sees another event's travel times;
 *  - scoring is objective-weighted (`fn_objective_weights`), missing data is confined to a
 *    band below measured data (`fn_banded_score`), and a label is only written when the row
 *    genuinely leads that metric — otherwise the badge is dropped, never reassigned;
 *  - a relaxation proposal is idempotent per event (`fn_propose_relaxation`, 0021): the open
 *    proposal is returned rather than duplicated, and a step already rejected is not re-asked.
 */

import type {
  ConstraintKind,
  ConstraintSensitivity,
  ConstraintVisibility,
  EventObjective,
  EventStatus,
  NormalizedType,
  NormalizedValue,
  NegotiationStatus,
  ObjectiveWeights,
  ParticipantRole,
  QualityMethod,
  RecommendationLabel,
  ScoreBreakdown,
  ScoreDimension,
  TravelReference,
  VerificationRequirement,
} from '../models/types'
import { SCORE_DIMENSIONS } from '../models/types'

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

export interface EventRow {
  id: string
  name: string
  invite_code: string
  organizer_participant_id: string | null
  objective: EventObjective
  status: EventStatus
  created_at: string
  chosen_place_id: string | null
  chosen_at: string | null
  /** Set by fn_close_preferences (0018). Non-null means constraint writes are refused. */
  preferences_closed_at: string | null
}

export interface ParticipantRow {
  id: string
  event_id: string
  auth_user_id: string
  display_name: string
  role: ParticipantRole
  travel_reference: TravelReference | null
  travel_reference_place_id: string | null
  joined_at: string
}

export interface ConstraintRow {
  id: string
  event_id: string
  participant_id: string
  kind: ConstraintKind
  raw_text: string
  normalized_type: NormalizedType
  normalized_value: NormalizedValue
  visibility: ConstraintVisibility
  /**
   * Advisory metadata derived server-side from (kind, normalized_type) by 0018's
   * trg_derive_constraint_metadata. Never read by feasibility — sensitivity must not
   * influence visibility, which the participant owns.
   */
  sensitivity: ConstraintSensitivity
  verification_requirement: VerificationRequirement
  /** The participant's own wording the taxonomy did not capture; for P1 semantic matching. */
  semantic_remainder: string | null
  created_at: string
  updated_at: string
}

export interface NegotiationRow {
  id: string
  event_id: string
  constraint_id: string
  participant_id: string
  proposed_value: NormalizedValue
  unlocked_count: number
  status: NegotiationStatus
  created_at: string
  responded_at: string | null
}

export interface RestaurantRow {
  place_id: string
  hotpepper_id: string | null
  last_fetched_at: string
}

export interface FeatureRow {
  place_id: string
  name: string | null
  price_yen_estimate: number | null
  room_type: string | null
  cuisine_tags: string[]
  dietary_tags: string[]
  allergy_safe_tags: string[]
  atmosphere_tags: string[]
  travel_minutes_by_participant: Record<string, number>
  fetched_at: string
  /**
   * Provider quality signal (`restaurant_features.rating` / `user_rating_count`, 0016).
   * Optional here because fixtures written before 0016 do not set them; absent or null
   * means "unrated", which the quality score treats as strictly worse than any rating.
   */
  rating?: number | null
  user_rating_count?: number | null
  /**
   * `restaurant_features.accessibility_tags` (0016), constrained since 0022 to
   * `ACCESSIBILITY_VOCABULARY`. Absent or empty = no data, never "supported": only positives
   * are ever recorded, so a missing member means UNCONFIRMED and never confirmed-absent.
   */
  accessibility_tags?: string[]
  /**
   * `restaurant_features.smoking_policy` (0021), the venue attribute a smoking MUST is
   * judged against. Optional and nullable for the same reason the column is: no provider
   * fills it yet, and absent/null means UNCONFIRMED — which fails a smoking MUST rather
   * than satisfying it. 分煙 is recorded as null, not as a third value: we cannot certify
   * from provider text which side of the partition the group would sit on.
   */
  smoking_policy?: 'non_smoking' | 'smoking_ok' | null
}

/** A row of `travel_matrix_cache` (event-scoped travel times, created by 0017). */
export interface TravelMatrixRow {
  event_id: string
  participant_id: string
  place_id: string
  minutes: number
}

export interface RunRow {
  id: string
  event_id: string
  run_at: string
  feasible_count: number
  input_snapshot: Record<string, unknown>
}

export interface ScoreRow {
  id: string
  run_id: string
  restaurant_place_id: string
  fairness_score: number | null
  satisfaction_score: number | null
  quality_score: number | null
  cost_burden_score: number | null
  accessibility_burden_score: number | null
  objective_score: number | null
  score_breakdown: ScoreBreakdown | null
  label: RecommendationLabel | null
  explanation: string | null
}

export interface Db {
  events: EventRow[]
  participants: ParticipantRow[]
  constraints: ConstraintRow[]
  negotiations: NegotiationRow[]
  restaurants: RestaurantRow[]
  features: FeatureRow[]
  runs: RunRow[]
  scores: ScoreRow[]
  /**
   * Event-scoped travel times (`travel_matrix_cache`). Optional: callers written before
   * 0017 simply do not have it, and then every lookup falls back to
   * `restaurant_features.travel_minutes_by_participant`, exactly as `fn_travel_minutes` does.
   */
  travelMatrix?: TravelMatrixRow[]
}

/* -------------------------------------------------------------------------- */
/* SQL-ish helpers                                                             */
/* -------------------------------------------------------------------------- */

/**
 * `fn_jsonb_int(value, 'key')` (0021) — SQL NULL for a missing key or a non-numeric value.
 * This port always behaved this way; 0021 replaced the raw `(value->>'key')::int` casts in
 * SQL with the same rule, because a single `{"max_yen":"cheap"}` row raised
 * invalid_text_representation and aborted the whole event's recompute. NULL is not a
 * loophole: `x > NULL` is falsey, so an unreadable key leaves the MUST passing exactly as a
 * missing key always did.
 */
function nullableInt(value: NormalizedValue, key: string): number | null {
  const raw = value[key]
  if (raw === undefined || raw === null) return null
  // fn_jsonb_int guards the cast with `~ '^-?[0-9]+(\.[0-9]+)?$'` on the text form, so
  // "40abc" is NULL there rather than 40 as Number.parseInt would have it. Same rule here, so
  // the two implementations cannot disagree about a hand-written value.
  let numeric = Number.NaN
  if (typeof raw === 'number') numeric = raw
  else if (/^-?\d+(\.\d+)?$/.test(String(raw))) numeric = Number(raw)
  if (!Number.isFinite(numeric)) return null
  const truncated = Math.trunc(numeric)
  // `::int`: a value outside the 32-bit range is reported as absent rather than silently
  // becoming a different number. Both implementations then leave the MUST passing, because
  // `x > null` is falsey — the same outcome a missing key has always had.
  if (truncated < -2147483648 || truncated > 2147483647) return null
  return truncated
}

/** `left > right` where a NULL right-hand side makes the whole predicate NULL (falsey). */
function exceeds(left: number, right: number | null): boolean {
  if (right === null) return false
  return left > right
}

/** `(jsonb->>'key')` — the value's text form, or null for a missing key or a JSON null. */
function nullableText(value: NormalizedValue, key: string): string | null {
  const raw = value[key]
  if (raw === undefined || raw === null) return null
  return typeof raw === 'string' ? raw : JSON.stringify(raw)
}

/**
 * `fn_jsonb_flag(value, key)` (0021): true only for a real JSON `true`. The flag is written
 * by `relaxedValue`, so anything else in that key is malformed and must not widen a MUST.
 */
function flag(value: NormalizedValue, key: string): boolean {
  return value[key] === true
}

/**
 * Postgres `jsonb = jsonb`: key order is not part of the value. Used to recognise a
 * relaxation step a participant already rejected. Our relaxation values are flat objects of
 * scalars, which is the only shape this canonicalisation has to handle.
 */
function sameValue(left: NormalizedValue, right: NormalizedValue): boolean {
  const canonical = (value: NormalizedValue) =>
    JSON.stringify(
      Object.keys(value)
        .sort()
        .map((key) => [key, value[key]]),
    )
  return canonical(left) === canonical(right)
}

function stringArray(value: NormalizedValue, key: string): string[] | null {
  const raw = value[key]
  if (!Array.isArray(raw)) return null
  return raw.filter((entry): entry is string => typeof entry === 'string')
}

/** Postgres `@>`: does `haystack` contain every element of `needles`? */
function contains(haystack: string[], needles: string[]): boolean {
  return needles.every((needle) => haystack.includes(needle))
}

/** Postgres `&&`: do the arrays share at least one element? */
function overlaps(left: string[], right: string[]): boolean {
  return left.some((entry) => right.includes(entry))
}

/** Postgres `round(numeric, 4)`. */
function round4(value: number): number {
  return Math.round(value * 10000) / 10000
}

/** Postgres `greatest(0, least(1, x))`. */
function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0
  return Math.min(1, Math.max(0, value))
}

/* -------------------------------------------------------------------------- */
/* fn_travel_minutes                                                           */
/* -------------------------------------------------------------------------- */

/**
 * Ports `public.fn_travel_minutes(p_event_id, p_place_id, p_participant_id)` from 0016 —
 * the single place either implementation reads a travel time.
 *
 * Precedence, exactly as in SQL: the event-scoped `travel_matrix_cache` row wins, then the
 * legacy global `restaurant_features.travel_minutes_by_participant` map, then NULL. NULL
 * means "unknown", never "zero minutes": the global map is shared by every event, so one
 * event's search used to silently overwrite another's (an event went 3 feasible → 0).
 */
export function travelMinutesFor(
  db: Db,
  eventId: string,
  placeId: string,
  participantId: string,
): number | null {
  const cached = db.travelMatrix?.find(
    (row) =>
      row.event_id === eventId &&
      row.place_id === placeId &&
      row.participant_id === participantId,
  )
  if (cached && Number.isFinite(cached.minutes)) return Math.trunc(cached.minutes)

  const feature = db.features.find((row) => row.place_id === placeId)
  const fallback = feature?.travel_minutes_by_participant[participantId]
  return typeof fallback === 'number' && Number.isFinite(fallback) ? Math.trunc(fallback) : null
}

/* -------------------------------------------------------------------------- */
/* Accessibility vocabulary — fn_accessibility_vocabulary (0022)               */
/* -------------------------------------------------------------------------- */

/**
 * The closed accessibility vocabulary, ported from `fn_accessibility_vocabulary()` (0022) and
 * kept in the same (sorted) order as the SQL array.
 *
 * It is exactly the four nullable booleans Google Places (New) returns in
 * `accessibilityOptions` — wheelchairAccessibleParking / Entrance / Restroom / Seating — named
 * after them, so provider data maps onto it 1:1 with no inference: `restaurant-search` records
 * a member if and only if the matching boolean came back `true`, and an absent or null boolean
 * stays UNKNOWN (never `false`, never a tag).
 *
 * The same four strings are stated in the `llm-assist` prompt AND validated server-side there,
 * and `restaurant_features_accessibility_vocabulary` (0022) constrains the venue side in the
 * database. Feasibility itself stays a plain containment test: normalization belongs at the
 * boundaries, never inside the deterministic engine.
 */
export const ACCESSIBILITY_VOCABULARY = [
  'wheelchair_accessible_entrance',
  'wheelchair_accessible_parking',
  'wheelchair_accessible_restroom',
  'wheelchair_accessible_seating',
] as const

/* -------------------------------------------------------------------------- */
/* Allergen / dietary vocabularies — fn_allergen_vocabulary (0026)             */
/* -------------------------------------------------------------------------- */

/**
 * The closed allergen vocabulary, ported from `fn_allergen_vocabulary()` (0026) and kept in the
 * same (sorted) order as the SQL array.
 *
 * Six members, none of them invented here: `allergenLabel()` in `src/design/copy.ts`,
 * `AppCopy.allergen` in AppCopy.swift and `ALLERGEN_WORDS` in `mock.ts` already enumerate exactly
 * these, so every member has a Japanese label (甲殻類・卵・乳・落花生・小麦・そば) a fully
 * Japanese UI can print. Five are 消費者庁の特定原材料 and `shellfish` is the CRUSTACEAN tag
 * (えび・かに), which is the granularity the venue side records.
 *
 * The venue side speaks the same vocabulary with a `_free` suffix
 * (`restaurant_features.allergy_safe_tags`, constrained since 0026 by
 * `restaurant_features_allergen_safe_tag_vocabulary`), and `llm-assist` states the six strings in
 * its prompt AND enforces them on the model's answer. Feasibility itself stays a plain
 * containment test: normalization belongs at the boundaries, never inside the deterministic
 * engine.
 *
 * WHY IT HAS TO BE CLOSED: before 0026 the live model answered 「えびとかにのアレルギーがありま
 * す」 with `{"allergens":["えび","かに"]}` — the prompt gave allergy no example, so the model
 * mirrored the writer's language — and the containment test below then looked for `えび_free`
 * against a venue recording `shellfish_free`. Zero candidates, and allergy is never relaxable,
 * so there was no proposal to escape through either.
 */
export const ALLERGEN_VOCABULARY = [
  'buckwheat',
  'egg',
  'milk',
  'peanut',
  'shellfish',
  'wheat',
] as const

/**
 * The closed dietary vocabulary, ported from `fn_dietary_vocabulary()` (0026). The same bug one
 * category over: for 「卵と乳製品がだめです」 the live model invented
 * `{"tags":["egg-free","dairy-free"]}`, which no `dietary_tags` value can ever match. Unlike
 * allergens these are *patterns a kitchen claims to cater for*, which is why `gluten_free` is
 * here and 小麦 is an allergen.
 */
export const DIETARY_VOCABULARY = ['gluten_free', 'halal', 'vegan', 'vegetarian'] as const

/** `room_type` / `{"room": …}` domain — `restaurant_features.room_type`'s CHECK (0001). */
const ROOM_TYPES = ['private', 'semi_private', 'open']

/**
 * Ports `fn_accessibility_needs_met` (0022): the accessibility predicate, in one place, so the
 * gate and the coverage count below cannot disagree.
 *
 * Unchanged from 0021: `needs` must be a non-empty array, the venue must have tags recorded,
 * and those tags must CONTAIN every need. No tags recorded means UNKNOWN, and unknown is not
 * step-free.
 */
function accessibilityNeedsMet(venueTags: string[], value: NormalizedValue): boolean {
  const needs = stringArray(value, 'needs')
  return (
    needs !== null && needs.length > 0 && venueTags.length > 0 && contains(venueTags, needs)
  )
}

/**
 * Ports `fn_allergy_allergens_met` (0026): the allergy predicate, in one place, so the gate and
 * the coverage count in `recomputeFeasibility` cannot disagree about what "unmet" means.
 *
 * Unchanged from 0009/0016/0021/0022 — this is that expression moved, not edited. `allergens`
 * must be a non-empty array (a MUST whose own value cannot be read is not one we may certify as
 * met), the venue must have tags recorded, and those tags must CONTAIN `<allergen>_free` for
 * every allergen. No tags recorded means UNKNOWN, and unknown is not safe (PRD §11).
 *
 * There is deliberately no `accept_unknown` escape of the kind `room` and `smoking` have: 0021
 * may ask a group to accept an unconfirmed smoking policy, but nobody may be asked to consent to
 * an unverified allergen claim. The escape is the coverage count plus a phone call
 * (`verification_requirement = 'required'`), never consent.
 */
function allergyAllergensMet(venueTags: string[], value: NormalizedValue): boolean {
  const allergens = stringArray(value, 'allergens')
  return (
    allergens !== null &&
    allergens.length > 0 &&
    venueTags.length > 0 &&
    contains(
      venueTags,
      allergens.map((allergen) => `${allergen}_free`),
    )
  )
}

/* -------------------------------------------------------------------------- */
/* fn_candidate_blocking_types / fn_candidate_is_feasible                      */
/* -------------------------------------------------------------------------- */

/**
 * Which MUST *types* stand between this event and this venue — `[]` meaning feasible. Ports
 * `fn_candidate_blocking_types` (0022), deduped and sorted exactly as the SQL returns it.
 *
 * It exists so that "0 candidates" can be explained rather than merely reported (a wheelchair
 * user must never be shown a silent empty result), and `candidateIsFeasible` is a wrapper over
 * it so there is one implementation of the MUST chain.
 *
 * `'unknown_venue'` is deliberately not a normalized_type: a place with no feature row was
 * infeasible before too, and this way no caller mistakes it for an accessibility-only
 * exclusion.
 */
export function candidateBlockingTypes(
  db: Db,
  eventId: string,
  placeId: string,
  overrideConstraintId?: string,
  overrideValue?: NormalizedValue,
): string[] {
  const candidate = db.features.find((feature) => feature.place_id === placeId)
  if (!candidate) return ['unknown_venue']

  const musts = db.constraints.filter(
    (constraint) => constraint.event_id === eventId && constraint.kind === 'MUST',
  )
  const blocked = new Set<string>()

  for (const must of musts) {
    const value =
      must.id === overrideConstraintId && overrideValue ? overrideValue : must.normalized_value

    if (must.normalized_type === 'budget') {
      if (
        candidate.price_yen_estimate === null ||
        exceeds(candidate.price_yen_estimate, nullableInt(value, 'max_yen'))
      ) {
        blocked.add('budget')
      }
    } else if (must.normalized_type === 'room') {
      // {"room": "private"|"semi_private"|"open"}, plus "accept_unknown": true once the
      // participant has accepted the relaxation step (see relaxedValue). Same three-part rule
      // as smoking since 0022: an unreadable preference is not a satisfied one, a venue whose
      // room_type is UNCONFIRMED (every Places-only candidate — Places has no private-room
      // field) passes only with the flag, and a venue KNOWN to be another room type always
      // fails, so consenting to 半個室 never admits a counter-only 大衆酒場.
      const wanted = nullableText(value, 'room')
      const roomType = candidate.room_type
      if (
        wanted === null ||
        !ROOM_TYPES.includes(wanted) ||
        (roomType === null && !flag(value, 'accept_unknown')) ||
        (roomType !== null && roomType !== wanted)
      ) {
        blocked.add('room')
      }
    } else if (must.normalized_type === 'dietary') {
      const tags = stringArray(value, 'tags')
      if (
        tags === null ||
        tags.length === 0 ||
        candidate.dietary_tags.length === 0 ||
        !contains(candidate.dietary_tags, tags)
      ) {
        blocked.add('dietary')
      }
    } else if (must.normalized_type === 'allergy') {
      // {"allergens": string[]} drawn from ALLERGEN_VOCABULARY (0026), against
      // restaurant_features.allergy_safe_tags' `<allergen>_free` claims. Never relaxable and
      // never granted an `accept_unknown` flag — see allergyAllergensMet. A venue with no tags
      // recorded is UNKNOWN, and `recomputeFeasibility` reports how many candidates are excluded
      // for exactly that reason so the zero is never silent.
      if (!allergyAllergensMet(candidate.allergy_safe_tags, value)) {
        blocked.add('allergy')
      }
    } else if (must.normalized_type === 'accessibility') {
      // {"needs": string[]} drawn from ACCESSIBILITY_VOCABULARY, against
      // restaurant_features.accessibility_tags. A venue with no tags recorded is UNKNOWN, and
      // unknown is not step-free. Before 0021 this MUST had no branch at all, so
      // 「車椅子で入れる店」 was silently satisfied while also being un-negotiable; it is still
      // never relaxable, so the only way a venue passes is recorded provider data.
      if (!accessibilityNeedsMet(candidate.accessibility_tags ?? [], value)) {
        blocked.add('accessibility')
      }
    } else if (must.normalized_type === 'smoking') {
      // {"preference": "non_smoking"|"smoking_ok"}, plus "accept_unknown": true once the
      // participant has accepted the relaxation step (see relaxedValue). An unreadable
      // preference is not a satisfied one, an unconfirmed venue only passes with the flag,
      // and a venue KNOWN to have the other policy always fails.
      const preference = nullableText(value, 'preference')
      const policy = candidate.smoking_policy ?? null
      if (
        preference === null ||
        (preference !== 'non_smoking' && preference !== 'smoking_ok') ||
        (policy === null && !flag(value, 'accept_unknown')) ||
        (policy !== null && policy !== preference)
      ) {
        blocked.add('smoking')
      }
    } else if (must.normalized_type === 'travel_time') {
      // coalesce(fn_travel_minutes(...), 9999): an unknown travel time fails a travel MUST
      // rather than passing it, and the lookup is event-scoped (0016).
      const minutes = travelMinutesFor(db, eventId, placeId, must.participant_id) ?? 9999
      if (exceeds(minutes, nullableInt(value, 'max_minutes'))) blocked.add('travel_time')
    }
  }

  return [...blocked].sort()
}

export function candidateIsFeasible(
  db: Db,
  eventId: string,
  placeId: string,
  overrideConstraintId?: string,
  overrideValue?: NormalizedValue,
): boolean {
  return (
    candidateBlockingTypes(db, eventId, placeId, overrideConstraintId, overrideValue).length === 0
  )
}

/* -------------------------------------------------------------------------- */
/* Scoring constants — fn_banded_score / fn_quality_signal / fn_cost_burden    */
/* -------------------------------------------------------------------------- */

/**
 * Scores derived from COMPLETE data live in [0.2, 1.0]; anything with a gap is squeezed
 * into [0, 0.2). Ports `fn_banded_score` (0016), and it is how "missing data must never
 * win" is enforced structurally rather than by hoping the arithmetic works out. The old
 * `round(1.0 / (1.0 + coalesce(travel_max - travel_min, 0)), 4)` handed a perfect 1.0000
 * to a venue with one (or zero) known travel times, beating a venue with a real
 * 5/30/75-minute spread at 0.0141.
 */
const COMPLETE_DATA_FLOOR = 0.2

/** 30 minutes between the luckiest and the unluckiest participant halves fairness credit. */
const TRAVEL_SPREAD_HALF_LIFE_MINUTES = 30

/** An average one-way trip of two hours earns no access credit at all. */
const TRAVEL_ACCESS_HORIZON_MINUTES = 120

/**
 * Bayesian prior for the quality signal: every venue starts out as "an average Tokyo
 * izakaya with 50 reviews", so a 5.0 from 3 reviews cannot beat a 4.3 from 800.
 */
const QUALITY_PRIOR_RATING = 3.9
const QUALITY_PRIOR_REVIEWS = 50
const RATING_MAX = 5

/**
 * Only used when nobody stated a budget MUST, so the `cost` objective still has a signal
 * to work with: a typical Tokyo 飲み会 per-head budget.
 */
const DEFAULT_BUDGET_REFERENCE_YEN = 6000

/**
 * Objective weight table — ports `fn_objective_weights` (0016). Each row sums to 1.0.
 *
 *   objective  | travel_fairness | travel_access | satisfaction | quality | cost_fit | accessibility_fit
 *   -----------+-----------------+---------------+--------------+---------+----------+------------------
 *   balanced   |            0.20 |          0.15 |         0.25 |    0.20 |     0.10 |              0.10
 *   access     |            0.25 |          0.35 |         0.10 |    0.05 |     0.10 |              0.15
 *   cost       |            0.10 |          0.10 |         0.15 |    0.10 |     0.45 |              0.10
 *   experience |            0.10 |          0.10 |         0.25 |    0.35 |     0.10 |              0.10
 *   custom     | = balanced
 *
 * WHY these numbers:
 *  - the 幹事's objective may only re-emphasize, never override: feasibility is decided by
 *    fn_candidate_is_feasible before any of this runs, so no weight can admit a venue that
 *    breaks a MUST;
 *  - every objective keeps a floor of 0.10 under travel_fairness and accessibility_fit, so
 *    "cheap" or "impressive" can never be bought by dumping the burden on one participant;
 *  - `access` splits its emphasis between raw proximity (travel_access) and equity
 *    (travel_fairness), and lifts accessibility_fit — step-free access is access too;
 *  - `custom` has no bespoke weights yet (nothing in the UI can express them), so it
 *    deliberately resolves to `balanced` instead of inventing a fifth profile.
 */
const BALANCED_WEIGHTS: ObjectiveWeights = {
  travel_fairness: 0.2,
  travel_access: 0.15,
  satisfaction: 0.25,
  quality: 0.2,
  cost_fit: 0.1,
  accessibility_fit: 0.1,
}

export const OBJECTIVE_WEIGHTS: Record<EventObjective, ObjectiveWeights> = {
  balanced: BALANCED_WEIGHTS,
  access: {
    travel_fairness: 0.25,
    travel_access: 0.35,
    satisfaction: 0.1,
    quality: 0.05,
    cost_fit: 0.1,
    accessibility_fit: 0.15,
  },
  cost: {
    travel_fairness: 0.1,
    travel_access: 0.1,
    satisfaction: 0.15,
    quality: 0.1,
    cost_fit: 0.45,
    accessibility_fit: 0.1,
  },
  experience: {
    travel_fairness: 0.1,
    travel_access: 0.1,
    satisfaction: 0.25,
    quality: 0.35,
    cost_fit: 0.1,
    accessibility_fit: 0.1,
  },
  custom: BALANCED_WEIGHTS,
}

const SCALE_NOTE = {
  components: '0..1, higher is better',
  burdens: '0..1, higher is worse',
}

/** `fn_banded_score(p_coverage, p_credit)`: complete data in [0.2,1], gaps in [0,0.2). */
function bandedScore(coverage: number, credit: number): number {
  const value = clamp01(credit)
  if (coverage >= 1) return round4(COMPLETE_DATA_FLOOR + (1 - COMPLETE_DATA_FLOOR) * value)
  return round4(COMPLETE_DATA_FLOOR * clamp01(coverage) * value)
}

/* -------------------------------------------------------------------------- */
/* fn_travel_profile / fn_quality_signal / fn_cost_burden / fn_accessibility_burden */
/* -------------------------------------------------------------------------- */

/** Ports `fn_travel_profile`: travel equity and proximity for one venue in one event. */
function travelProfile(db: Db, eventId: string, placeId: string): ScoreBreakdown['travel'] {
  const participants = db.participants.filter((row) => row.event_id === eventId)
  const known: number[] = []
  for (const participant of participants) {
    const minutes = travelMinutesFor(db, eventId, placeId, participant.id)
    if (minutes !== null) known.push(minutes)
  }

  const total = participants.length
  const spread = known.length >= 2 ? Math.max(...known) - Math.min(...known) : 0
  const average =
    known.length > 0 ? known.reduce((sum, value) => sum + value, 0) / known.length : null
  // Coverage is over the event's participants, not over the JSONB map: a stale key from
  // another event must not count as data about this group.
  const coverage = total === 0 ? 1 : known.length / total
  const fairnessCredit = 1 / (1 + spread / TRAVEL_SPREAD_HALF_LIFE_MINUTES)
  const accessCredit = average === null ? 0 : 1 - average / TRAVEL_ACCESS_HORIZON_MINUTES

  return {
    participants: total,
    known: known.length,
    spread_minutes: spread,
    average_minutes: average === null ? null : round4(average),
    complete: coverage >= 1,
    fairness: bandedScore(coverage, fairnessCredit),
    access: bandedScore(coverage, accessCredit),
  }
}

/**
 * Ports `fn_quality_signal`: a review-volume-adjusted quality signal.
 *
 * quality = shrink(rating, n) / 5 with shrink(r, n) = (50 * 3.9 + r * n) / (50 + n), so a
 * 5.0 from 3 reviews lands at 0.79 while a 4.3 from 800 lands at 0.86. Google's scale
 * starts at 1.0 and the field is absent for unrated places, so `rating <= 0` or a zero
 * review count means "no signal", not "terrible": those fall back to the historical
 * atmosphere-tag proxy, capped at COMPLETE_DATA_FLOOR so an unrated venue can never
 * outscore a rated one (a rated venue is always > 0.2 because shrink() > 1).
 */
function qualitySignal(feature: FeatureRow): ScoreBreakdown['quality'] {
  const rating =
    typeof feature.rating === 'number' && Number.isFinite(feature.rating) ? feature.rating : null
  const count =
    typeof feature.user_rating_count === 'number' && Number.isFinite(feature.user_rating_count)
      ? Math.trunc(feature.user_rating_count)
      : null
  const tags = Math.min(feature.atmosphere_tags.length, 3)

  const shared = {
    rating,
    user_rating_count: count,
    prior_rating: QUALITY_PRIOR_RATING,
    prior_reviews: QUALITY_PRIOR_REVIEWS,
    atmosphere_tags: tags,
  }

  if (rating !== null && rating > 0 && count !== null && count > 0) {
    const clamped = Math.min(RATING_MAX, Math.max(1, rating))
    const shrunk =
      (QUALITY_PRIOR_REVIEWS * QUALITY_PRIOR_RATING + clamped * count) /
      (QUALITY_PRIOR_REVIEWS + count)
    const method: QualityMethod = 'rating_bayesian_shrunk'
    return { score: round4(clamp01(shrunk / RATING_MAX)), method, ...shared }
  }

  const method: QualityMethod = 'atmosphere_tag_proxy'
  return { score: round4(COMPLETE_DATA_FLOOR * (tags / 3)), method, ...shared }
}

/**
 * Ports `fn_cost_burden`: how unfairly the price sits against the participants' budget
 * MUSTs. The tightest budget in the group decides — a venue at the very top of it burdens
 * that one person far more than a venue comfortably under everyone's ceiling — and an
 * unknown price is scored as the worst case rather than as free.
 */
function costBurden(db: Db, eventId: string, feature: FeatureRow): ScoreBreakdown['cost'] {
  const limits = db.constraints
    .filter(
      (constraint) =>
        constraint.event_id === eventId &&
        constraint.kind === 'MUST' &&
        constraint.normalized_type === 'budget',
    )
    .map((constraint) => nullableInt(constraint.normalized_value, 'max_yen'))
    .filter((value): value is number => value !== null && value > 0)

  const price = feature.price_yen_estimate
  const tightest = limits.length > 0 ? Math.min(...limits) : null
  const reference = tightest ?? DEFAULT_BUDGET_REFERENCE_YEN
  const burden = price === null ? 1 : clamp01(price / reference)

  return {
    burden: round4(burden),
    price_yen: price,
    tightest_budget_yen: tightest,
    budget_musts: limits.length,
    reference_yen: reference,
  }
}

/**
 * Ports `fn_accessibility_burden`. Both MUST and WANT accessibility rows count. Since 0021 a
 * MUST is also a hard gate in candidateIsFeasible, so this no longer carries the whole
 * weight of the requirement — but a WANT still has nowhere else to be honoured, and among
 * venues that all clear the MUST this is what orders "meets more of the group's needs" first.
 *
 * A venue with no accessibility data at all is treated as UNKNOWN — full burden — never as
 * "supported". The worst-affected request set decides, so one participant whose needs are
 * entirely unmet is not averaged away by four who need nothing.
 */
function accessibilityBurden(
  db: Db,
  eventId: string,
  feature: FeatureRow,
): ScoreBreakdown['accessibility'] {
  const venueTags = feature.accessibility_tags ?? []
  const requests = db.constraints
    .filter(
      (constraint) =>
        constraint.event_id === eventId && constraint.normalized_type === 'accessibility',
    )
    .map((constraint) => stringArray(constraint.normalized_value, 'needs') ?? [])
    .filter((needs) => needs.length > 0)

  const needs = [...new Set(requests.flat())].sort()
  const unmet = needs.filter((need) => !venueTags.includes(need))
  const burden =
    requests.length === 0
      ? 0
      : Math.max(
          ...requests.map(
            (set) => set.filter((need) => !venueTags.includes(need)).length / set.length,
          ),
        )

  return {
    burden: round4(burden),
    needs,
    unmet_needs: unmet,
    venue_tags: venueTags,
    data_present: venueTags.length > 0,
    requests: requests.length,
  }
}

/* -------------------------------------------------------------------------- */
/* fn_score_feasible_candidates                                                */
/* -------------------------------------------------------------------------- */

export function scoreFeasibleCandidates(
  db: Db,
  runId: string,
  eventId: string,
  newId: () => string,
): void {
  const wants = db.constraints.filter(
    (constraint) => constraint.event_id === eventId && constraint.kind === 'WANT',
  )
  const wantCount = wants.length

  // The 幹事's objective decides emphasis only; the candidate set was already filtered by
  // fn_candidate_is_feasible, so weights can never resurrect an infeasible venue.
  const objective = db.events.find((event) => event.id === eventId)?.objective ?? 'balanced'
  const weights = OBJECTIVE_WEIGHTS[objective] ?? BALANCED_WEIGHTS

  const rows = db.restaurants
    .map((restaurant) => db.features.find((feature) => feature.place_id === restaurant.place_id))
    .filter((feature): feature is FeatureRow => feature !== undefined)
    .filter((feature) => candidateIsFeasible(db, eventId, feature.place_id))
    .map((feature) => {
      const wantsMatched = wants.filter((want) => {
        if (want.normalized_type === 'cuisine') {
          const include = stringArray(want.normalized_value, 'include') ?? []
          const exclude = stringArray(want.normalized_value, 'exclude') ?? []
          const included = include.length === 0 || overlaps(feature.cuisine_tags, include)
          const excluded = overlaps(feature.cuisine_tags, exclude)
          return included && !excluded
        }
        if (want.normalized_type === 'atmosphere') {
          const tags = stringArray(want.normalized_value, 'tags') ?? []
          return overlaps(feature.atmosphere_tags, tags)
        }
        return false
      }).length

      const travel = travelProfile(db, eventId, feature.place_id)
      const quality = qualitySignal(feature)
      const cost = costBurden(db, eventId, feature)
      const accessibility = accessibilityBurden(db, eventId, feature)

      const components: Record<ScoreDimension, number> = {
        travel_fairness: travel.fairness,
        travel_access: travel.access,
        satisfaction: wantCount === 0 ? 1 : round4(wantsMatched / wantCount),
        quality: quality.score,
        cost_fit: round4(1 - cost.burden),
        accessibility_fit: round4(1 - accessibility.burden),
      }
      const contributions = Object.fromEntries(
        SCORE_DIMENSIONS.map((dimension) => [
          dimension,
          round4(weights[dimension] * components[dimension]),
        ]),
      ) as Record<ScoreDimension, number>
      const objectiveScore = round4(
        SCORE_DIMENSIONS.reduce(
          (sum, dimension) => sum + weights[dimension] * components[dimension],
          0,
        ),
      )

      const breakdown: ScoreBreakdown = {
        version: 1,
        objective,
        scale: { ...SCALE_NOTE },
        weights: { ...weights },
        components,
        contributions,
        objective_score: objectiveScore,
        travel,
        quality,
        cost,
        accessibility,
      }

      return { feature, components, quality, cost, accessibility, objectiveScore, breakdown }
    })
    // order by objective_score desc, place_id — the objective now decides which of the
    // feasible venues make the 3–5 cards, not just the raw WANT count.
    .sort(
      (a, b) =>
        b.objectiveScore - a.objectiveScore ||
        a.feature.place_id.localeCompare(b.feature.place_id),
    )
    .slice(0, 5)

  for (const row of rows) {
    db.scores.push({
      id: newId(),
      run_id: runId,
      restaurant_place_id: row.feature.place_id,
      fairness_score: row.components.travel_fairness,
      satisfaction_score: row.components.satisfaction,
      quality_score: row.quality.score,
      cost_burden_score: row.cost.burden,
      accessibility_burden_score: row.accessibility.burden,
      objective_score: row.objectiveScore,
      score_breakdown: row.breakdown,
      label: null,
      explanation: null,
    })
  }

  assignHonestLabels(db, runId)
}

/* -------------------------------------------------------------------------- */
/* Labels                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * The metric each badge claims, in the fixed order labels are considered. Every metric is
 * "higher is better"; `best_value` reads cost_fit rather than the raw price because that is
 * the same ordering measured against the group's tightest budget, and it makes an unknown
 * price ineligible instead of merely last.
 */
const LABEL_METRICS: Array<[RecommendationLabel, (row: ScoreRow) => number | null]> = [
  ['fairest', (row) => row.fairness_score],
  ['best_access', (row) => row.score_breakdown?.components.travel_access ?? null],
  ['best_value', (row) => row.score_breakdown?.components.cost_fit ?? null],
  ['best_experience', (row) => row.quality_score],
  ['crowd_pleaser', (row) => row.satisfaction_score],
]

/**
 * Honest label assignment, ported from the label loop in 0016.
 *
 * The old greedy pass gave each label to the best STILL-UNLABELLED row, so the badges lied:
 * a venue with a 75-minute commute for one participant was labelled `best_access` only
 * because the better venue had already taken `fairest`. Now a badge is written only when the
 * row genuinely leads that metric:
 *  - a row with no value for the metric can never lead it;
 *  - if every row has the same value the metric separates nothing, so the badge is dropped
 *    — there is no "most X" to claim;
 *  - ties are legitimate co-leaders; the first by place_id that is still unlabelled takes it;
 *  - if every genuine leader already carries a badge, the label goes unused rather than
 *    being handed to a row that does not deserve it. Fewer than five labels is expected,
 *    and the UI already renders a null label as the neutral 「おすすめ」 badge.
 */
function assignHonestLabels(db: Db, runId: string): void {
  const rows = db.scores.filter((score) => score.run_id === runId)

  for (const [label, metric] of LABEL_METRICS) {
    const values = rows.map(metric).filter((value): value is number => value !== null)
    if (values.length === 0) continue

    const best = Math.max(...values)
    const leaders = rows.filter((row) => metric(row) === best)
    if (leaders.length === rows.length) continue

    const winner = leaders
      .slice()
      .sort((a, b) => a.restaurant_place_id.localeCompare(b.restaurant_place_id))
      .find((row) => row.label === null)
    if (winner) winner.label = label
  }
}

/* -------------------------------------------------------------------------- */
/* fn_recompute_feasibility                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Ports `fn_recompute_feasibility` (0026, itself 0022's definition of 0018's).
 *
 * `accessibility_unverified_count` (0022) and `allergy_unverified_count` (0026) are the two keys
 * added since, and no existing key changed meaning — the web and Swift clients decode this
 * payload, so adding a key is the only backwards-compatible way to say something new.
 *
 * Each counts the candidates whose ONLY unmet MUSTs are of that one type: the venues that would
 * be on the shortlist if somebody could confirm the thing nobody has recorded. They are the
 * honest numbers behind 「N件は車椅子対応が確認できませんでした（お店に確認できます）」 and
 * 「N件はアレルギー対応が確認できませんでした（お店に確認できます）」, and they are why a
 * wheelchair user or somebody with a shellfish allergy is never shown a bare 「0件」 — neither
 * MUST is relaxable, so without them there is nothing to show and nothing to do.
 *
 * Both deliberately exclude venues that also break another MUST (a phone call would not make
 * those available), and both are 0 for an event that stated no MUST of that type — including the
 * five-persona demo, where Emma's shellfish MUST is met by every seeded venue.
 *
 * "Unverified" rather than "unsuitable" is accurate in both dimensions for the same reason: only
 * POSITIVE claims are ever recorded (`accessibility_tags`, `<allergen>_free`), so a requirement
 * the recorded data does not cover is unconfirmed, never confirmed-absent. On the allergy side
 * that is the normal case rather than an edge one — no provider anywhere supplies restaurant
 * allergen data (see 0026's header for the survey), so every live candidate arrives with `[]`.
 */
export function recomputeFeasibility(
  db: Db,
  eventId: string,
  newId: () => string,
  now: () => string,
): {
  run_id: string
  feasible_count: number
  accessibility_unverified_count: number
  allergy_unverified_count: number
} {
  let feasibleCount = 0
  let accessibilityUnverifiedCount = 0
  let allergyUnverifiedCount = 0
  const candidates = db.restaurants
    .slice()
    .sort((a, b) => a.place_id.localeCompare(b.place_id))
    .filter((restaurant) => db.features.some((feature) => feature.place_id === restaurant.place_id))
  for (const restaurant of candidates) {
    const blocked = candidateBlockingTypes(db, eventId, restaurant.place_id)
    if (blocked.length === 0) feasibleCount += 1
    else if (blocked.length === 1 && blocked[0] === 'accessibility') {
      accessibilityUnverifiedCount += 1
    } else if (blocked.length === 1 && blocked[0] === 'allergy') {
      allergyUnverifiedCount += 1
    }
  }

  const runId = newId()
  db.runs.push({
    id: runId,
    event_id: eventId,
    run_at: now(),
    feasible_count: feasibleCount,
    input_snapshot: {
      must_count: db.constraints.filter(
        (constraint) => constraint.event_id === eventId && constraint.kind === 'MUST',
      ).length,
    },
  })

  if (feasibleCount > 0) scoreFeasibleCandidates(db, runId, eventId, newId)

  return {
    run_id: runId,
    feasible_count: feasibleCount,
    accessibility_unverified_count: accessibilityUnverifiedCount,
    allergy_unverified_count: allergyUnverifiedCount,
  }
}

/* -------------------------------------------------------------------------- */
/* Relaxation                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * The single relaxation step the engine is willing to propose, per constraint type. Ports
 * `fn_relaxed_value` (0022, itself 0021's), which is also what `proposeRelaxation` compares a
 * REJECTED proposal against — so "what would we offer" and "what did we offer" cannot drift.
 *
 *   room         private → semi_private (a divider instead of a door) AND accept an
 *                UNCONFIRMED venue
 *   travel_time  +10 minutes
 *   budget       +500 yen
 *   smoking      keep the preference, accept an UNCONFIRMED venue
 *
 * WHY the smoking step is `accept_unknown` and nothing else: no provider fills
 * `smoking_policy`, so a fail-closed smoking MUST is unsatisfiable and — with no step —
 * `countUnlockedIfRelaxed` would return 0, no proposal would ever be offered, and the group
 * would be left with zero candidates and no question to answer. What actually blocks those
 * venues is missing data, not a known conflict, so the honest question is 「禁煙が確認できて
 * いないお店も候補に入れてよいですか？」 (the constraint already carries
 * verification_requirement = 'recommended', the UI's cue to suggest phoning the venue). It
 * never trades away what was asked for: a venue known to be 喫煙可 still fails a
 * non_smoking MUST afterwards. accessibility and allergy deliberately have NO step — they stay
 * on NEVER_RELAXED, because accepting an unverified step-free entrance is accepting the risk of
 * not getting in, and accepting an unverified allergen claim is accepting a medical risk on the
 * strength of data that (0026) no provider on earth publishes. For both, the escape hatch is
 * human verification and the coverage counts in `recomputeFeasibility`, not a negotiation.
 *
 * WHY THE TWO ROOM CONCESSIONS ARE ONE STEP (0022). `room_type` is filled only from Hot
 * Pepper, so every Places-only candidate has it NULL and a 個室 MUST used to be infeasible
 * before AND after the private → semi_private step — 0 unlocked, no proposal, dead end. Both
 * two-rung orderings were considered and each is unreachable in one of the two worlds this
 * engine serves: widening first unlocks nothing when every room_type is NULL (so the second
 * rung is never reached, because `proposeRelaxation` returns null on a step that unlocks 0),
 * and accepting unknown first unlocks nothing on the seeded demo where every venue HAS a
 * room_type (so Bob is never asked and the 0-then-3 invariant dies). This function is a pure
 * function of (type, value) by design and cannot look at the candidate pool to pick a rung, so
 * the two concessions are composed into one reachable question, which also asks the
 * participant once rather than twice. It still never trades away what was asked: the room type
 * is checked whenever the venue HAS one, so an accepted step admits confirmed 半個室 and
 * unconfirmed venues, never a venue known to be `open`.
 *
 * A type with no step returns its value unchanged, so countUnlockedIfRelaxed measures a
 * no-op and reports 0 unlocked. Relaxing an already-relaxed room value is likewise a no-op,
 * so the ladder terminates instead of being re-asked forever.
 */
export function relaxedValue(constraint: ConstraintRow): NormalizedValue {
  switch (constraint.normalized_type) {
    case 'room': {
      // `(value->>'room')` is carried over verbatim for anything that is not 'private', so an
      // unreadable room stays unreadable (null): the relaxed value is then still infeasible
      // and never gets proposed, exactly as with an unreadable smoking preference.
      const current = nullableText(constraint.normalized_value, 'room')
      return { room: current === 'private' ? 'semi_private' : current, accept_unknown: true }
    }
    case 'travel_time': {
      const current = nullableInt(constraint.normalized_value, 'max_minutes')
      return { max_minutes: (current ?? 0) + 10 }
    }
    case 'budget': {
      const current = nullableInt(constraint.normalized_value, 'max_yen')
      return { max_yen: (current ?? 0) + 500 }
    }
    case 'smoking':
      // `(value->>'preference')` is carried over verbatim: an unreadable preference stays
      // unreadable, so the relaxed value is still infeasible and never gets proposed. We do
      // not invent a preference on somebody's behalf.
      return {
        preference: nullableText(constraint.normalized_value, 'preference'),
        accept_unknown: true,
      }
    default:
      return constraint.normalized_value
  }
}

export function countUnlockedIfRelaxed(db: Db, eventId: string, constraintId: string): number {
  const constraint = db.constraints.find(
    (row) => row.id === constraintId && row.event_id === eventId,
  )
  if (!constraint) throw new Error('constraint not found')

  const relaxed = relaxedValue(constraint)
  const withFeatures = db.restaurants.filter((restaurant) =>
    db.features.some((feature) => feature.place_id === restaurant.place_id),
  )

  const baseline = withFeatures.filter((restaurant) =>
    candidateIsFeasible(db, eventId, restaurant.place_id),
  ).length
  const relaxedCount = withFeatures.filter((restaurant) =>
    candidateIsFeasible(db, eventId, restaurant.place_id, constraintId, relaxed),
  ).length

  return relaxedCount - baseline
}

/**
 * SAFETY RULE — hardcoded, exactly as in SQL: allergy / dietary / accessibility MUSTs
 * are NEVER eligible for relaxation, no exceptions.
 */
const NEVER_RELAXED: NormalizedType[] = ['allergy', 'dietary', 'accessibility']

/**
 * Ports `fn_propose_relaxation` (0021), including its three idempotency rules:
 *
 *  1. an OPEN proposal is returned, never duplicated. Pressing 「条件に合うお店を探す」 four
 *     times while feasible = 0 used to write four identical PROPOSED rows and ask the same
 *     participant the same question four times, which the PRD forbids;
 *  2. if the open proposal targets a DIFFERENT constraint than the one now judged best, the
 *     open one still wins and nothing is written. Retargeting would withdraw a question
 *     somebody is looking at, or put a second question to a second person while the first is
 *     unanswered — and since each unlocked_count assumes every other MUST is unchanged, two
 *     acceptances relax more than the group needed. Answering the open proposal takes it out
 *     of PROPOSED and the next call re-ranks from scratch, so the better target is deferred
 *     one round, not dropped;
 *  3. a step already REJECTED is never offered again ("on rejection, keep the MUST and do not
 *     pressure repeatedly"). Matched on (constraint, proposed value) rather than the
 *     constraint alone, so "no" means no to THAT question: if the participant later edits
 *     their own MUST the step differs and asking it is a new question, and a single "no" does
 *     not blacklist the constraint forever and dead-end the event.
 *
 * In SQL rule 1 is additionally a partial unique index on `negotiations (event_id) where
 * status = 'PROPOSED'`, so a concurrent double-press cannot slip past the check. There is no
 * concurrency here (one JS event loop, one localStorage snapshot), so the check is the whole
 * mechanism.
 */
export function proposeRelaxation(
  db: Db,
  eventId: string,
  newId: () => string,
  now: () => string,
): string | null {
  // Reuse before propose.
  const open = db.negotiations
    .filter((row) => row.event_id === eventId && row.status === 'PROPOSED')
    .sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id))[0]
  if (open) return open.id

  const candidates = db.constraints
    .filter(
      (constraint) =>
        constraint.event_id === eventId &&
        constraint.kind === 'MUST' &&
        !NEVER_RELAXED.includes(constraint.normalized_type) &&
        !db.negotiations.some(
          (row) =>
            row.constraint_id === constraint.id &&
            row.status === 'REJECTED' &&
            sameValue(row.proposed_value, relaxedValue(constraint)),
        ),
    )
    .sort((a, b) => a.id.localeCompare(b.id))

  let bestUnlocked = -1
  let best: ConstraintRow | undefined

  for (const candidate of candidates) {
    const unlocked = countUnlockedIfRelaxed(db, eventId, candidate.id)
    if (unlocked > bestUnlocked) {
      bestUnlocked = unlocked
      best = candidate
    }
  }

  // Nothing eligible unlocks anything: hand off to the human 幹事, do not force a proposal.
  if (!best || bestUnlocked <= 0) return null

  const negotiationId = newId()
  db.negotiations.push({
    id: negotiationId,
    event_id: eventId,
    constraint_id: best.id,
    participant_id: best.participant_id,
    proposed_value: relaxedValue(best),
    unlocked_count: bestUnlocked,
    status: 'PROPOSED',
    created_at: now(),
    responded_at: null,
  })
  return negotiationId
}
