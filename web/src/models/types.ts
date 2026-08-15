/**
 * Ported from AIKanji/AIKanji/Models/*.swift.
 *
 * Wire names (snake_case) are preserved exactly, because these types are decoded
 * straight from Supabase RPC/table responses and from the realtime broadcast payloads.
 */

/** Codable representation of an arbitrary Postgres `jsonb` value (Models/JSONValue.swift). */
export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue }

export type NormalizedValue = Record<string, JSONValue>

export type ConstraintKind = 'MUST' | 'WANT'
export const CONSTRAINT_KINDS: ConstraintKind[] = ['MUST', 'WANT']

export type NormalizedType =
  | 'budget'
  | 'cuisine'
  | 'dietary'
  | 'allergy'
  | 'smoking'
  | 'room'
  | 'travel_time'
  | 'accessibility'
  | 'atmosphere'
  | 'other'

export const NORMALIZED_TYPES: NormalizedType[] = [
  'budget',
  'cuisine',
  'dietary',
  'allergy',
  'smoking',
  'room',
  'travel_time',
  'accessibility',
  'atmosphere',
  'other',
]

export type ConstraintVisibility = 'PUBLIC' | 'ANONYMOUS' | 'PRIVATE'

export type EventObjective = 'balanced' | 'access' | 'cost' | 'experience' | 'custom'
export const EVENT_OBJECTIVES: EventObjective[] = ['balanced', 'access', 'cost', 'experience', 'custom']

export type EventStatus = 'collecting' | 'negotiating' | 'ready' | 'closed'

export type ParticipantRole = 'organizer' | 'participant'

export type TravelReference = 'office' | 'home' | 'station' | 'doesnt_matter'
/**
 * PRD §4 lists all four as valid travel references. `doesnt_matter` imposes no travel
 * constraint, so the backend excludes those participants from the origins set.
 */
export const TRAVEL_REFERENCES: TravelReference[] = ['office', 'home', 'station', 'doesnt_matter']
/** Kept for callers that only offer the three location-bearing options. */
export const SELECTABLE_TRAVEL_REFERENCES: TravelReference[] = ['office', 'home', 'station']

/** A place candidate from the `place-search` Edge Function, for the travel-reference picker. */
export interface PlaceSuggestion {
  place_id: string
  name: string
  address: string | null
}

/**
 * A participant's own travel reference: the UI category and the place it stands for.
 * PRD §4 calls this context — "not itself a constraint; changeable later" — so it is
 * readable and writable after joining, through `fn_set_travel_reference` (0020).
 *
 * `travel_reference_place_id` is what actually gives the participant a travel origin.
 * Null means the backend has no origin for them and reports them as unresolved rather
 * than geocoding the word 「会社」.
 */
export interface ParticipantTravel {
  travel_reference: TravelReference | null
  travel_reference_place_id: string | null
}

/** How sensitive a requirement is. Advisory metadata; the participant still owns visibility. */
export type ConstraintSensitivity = 'normal' | 'sensitive' | 'highly_sensitive'

/** Whether a MUST needs external confirmation before it can be trusted (PRD §11). */
export type VerificationRequirement = 'none' | 'recommended' | 'required'

/** Response of the `llm-assist` Edge Function in `parse` mode. */
export interface ParseResult {
  normalized_type: NormalizedType
  normalized_value: NormalizedValue
  suggested_visibility: Exclude<ConstraintVisibility, 'PRIVATE'>
  confidence: number
  needs_clarification: boolean
  /**
   * The participant's own wording that the structured taxonomy did not capture. Kept so
   * P1 semantic matching has something to embed; withheld from the sanitized feed because
   * it is verbatim human text.
   */
  semantic_remainder: string | null
  /** Server-assigned from normalized_type — the model is not trusted with these. */
  sensitivity: ConstraintSensitivity
  verification_requirement: VerificationRequirement
}

