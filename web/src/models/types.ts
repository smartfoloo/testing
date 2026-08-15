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
/** CreateEventView/JoinEventView only offer these three; `doesnt_matter` is not selectable. */
export const SELECTABLE_TRAVEL_REFERENCES: TravelReference[] = ['office', 'home', 'station']

/** Response of the `llm-assist` Edge Function in `parse` mode. */
export interface ParseResult {
  normalized_type: NormalizedType
  normalized_value: NormalizedValue
  suggested_visibility: Exclude<ConstraintVisibility, 'PRIVATE'>
  confidence: number
  needs_clarification: boolean
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

export interface RecommendationScore {
  id: string
  run_id: string
  restaurant_place_id: string
  fairness_score: number | null
  satisfaction_score: number | null
  quality_score: number | null
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
}

/** `run_updated` broadcast payload from the `trg_broadcast_run` trigger. */
export interface RunUpdate {
  run_id: string
  feasible_count: number
}

export type HomeTab = 'requirements' | 'group' | 'organizer'
