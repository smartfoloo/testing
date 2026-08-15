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
  findRestaurants(eventId: string): Promise<number>
  recomputeFeasibility(eventId: string): Promise<FeasibilityResult>
  proposeRelaxation(eventId: string): Promise<string | null>
  subscribeRuns(eventId: string, onUpdate: (update: RunUpdate) => void): Promise<Unsubscribe>

  // MARK: - RecommendationService
  scores(runId: string): Promise<RecommendationScore[]>
  features(placeIds: string[]): Promise<RestaurantFeature[]>
  explanation(runId: string, restaurantPlaceId: string): Promise<string>
}