/** Payload of `fn_get_collection_readiness` (PRD §12 progressive search). */
export interface CollectionReadiness {
  participant_count: number
  responded_count: number
  threshold_count: number
  threshold_met: boolean
  provisional_ready: boolean
  preferences_closed: boolean
  preferences_closed_at: string | null
}

/**
 * A row of the sanitized group feed: either from `fn_get_sanitized_feed` or a broadcast
 * payload. `display_name` is null for ANONYMOUS entries — the name is stripped
 * server-side, not hidden here.
 */
export interface FeedItem {
  id: string
  kind: ConstraintKind
  normalized_type: NormalizedType
  normalized_value: NormalizedValue
  visibility: ConstraintVisibility
  display_name: string | null
  created_at: string
}

export interface SavedConstraint {
  id: string
  kind: ConstraintKind
  raw_text: string
}

export interface Event {
  id: string
  name: string
  invite_code: string
  organizer_participant_id: string | null
  objective: EventObjective
  status: EventStatus
  created_at: string
}

/** Payload returned by the `fn_create_event` RPC. */
export interface CreatedEvent {
  event_id: string
  invite_code: string
  participant_id: string
}

export interface EventDecision {
  chosen_place_id: string | null
  chosen_at: string | null
}

export type NegotiationStatus = 'PROPOSED' | 'ACCEPTED' | 'REJECTED'

/**
 * A relaxation proposal as seen by the participant it targets. RLS returns only that
 * participant's own rows, and the embedded constraint is their own constraint — nobody
 * else, organizer included, can read either side of this.
 */
export interface PendingNegotiation {
  id: string
  proposed_value: NormalizedValue
  unlocked_count: number
  participant_constraints: {
    normalized_type: NormalizedType
    normalized_value: NormalizedValue
    raw_text: string
  }
}

/** Payload of `fn_recompute_feasibility` and `fn_respond_negotiation`. */
export interface FeasibilityResult {
  run_id: string | null
  feasible_count: number
  /**
   * Candidates whose ONLY unmet MUSTs are accessibility ones (0022) — the venues a single
   * phone call away. Accessibility is deliberately never relaxable, so without this the
   * group would just see 「0件」 with no way to understand or act on it. Optional: a run
   * recorded before 0022 does not carry it.
   */
  accessibility_unverified_count?: number | null
  /**
   * The same idea for allergies (0026), and the case where it matters most: no provider
   * anywhere supplies restaurant allergen data — Hot Pepper returns 51 fields and none is
   * allergen-related, Google Places has none — so `allergy_safe_tags` is only ever filled in
   * by a human. An allergy MUST therefore excludes every live candidate, and it is never
   * relaxable, because nobody may be asked to consent to an unverified allergen claim the way
   * 0021 lets a group accept an unconfirmed smoking policy. This count is the whole escape
   * route: it turns a bare 「0件」 into a number and a phone call. Optional: a run recorded
   * before 0026 does not carry it.
   */
  allergy_unverified_count?: number | null
}

export type RecommendationLabel =
  | 'fairest'
  | 'best_access'
  | 'best_value'
  | 'best_experience'
  | 'crowd_pleaser'

export interface RecommendationRun {
  id: string
  event_id: string
  run_at: string
  feasible_count: number
}

/**
 * The dimensions the ordering score is built from (0016_scoring_and_objective.sql).
 * All six are normalized to 0..1 where **higher is better**, so the objective weights
 * can simply be a weighted sum. Burdens (the inverse) are stored separately.
 */
export type ScoreDimension =
  | 'travel_fairness'
  | 'travel_access'
  | 'satisfaction'
  | 'quality'
  | 'cost_fit'
  | 'accessibility_fit'

export const SCORE_DIMENSIONS: ScoreDimension[] = [
  'travel_fairness',
  'travel_access',
  'satisfaction',
  'quality',
  'cost_fit',
  'accessibility_fit',
]

/** Weight per dimension for one `events.objective`; the weights of an objective sum to 1. */
export type ObjectiveWeights = Record<ScoreDimension, number>

