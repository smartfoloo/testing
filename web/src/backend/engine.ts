/**
 * TypeScript port of the deterministic feasibility / scoring / relaxation engine
 * defined in AIKanji/supabase/migrations/0009_review_function_replacements.sql
 * (which supersedes the original 0005_feasibility.sql).
 *
 * This exists so the mock backend behaves the same as the real Postgres one: the LLM
 * never decides feasibility or which MUST gets relaxed, it is all deterministic here too.
 *
 * SQL semantics that are deliberately reproduced:
 *  - a MUST of a type with no branch below (smoking, accessibility, cuisine, atmosphere,
 *    other) is silently satisfied, exactly as the `if/elsif` chain does;
 *  - `(value->>'key')::int` on a missing key yields SQL NULL, and `x > NULL` is NULL,
 *    which `if` treats as false — so the MUST passes. `nullableInt` + `exceeds` model that;
 *  - `is distinct from` is null-safe inequality;
 *  - `@>` is array containment, `&&` is array overlap;
 *  - labels are assigned greedily in a fixed order to the best still-unlabelled row.
 */

import type {
  ConstraintKind,
  ConstraintVisibility,
  EventObjective,
  EventStatus,
  NormalizedType,
  NormalizedValue,
  NegotiationStatus,
  ParticipantRole,
  RecommendationLabel,
  TravelReference,
} from '../models/types'

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
}

/* -------------------------------------------------------------------------- */
/* SQL-ish helpers                                                             */
/* -------------------------------------------------------------------------- */

/** `(jsonb->>'key')::int` — SQL NULL for a missing key or a non-numeric value. */
function nullableInt(value: NormalizedValue, key: string): number | null {
  const raw = value[key]
  if (raw === undefined || raw === null) return null
  const parsed = typeof raw === 'number' ? raw : Number.parseInt(String(raw), 10)
  return Number.isFinite(parsed) ? Math.trunc(parsed) : null
}

