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
    objective: EventObjective
  }): Promise<CreatedEvent>
  joinEvent(input: {
    inviteCode: string
    displayName: string
    travelReference: TravelReference
  }): Promise<string>
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
  }): Promise<void>
  ownConstraints(participantId: string): Promise<SavedConstraint[]>
  sanitizedFeed(eventId: string): Promise<FeedItem[]>
  subscribeConstraints(eventId: string, onItem: (item: FeedItem) => void): Promise<Unsubscribe>

  // MARK: - NegotiationService
  pendingNegotiation(participantId: string): Promise<PendingNegotiation | null>
  respondNegotiation(negotiationId: string, accept: boolean): Promise<FeasibilityResult | null>
  responseCount(eventId: string): Promise<number>
  pendingNegotiationCount(eventId: string): Promise<number>
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
