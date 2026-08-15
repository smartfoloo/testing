/**
 * The surface the screens consume, mirroring the four Swift services
 * (EventService, ConstraintService, NegotiationService, RecommendationService).
 *
 * Two implementations exist:
 *  - `supabase.ts` — the real thing, calling the same RPCs / Edge Functions / realtime
 *    topics as the iOS app.
 *  - `mock.ts` — an in-browser stand-in seeded with supabase/seed.sql, used when no
 *    credentials are configured so the app is runnable and reviewable offline.
 */

import type {
  CollectionReadiness,
  ConstraintKind,
  ConstraintVisibility,
  CreatedEvent,
  Event,
  EventDecision,
  EventObjective,
  FeasibilityResult,
  FeedItem,
  NormalizedType,
  NormalizedValue,
  ParseResult,
  ParticipantRole,
  ParticipantTravel,
  PendingNegotiation,
  PlaceSuggestion,
  RecommendationRun,
  RecommendationScore,
  RestaurantFeature,
  RunUpdate,
  SavedConstraint,
  TravelReference,
} from '../models/types'

export type Unsubscribe = () => void

/* -------------------------------------------------------------------------- */
/* Travel-origin coverage of a search                                          */
/* -------------------------------------------------------------------------- */

/**
 * How much of the group a search could actually measure travel for.
 *
 * Deliberately **counts, not identities**. `restaurant-search` answers with
 * `unresolved_participants: [{participant_id, reason}]`, but the only screen that reads
 * this is the organizer dashboard, which shows aggregates only — so the participant ids
 * are collapsed here, in the backend layer, and never reach the UI. A privacy boundary
 * that lives in a type cannot be forgotten by a later caller.
 */
export interface TravelOriginCoverage {
  /**
   * Participants whose travel reference names a location (会社/自宅/駅) but who have no
   * place id, so the backend has no origin for them and travel fairness cannot include
   * them. This is the actionable number.
   */
  unresolvedCount: number
  /**
   * Participants who chose どこでも. They impose no travel constraint by design, are
   * excluded from the origins set on purpose, and must never be reported as a problem.
   */
  unconstrainedCount: number
}

/** What one press of 「条件に合うお店を探す」 achieved. */
export interface RestaurantSearchResult {
  /**
   * `candidate_count` from the Edge Function, with its meaning unchanged: how many
   * candidates THIS call obtained from the providers. Zero means the shortlist on
   * screen comes from previously fetched candidates (a cache hit), which is what the
   * organizer dashboard reports as 「以前に取得した候補を表示しています。」
   */
  candidateCount: number
  travel: TravelOriginCoverage
  /** Provider failures logged during the search: never fatal (A10), never invisible. */
  providerIncidentCount: number
}

/**
 * Thrown when `restaurant-search` answers 422: it had to call the providers, not one
 * participant has a usable travel origin to search around, and there is no cached
 * candidate to fall back on. This is a missing-location problem, not a network problem —
 * surfacing it as 「通信できませんでした」 told the organizer nothing they could act on.
 *
 * Carries the same counts-only coverage as the success path, so the message can say how
 * many people still need a location without naming any of them.
 */
export class NoTravelOriginError extends Error {
  readonly travel: TravelOriginCoverage

  constructor(travel: TravelOriginCoverage) {
    super('could not resolve any travel reference')
    this.name = 'NoTravelOriginError'
    this.travel = travel
  }
}

export interface Backend {
  readonly mode: 'supabase' | 'mock'

  /** Anonymous sign-in, matching Supa.ensureSession(). */
  ensureSession(): Promise<void>

  // MARK: - EventService
  createEvent(input: {
    name: string
    displayName: string
    travelReference: TravelReference
    /**
     * Places id for the participant's travel reference. Required for travel burden to
     * mean anything: without it the backend has no origin and reports the participant
     * as unresolved rather than geocoding the word "office".
     */
    travelReferencePlaceId?: string | null
    objective: EventObjective
  }): Promise<CreatedEvent>
  joinEvent(input: {
    inviteCode: string
    displayName: string
    travelReference: TravelReference
    travelReferencePlaceId?: string | null
  }): Promise<string>