/** `left > right` where a NULL right-hand side makes the whole predicate NULL (falsey). */
function exceeds(left: number, right: number | null): boolean {
  if (right === null) return false
  return left > right
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

function travelMinutes(feature: FeatureRow): number[] {
  return Object.values(feature.travel_minutes_by_participant).filter((value) =>
    Number.isFinite(value),
  )
}

/* -------------------------------------------------------------------------- */
/* fn_candidate_is_feasible                                                    */
/* -------------------------------------------------------------------------- */

export function candidateIsFeasible(
  db: Db,
  eventId: string,
  placeId: string,
  overrideConstraintId?: string,
  overrideValue?: NormalizedValue,
): boolean {
  const candidate = db.features.find((feature) => feature.place_id === placeId)
  if (!candidate) return false

  const musts = db.constraints.filter(
    (constraint) => constraint.event_id === eventId && constraint.kind === 'MUST',
  )

  for (const must of musts) {
    const value =
      must.id === overrideConstraintId && overrideValue ? overrideValue : must.normalized_value

    if (must.normalized_type === 'budget') {
      if (
        candidate.price_yen_estimate === null ||
        exceeds(candidate.price_yen_estimate, nullableInt(value, 'max_yen'))
      ) {
        return false
      }
    } else if (must.normalized_type === 'room') {
      const wanted = typeof value.room === 'string' ? value.room : null
      if (candidate.room_type !== wanted) return false
    } else if (must.normalized_type === 'dietary') {
      const tags = stringArray(value, 'tags')
      if (
        tags === null ||
        tags.length === 0 ||
        candidate.dietary_tags.length === 0 ||
        !contains(candidate.dietary_tags, tags)
      ) {
        return false
      }
    } else if (must.normalized_type === 'allergy') {
      const allergens = stringArray(value, 'allergens')
      if (
        allergens === null ||
        allergens.length === 0 ||
        candidate.allergy_safe_tags.length === 0 ||
        !contains(
          candidate.allergy_safe_tags,
          allergens.map((allergen) => `${allergen}_free`),
        )
      ) {
        return false
      }
    } else if (must.normalized_type === 'travel_time') {
      const minutes = candidate.travel_minutes_by_participant[must.participant_id] ?? 9999
      if (exceeds(minutes, nullableInt(value, 'max_minutes'))) return false
    }
  }

  return true
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

      const minutes = travelMinutes(feature)
      const travelMax = minutes.length > 0 ? Math.max(...minutes) : null
      const travelMin = minutes.length > 0 ? Math.min(...minutes) : null
      const spread = travelMax !== null && travelMin !== null ? travelMax - travelMin : 0

      return {
        feature,
        wantsMatched,
        fairness: round4(1 / (1 + spread)),
        satisfaction: wantCount === 0 ? 1 : round4(wantsMatched / wantCount),
        quality: round4(Math.min(feature.atmosphere_tags.length, 3) / 3),
      }
    })
    // order by c.wants_matched desc, c.place_id
    .sort(
      (a, b) =>
        b.wantsMatched - a.wantsMatched || a.feature.place_id.localeCompare(b.feature.place_id),
    )
    .slice(0, 5)

  for (const row of rows) {
    db.scores.push({
      id: newId(),
      run_id: runId,
      restaurant_place_id: row.feature.place_id,
      fairness_score: row.fairness,
      satisfaction_score: row.satisfaction,
      quality_score: row.quality,
      label: null,
      explanation: null,
    })
  }

  const unlabelled = () => db.scores.filter((score) => score.run_id === runId && score.label === null)
  const featureFor = (score: ScoreRow) =>
    db.features.find((feature) => feature.place_id === score.restaurant_place_id)
  const averageTravel = (score: ScoreRow): number | null => {
    const feature = featureFor(score)
    if (!feature) return null
    const minutes = travelMinutes(feature)
    if (minutes.length === 0) return null
    return minutes.reduce((sum, value) => sum + value, 0) / minutes.length
  }

  /** `order by <metric> ... , restaurant_place_id limit 1` then `set label = ...`. */
  const assign = (
    label: RecommendationLabel,
    compare: (a: ScoreRow, b: ScoreRow) => number,
  ): void => {
    const [winner] = unlabelled().sort(
      (a, b) => compare(a, b) || a.restaurant_place_id.localeCompare(b.restaurant_place_id),
    )
    if (winner) winner.label = label
  }

  const descending = (pick: (score: ScoreRow) => number | null) => (a: ScoreRow, b: ScoreRow) =>
    (pick(b) ?? 0) - (pick(a) ?? 0)

  /** `asc nulls last` */
  const ascendingNullsLast =
    (pick: (score: ScoreRow) => number | null) => (a: ScoreRow, b: ScoreRow) => {
      const left = pick(a)
      const right = pick(b)
      if (left === null && right === null) return 0
      if (left === null) return 1
      if (right === null) return -1
      return left - right
    }

  assign('fairest', descending((score) => score.fairness_score))
  assign('best_access', ascendingNullsLast(averageTravel))
  assign('best_value', ascendingNullsLast((score) => featureFor(score)?.price_yen_estimate ?? null))
  assign('best_experience', descending((score) => score.quality_score))
  assign('crowd_pleaser', descending((score) => score.satisfaction_score))
}

/* -------------------------------------------------------------------------- */
/* fn_recompute_feasibility                                                    */
/* -------------------------------------------------------------------------- */

export function recomputeFeasibility(
  db: Db,
  eventId: string,
  newId: () => string,
  now: () => string,
): { run_id: string; feasible_count: number } {
  const feasibleCount = db.restaurants
    .slice()
    .sort((a, b) => a.place_id.localeCompare(b.place_id))
    .filter((restaurant) => db.features.some((feature) => feature.place_id === restaurant.place_id))
    .filter((restaurant) => candidateIsFeasible(db, eventId, restaurant.place_id)).length

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

  return { run_id: runId, feasible_count: feasibleCount }
}

/* -------------------------------------------------------------------------- */
/* Relaxation                                                                  */
/* -------------------------------------------------------------------------- */

/** The single relaxation step the engine is willing to propose, per constraint type. */
export function relaxedValue(constraint: ConstraintRow): NormalizedValue {
  switch (constraint.normalized_type) {
    case 'room':
      return { room: 'semi_private' }
    case 'travel_time': {
      const current = nullableInt(constraint.normalized_value, 'max_minutes')
      return { max_minutes: (current ?? 0) + 10 }
    }
    case 'budget': {
      const current = nullableInt(constraint.normalized_value, 'max_yen')
      return { max_yen: (current ?? 0) + 500 }
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

export function proposeRelaxation(
  db: Db,
  eventId: string,
  newId: () => string,
  now: () => string,
): string | null {
  const candidates = db.constraints
    .filter(
      (constraint) =>
        constraint.event_id === eventId &&
        constraint.kind === 'MUST' &&
        !NEVER_RELAXED.includes(constraint.normalized_type),
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
