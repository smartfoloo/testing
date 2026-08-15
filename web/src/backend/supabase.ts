/**
 * Real backend. Every call here targets the same RPC / table / Edge Function / realtime
 * topic as the corresponding Swift service, so the web client sits behind the identical
 * security boundary:
 *  - only `participant_constraints` is written directly (RLS allows own rows only);
 *  - everything else goes through `security definer` RPCs or Edge Functions;
 *  - the group feed is a sanitized broadcast on the private `event-{event_id}` topic,
 *    never a table read, because RLS hides other participants' constraint rows.
 */

import { createClient, type RealtimeChannel, type SupabaseClient } from '@supabase/supabase-js'
import { NoTravelOriginError } from './types'
import type {
  Backend,
  RestaurantSearchResult,
  TravelOriginCoverage,
  Unsubscribe,
} from './types'
import type {
  CollectionReadiness,
  ConstraintKind,
  ConstraintVisibility,
  CreatedEvent,
  Event as EventModel,
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

function unwrap<T>({ data, error }: { data: T | null; error: { message: string } | null }): T {
  if (error) throw new Error(error.message)
  if (data === null) throw new Error('empty response')
  return data
}

/**
 * The parts of the `restaurant-search` answer this client reads. The function returns a
 * great deal more (meeting zones, cache provenance, unroutable place ids); those are
 * server-side diagnostics with no screen behind them.
 */
interface RestaurantSearchResponse {
  candidate_count?: number
  /** `[{participant_id, reason}]` — read for its LENGTH only, see travelCoverage. */
  unresolved_participants?: Array<{ participant_id?: string; reason?: string }>
  travel_unconstrained_participants?: string[]
  provider_incident_count?: number
}

/**
 * Collapses the per-participant lists into counts. Identities stop here, at the backend
 * boundary: the only consumer is the organizer dashboard, which shows aggregates only.
 */
function travelCoverage(body: RestaurantSearchResponse | null): TravelOriginCoverage {
  return {
    unresolvedCount: body?.unresolved_participants?.length ?? 0,
    // どこでも: a valid answer, deliberately excluded from the origins set. Counted so
    // the UI can say it is fine, never so it can be reported as a gap.
    unconstrainedCount: body?.travel_unconstrained_participants?.length ?? 0,
  }
}

/**
 * A non-2xx Edge Function answer arrives as a `FunctionsHttpError` whose `context` is the
 * raw `Response`, so the 422 body — the only place that says WHY the search could not run
 * — is reachable only by reading it. Duck-typed rather than `instanceof`-ed, so a relay or
 * fetch failure (no Response at all) simply yields null instead of throwing here.
 */
async function httpFailure(
  error: unknown,
): Promise<{ status: number; body: RestaurantSearchResponse | null } | null> {
  const context = (error as { context?: unknown } | null)?.context
  if (!(context instanceof Response)) return null
  try {
    return { status: context.status, body: (await context.json()) as RestaurantSearchResponse }
  } catch {
    // A non-JSON error body still tells us the status, which is what we branch on.
    return { status: context.status, body: null }
  }
}

export class SupabaseBackend implements Backend {
  readonly mode = 'supabase' as const
  private client: SupabaseClient

  constructor(url: string, anonKey: string) {
    this.client = createClient(url, anonKey)
  }

  /** Signs in anonymously when the SDK has no persisted session (Supa.ensureSession). */
  async ensureSession(): Promise<void> {
    const { data } = await this.client.auth.getSession()
    if (data.session) return
    const { error } = await this.client.auth.signInAnonymously()
    if (error) throw new Error(error.message)
  }

  /* --------------------------------------------------------- EventService */

  async createEvent(input: {
    name: string
    displayName: string
    travelReference: TravelReference
    travelReferencePlaceId?: string | null
    objective: EventObjective
  }): Promise<CreatedEvent> {
    return unwrap(
      await this.client.rpc('fn_create_event', {
        p_name: input.name,
        p_objective: input.objective,
        p_display_name: input.displayName,
        p_travel_reference: input.travelReference,
        p_travel_reference_place_id: input.travelReferencePlaceId ?? null,
      }),
    )
  }

  async joinEvent(input: {
    inviteCode: string
    displayName: string
    travelReference: TravelReference
    travelReferencePlaceId?: string | null
  }): Promise<string> {
    return unwrap(
      await this.client.rpc('fn_join_event', {
        p_invite_code: input.inviteCode,
        p_display_name: input.displayName,
        p_travel_reference: input.travelReference,
        p_travel_reference_place_id: input.travelReferencePlaceId ?? null,
      }),
    )
  }

  /**
   * Server-side place lookup, so the Places key stays in Edge Function secrets.
   */
  async searchPlaces(query: string): Promise<PlaceSuggestion[]> {
    const trimmed = query.trim()
    if (trimmed.length === 0) return []
    const { data, error } = await this.client.functions.invoke<{ places: PlaceSuggestion[] }>(
      'place-search',
      { body: { query: trimmed } },
    )
    if (error) throw new Error(error.message)
    return data?.places ?? []
  }

  /** Readable only once the caller is a participant of the event (RLS on `events`). */
  async event(inviteCode: string): Promise<EventModel> {
    return unwrap(
      await this.client.from('events').select().eq('invite_code', inviteCode).single(),
    )
  }

  async decision(eventId: string): Promise<EventDecision> {
    return unwrap(
      await this.client
        .from('events')
        .select('chosen_place_id, chosen_at')
        .eq('id', eventId)
        .single(),
    )
  }

  async chooseRestaurant(eventId: string, placeId: string): Promise<EventDecision> {
    const rows = unwrap<EventDecision[]>(
      await this.client.rpc('fn_choose_restaurant', {
        p_event_id: eventId,
        p_place_id: placeId,
      }),
    )
    const [decision] = rows
    if (!decision) throw new Error('empty restaurant decision response')
    return decision
  }

  async restaurantName(placeId: string): Promise<string | null> {
    const row = unwrap<{ name: string | null }>(
      await this.client.from('restaurant_features').select('name').eq('place_id', placeId).single(),
    )
    return row.name
  }

  async role(participantId: string): Promise<ParticipantRole> {
    const row = unwrap<{ role: ParticipantRole }>(
      await this.client.from('participants').select('role').eq('id', participantId).single(),
    )
    return row.role
  }

  /** Own row read: the 0007 membership policy already scopes `participants` selects. */
  async participantTravel(participantId: string): Promise<ParticipantTravel> {
    return unwrap<ParticipantTravel>(
      await this.client
        .from('participants')
        .select('travel_reference, travel_reference_place_id')
        .eq('id', participantId)
        .single(),
    )
  }

  /**
   * `participants` has no client write policy and (since 0020) no client write privilege
   * either, so this is an RPC rather than an update: a direct table write would silently
   * match zero rows. The definer function writes exactly these two columns for exactly
   * the caller's own row.
   */
  async updateTravelReference(input: {
    participantId: string
    travelReference: TravelReference
    travelReferencePlaceId?: string | null
  }): Promise<ParticipantTravel> {
    const rows = unwrap<ParticipantTravel[]>(
      await this.client.rpc('fn_set_travel_reference', {
        p_participant_id: input.participantId,
        p_travel_reference: input.travelReference,
        // どこでも carries no place. Sent as null as well as forced null server-side.
        p_travel_reference_place_id:
          input.travelReference === 'doesnt_matter'
            ? null
            : (input.travelReferencePlaceId ?? null),
      }),
    )
    const [travel] = rows
    if (!travel) throw new Error('empty travel reference response')
    return travel
  }

  /* ---------------------------------------------------- ConstraintService */

  /**
   * The Edge Function never fails on a bad model response — it answers with a
   * `needs_clarification` fallback instead.
   */
  async parse(input: {
    rawText: string
    kind: ConstraintKind
    language: 'ja' | 'en'
  }): Promise<ParseResult> {
    const { data, error } = await this.client.functions.invoke<ParseResult>('llm-assist', {
      body: { mode: 'parse', raw_text: input.rawText, kind: input.kind, language: input.language },
    })
    if (error) throw new Error(error.message)
    if (!data) throw new Error('empty parse response')
    return data
  }

  /** Direct table insert — RLS allows a participant to write only their own rows. */
  async insertConstraint(input: {
    eventId: string
    participantId: string
    kind: ConstraintKind
    rawText: string
    normalizedType: NormalizedType
    normalizedValue: NormalizedValue
    visibility: ConstraintVisibility
    semanticRemainder?: string | null
  }): Promise<void> {
    // sensitivity / verification_requirement are forced by 0018's BEFORE-INSERT trigger,
    // so the client deliberately does not send them.
    const { error } = await this.client.from('participant_constraints').insert({
      event_id: input.eventId,
      participant_id: input.participantId,
      kind: input.kind,
      raw_text: input.rawText,
      normalized_type: input.normalizedType,
      normalized_value: input.normalizedValue,
      visibility: input.visibility,
      semantic_remainder: input.semanticRemainder ?? null,
    })
    if (error) throw new Error(error.message)
  }

  async ownConstraints(participantId: string): Promise<SavedConstraint[]> {
    return unwrap(
      await this.client
        .from('participant_constraints')
        .select('id, kind, raw_text')
        .eq('participant_id', participantId)
        .order('created_at', { ascending: true }),
    )
  }

  async sanitizedFeed(eventId: string): Promise<FeedItem[]> {
    return unwrap(await this.client.rpc('fn_get_sanitized_feed', { p_event_id: eventId }))
  }

  async subscribeConstraints(
    eventId: string,
    onItem: (item: FeedItem) => void,
  ): Promise<Unsubscribe> {
    return this.subscribeBroadcast(eventId, 'constraint_added', (payload) =>
      onItem(payload as FeedItem),
    )
  }

  /* --------------------------------------------------- NegotiationService */

  /**
   * RLS restricts `negotiations` to rows targeting the caller, so no client-side
   * filtering by participant is needed for correctness — the id keeps the query narrow.
   */
  async pendingNegotiation(participantId: string): Promise<PendingNegotiation | null> {
    const { data, error } = await this.client
      .from('negotiations')
      .select(
        'id, proposed_value, unlocked_count, participant_constraints(normalized_type, normalized_value, raw_text)',
      )
      .eq('participant_id', participantId)
      .eq('status', 'PROPOSED')
      .order('created_at', { ascending: false })
      .limit(1)
    if (error) throw new Error(error.message)

    // `negotiations.constraint_id` is a to-one FK so PostgREST embeds an object, but
    // without generated database types supabase-js widens the embed to an array.
    type Embedded = PendingNegotiation['participant_constraints']
    const rows = (data ?? []) as unknown as Array<
      Omit<PendingNegotiation, 'participant_constraints'> & {
        participant_constraints: Embedded | Embedded[] | null
      }
    >

    const row = rows[0]
    if (!row) return null
    const embedded = row.participant_constraints
    const constraint = Array.isArray(embedded) ? embedded[0] : embedded
    if (!constraint) return null

    return {
      id: row.id,
      proposed_value: row.proposed_value,
      unlocked_count: row.unlocked_count,
      participant_constraints: constraint,
    }
  }

  /**
   * Accepting rewrites the participant's own constraint and recomputes feasibility
   * server-side; the RPC rejects any caller other than the targeted participant.
   */
  async respondNegotiation(
    negotiationId: string,
    accept: boolean,
  ): Promise<FeasibilityResult | null> {
    const { data, error } = await this.client.rpc('fn_respond_negotiation', {
      p_negotiation_id: negotiationId,
      p_accept: accept,
    })
    if (error) throw new Error(error.message)
    return (data as FeasibilityResult | null) ?? null
  }

  async responseCount(eventId: string): Promise<number> {
    return unwrap(await this.client.rpc('fn_get_response_count', { p_event_id: eventId }))
  }

  /** Bare count of open negotiations — deliberately no participant or constraint id. */
  async pendingNegotiationCount(eventId: string): Promise<number> {
    return unwrap(
      await this.client.rpc('fn_get_pending_negotiation_count', { p_event_id: eventId }),
    )
  }

  async collectionReadiness(eventId: string): Promise<CollectionReadiness> {
    return unwrap(await this.client.rpc('fn_get_collection_readiness', { p_event_id: eventId }))
  }

  /**
   * Organizer-only. Deliberately does not recompute — PRD §12 requires post-close
   * recalculation to be explicit.
   */
  async closePreferences(eventId: string): Promise<CollectionReadiness> {
    const rows = unwrap<Array<{ preferences_closed_at: string | null; status: string }>>(
      await this.client.rpc('fn_close_preferences', { p_event_id: eventId }),
    )
    if (rows.length === 0) throw new Error('empty close-preferences response')
    // The RPC returns only the lifecycle columns, so re-read the full readiness payload.
    return this.collectionReadiness(eventId)
  }

  async latestRun(eventId: string): Promise<RecommendationRun | null> {
    const rows = unwrap<RecommendationRun[]>(
      await this.client
        .from('recommendation_runs')
        .select('id, event_id, run_at, feasible_count')
        .eq('event_id', eventId)
        .order('run_at', { ascending: false })
        .limit(1),
    )
    return rows[0] ?? null
  }

  /**
   * A search can succeed while some participants have no resolvable origin, so the
   * travel coverage travels back with the candidate count instead of being discarded —
   * otherwise "travel fairness" is quietly computed over half the group.
   */
  async findRestaurants(eventId: string): Promise<RestaurantSearchResult> {
    const { data, error } = await this.client.functions.invoke<RestaurantSearchResponse>(
      'restaurant-search',
      { body: { event_id: eventId } },
    )
    if (error) {
      const failure = await httpFailure(error)
      // 422: not one participant has a usable origin, so there was nothing to search
      // around. That is a missing-location problem with an obvious remedy, and the
      // organizer has to be told which one it is.
      if (failure?.status === 422) throw new NoTravelOriginError(travelCoverage(failure.body))
      throw new Error(error.message)
    }
    return {
      candidateCount: data?.candidate_count ?? 0,
      travel: travelCoverage(data ?? null),
      providerIncidentCount: data?.provider_incident_count ?? 0,
    }
  }

  async recomputeFeasibility(eventId: string): Promise<FeasibilityResult> {
    return unwrap(await this.client.rpc('fn_recompute_feasibility', { p_event_id: eventId }))
  }

  /**
   * Returns null when nothing relaxable would unlock a candidate — the engine hands
   * off to the human organizer rather than forcing a proposal.
   */
  async proposeRelaxation(eventId: string): Promise<string | null> {
    const { data, error } = await this.client.rpc('fn_propose_relaxation', { p_event_id: eventId })
    if (error) throw new Error(error.message)
    return (data as string | null) ?? null
  }

  async subscribeRuns(
    eventId: string,
    onUpdate: (update: RunUpdate) => void,
  ): Promise<Unsubscribe> {
    return this.subscribeBroadcast(eventId, 'run_updated', (payload) =>
      onUpdate(payload as RunUpdate),
    )
  }

  /* ------------------------------------------------ RecommendationService */

  async scores(runId: string): Promise<RecommendationScore[]> {
    return unwrap(await this.client.from('recommendation_scores').select().eq('run_id', runId))
  }

  async features(placeIds: string[]): Promise<RestaurantFeature[]> {
    if (placeIds.length === 0) return []
    return unwrap(
      await this.client
        .from('restaurant_features')
        .select('place_id, name, price_yen_estimate, room_type, cuisine_tags, atmosphere_tags')
        .in('place_id', placeIds),
    )
  }

  /**
   * The Edge Function fetches its own grounding data server-side; only identifiers are
   * sent, never an evidence blob the model could be steered by.
   */
  async explanation(runId: string, restaurantPlaceId: string): Promise<string> {
    const { data, error } = await this.client.functions.invoke<{ explanation: string }>(
      'llm-assist',
      { body: { mode: 'explain', run_id: runId, restaurant_place_id: restaurantPlaceId } },
    )
    if (error) throw new Error(error.message)
    return data?.explanation ?? ''
  }

  /* --------------------------------------------------------------- shared */

  /**
   * `event-{event_id}` is a private topic: Realtime Authorization decides who may
   * subscribe (policy on realtime.messages in 0004), which requires the socket to carry
   * the caller's access token.
   */
  private async subscribeBroadcast(
    eventId: string,
    event: 'constraint_added' | 'run_updated' | 'event_decided',
    onPayload: (payload: unknown) => void,
  ): Promise<Unsubscribe> {
    await this.client.realtime.setAuth()
    const channel: RealtimeChannel = this.client
      .channel(`event-${eventId.toLowerCase()}`, { config: { private: true } })
      .on('broadcast', { event }, (message) => onPayload(message.payload))

    await new Promise<void>((resolve, reject) => {
      channel.subscribe((status) => {
        if (status === 'SUBSCRIBED') resolve()
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          reject(new Error(`realtime subscribe failed: ${status}`))
        }
      })
    })

    return () => {
      void this.client.removeChannel(channel)
    }
  }
}