  /**
   * Server-side place lookup for the travel-reference picker. The provider key stays in
   * Edge Function secrets, so the client never talks to Google directly.
   */
  searchPlaces(query: string): Promise<PlaceSuggestion[]>
  event(inviteCode: string): Promise<Event>
  decision(eventId: string): Promise<EventDecision>
  chooseRestaurant(eventId: string, placeId: string): Promise<EventDecision>
  restaurantName(placeId: string): Promise<string | null>
  role(participantId: string): Promise<ParticipantRole>

  /**
   * The caller's own travel reference, so the picker can open on what is actually
   * stored instead of defaulting to 会社 and overwriting a real answer.
   */
  participantTravel(participantId: string): Promise<ParticipantTravel>

  /**
   * PRD §4: the travel reference is context, "changeable later". Sets the caller's OWN
   * category and place at any point after joining — the escape hatch for anyone who
   * skipped the picker on the create/join screen and therefore contributes no origin.
   *
   * `fn_set_travel_reference` (0020) writes those two columns and nothing else, refuses
   * another participant's row (the organizer included), forces the place id to null for
   * どこでも, and drops that participant's cached travel legs when the origin moves.
   */
  updateTravelReference(input: {
    participantId: string
    travelReference: TravelReference
    /** Ignored for どこでも, which means "no travel constraint" and so carries no place. */
    travelReferencePlaceId?: string | null
  }): Promise<ParticipantTravel>

  // MARK: - ConstraintService
  parse(input: { rawText: string; kind: ConstraintKind; language: 'ja' | 'en' }): Promise<ParseResult>
  insertConstraint(input: {
    eventId: string
    participantId: string
    kind: ConstraintKind
    rawText: string
    normalizedType: NormalizedType
    normalizedValue: NormalizedValue
    visibility: ConstraintVisibility
    /** Preserved for P1 semantic matching; `sensitivity` / `verification_requirement`
     *  are derived server-side from the type and are deliberately not sent. */
    semanticRemainder?: string | null
  }): Promise<void>
  ownConstraints(participantId: string): Promise<SavedConstraint[]>
  sanitizedFeed(eventId: string): Promise<FeedItem[]>
  subscribeConstraints(eventId: string, onItem: (item: FeedItem) => void): Promise<Unsubscribe>

  // MARK: - NegotiationService
  pendingNegotiation(participantId: string): Promise<PendingNegotiation | null>
  respondNegotiation(negotiationId: string, accept: boolean): Promise<FeasibilityResult | null>
  responseCount(eventId: string): Promise<number>
  pendingNegotiationCount(eventId: string): Promise<number>

  /**
   * PRD §12 progressive search — how many participants have answered, whether the
   * threshold for provisional recommendations is met, and whether collection is closed.
   */
  collectionReadiness(eventId: string): Promise<CollectionReadiness>

  /**
   * PRD §12 — the organizer closes preference collection. Deliberately does NOT
   * recompute: post-close changes require explicit recalculation.
   */
  closePreferences(eventId: string): Promise<CollectionReadiness>
  latestRun(eventId: string): Promise<RecommendationRun | null>

  /**
   * Runs `restaurant-search`. Returns the candidate count it always returned, plus how
   * much of the group it could resolve a travel origin for, so a search that quietly
   * measured travel for only half the group can say so.
   *
   * Throws `NoTravelOriginError` when the function answers 422 (nobody has an origin).
   */
  findRestaurants(eventId: string): Promise<RestaurantSearchResult>
  recomputeFeasibility(eventId: string): Promise<FeasibilityResult>
  proposeRelaxation(eventId: string): Promise<string | null>
  subscribeRuns(eventId: string, onUpdate: (update: RunUpdate) => void): Promise<Unsubscribe>

  // MARK: - RecommendationService
  scores(runId: string): Promise<RecommendationScore[]>
  features(placeIds: string[]): Promise<RestaurantFeature[]>
  explanation(runId: string, restaurantPlaceId: string): Promise<string>
}