/**
 * Which quality signal was actually available for a venue. `rating_bayesian_shrunk` is
 * the real signal; `atmosphere_tag_proxy` is the legacy tag-richness stand-in used when
 * the provider gave us no rating, and it is deliberately capped below any real rating.
 */
export type QualityMethod = 'rating_bayesian_shrunk' | 'atmosphere_tag_proxy'

/**
 * `recommendation_scores.score_breakdown`. PRD §9: never present one opaque universal
 * score — every component, the weights that were applied to it, and the provenance of
 * the quality signal are stored so the UI can show the arithmetic. Keys are stable and
 * snake_case because both the SQL engine and this TS port write them.
 */
export interface ScoreBreakdown {
  version: number
  objective: EventObjective
  /** Reading instructions for the numbers below, so no caller has to guess a direction. */
  scale: { components: string; burdens: string }
  weights: ObjectiveWeights
  components: Record<ScoreDimension, number>
  /** `weights[dimension] * components[dimension]`, i.e. what each dimension contributed. */
  contributions: Record<ScoreDimension, number>
  objective_score: number
  travel: {
    participants: number
    known: number
    spread_minutes: number
    average_minutes: number | null
    complete: boolean
    fairness: number
    access: number
  }
  quality: {
    score: number
    method: QualityMethod
    rating: number | null
    user_rating_count: number | null
    prior_rating: number
    prior_reviews: number
    atmosphere_tags: number
  }
  cost: {
    burden: number
    price_yen: number | null
    tightest_budget_yen: number | null
    budget_musts: number
    reference_yen: number
  }
  accessibility: {
    burden: number
    needs: string[]
    unmet_needs: string[]
    venue_tags: string[]
    data_present: boolean
    requests: number
  }
}

export interface RecommendationScore {
  id: string
  run_id: string
  restaurant_place_id: string
  fairness_score: number | null
  satisfaction_score: number | null
  quality_score: number | null
  /** 0..1, higher = more disproportionate cost burden (the inverse of `cost_fit`). */
  cost_burden_score: number | null
  /** 0..1, higher = more unmet/unknown accessibility needs (inverse of `accessibility_fit`). */
  accessibility_burden_score: number | null
  /** The objective-weighted composite the cards are ordered by. */
  objective_score: number | null
  score_breakdown: ScoreBreakdown | null
  label: RecommendationLabel | null
  explanation: string | null
}

export interface RestaurantFeature {
  place_id: string
  name: string | null
  price_yen_estimate: number | null
  room_type: string | null
  cuisine_tags: string[]
  atmosphere_tags: string[]
  /**
   * The per-place third-party credits Places returned, exactly as the provider sent them
   * (migration 0023). Displaying them is a licence obligation, not decoration, which is why
   * they live on this client-readable table rather than in the service-role-only raw payload.
   *
   * `unknown[]` on purpose: an element is EITHER a string (the historical HTML-ish form) or an
   * object (Places (New) documents a provider name plus a provider URI), and flattening one
   * into the other in the type would licence code to rewrite a credit. Optional because the
   * mock backend does not model provider payloads.
   */
  provider_attributions?: unknown[] | null
}

/** `run_updated` broadcast payload from the `trg_broadcast_run` trigger. */
export interface RunUpdate {
  run_id: string
  feasible_count: number
  /**
   * The run's `run_at` (0025). Optional because Realtime replays whatever is already in the
   * topic, so a payload written before that migration can still arrive.
   *
   * It exists because the other two fields cannot be ordered: `run_id` is a random uuid and
   * `feasible_count` is not monotonic — accepting a relaxation raises it, a new MUST lowers it
   * — so a client handed an older run had no way to know. Observed for real: a dashboard
   * rendered a count from a broadcast written 21 seconds before the organizer even subscribed.
   */
  run_at?: string | null
}

export type HomeTab = 'requirements' | 'group' | 'organizer'
