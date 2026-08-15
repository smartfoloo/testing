/**
 * In-browser stand-in for the Supabase backend, used when no credentials are configured.
 *
 * It reproduces, in order of importance:
 *  - the deterministic engine (see engine.ts, ported from 0009_review_function_replacements.sql,
 *    0016_scoring_and_objective.sql and 0021_must_coverage_and_proposal_integrity.sql);
 *  - the authorization guards the security definer RPCs raise ('not a participant of this
 *    event', 'only the organizer can choose the restaurant', 'negotiation already resolved');
 *  - the sanitized broadcast contract from 0004 — PRIVATE rows are never emitted and
 *    ANONYMOUS rows are emitted with display_name: null;
 *  - the demo fixture from supabase/seed.sql.
 *
 * The `llm-assist` Edge Function is replaced by a deterministic keyword parser. It emits
 * exactly the normalized_value shapes the real SYSTEM_PROMPT specifies, because the
 * engine reads those keys: budget {max_yen}, cuisine {include,exclude}, dietary {tags},
 * allergy {allergens}, smoking {preference}, room {room}, travel_time {max_minutes},
 * accessibility {needs}, atmosphere {tags}, other {}.
 */

import {
  candidateIsFeasible,
  countUnlockedIfRelaxed,
  proposeRelaxation as engineProposeRelaxation,
  recomputeFeasibility as engineRecompute,
  type ConstraintRow,
  type Db,
  type FeatureRow,
} from './engine'
import { NoTravelOriginError } from './types'
import type {
  Backend,
  RestaurantSearchResult,
  TravelOriginCoverage,
  Unsubscribe,
} from './types'
import { roomDescription } from '../models/format'
import type {
  CollectionReadiness,
  ConstraintKind,
  ConstraintSensitivity,
  Event as EventModel,
  EventDecision,
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
  VerificationRequirement,
} from '../models/types'

/**
 * Bump the db version whenever the fixture shape changes, so a browser holding an older
 * snapshot re-seeds instead of running with columns the engine now expects. v2 added
 * travel_matrix_cache legs, events.preferences_closed_at and the derived constraint
 * metadata. The user key is separate so the current identity survives a re-seed.
 *
 * 0021's `smoking_policy` deliberately does NOT need a bump: it is optional and an absent
 * value means "unconfirmed", which is exactly what a v2 snapshot (and seed.sql) implies, so
 * an existing snapshot keeps evaluating identically instead of throwing the user's event away.
 */
const STORAGE_KEY = 'matomeshi.mock.db.v2'
const USER_KEY = 'matomeshi.mock.user.v1'

/** Invite-code alphabet from fn_generate_invite_code (0007): 31 unambiguous chars. */
const INVITE_ALPHABET = '23456789abcdefghjkmnpqrstuvwxyz'

const DEMO_EVENT_ID = '00000000-0000-0000-0000-000000000001'
const P = {
  alice: '00000000-0000-0000-0000-0000000000a1',
  bob: '00000000-0000-0000-0000-0000000000b1',
  charlie: '00000000-0000-0000-0000-0000000000c1',
  david: '00000000-0000-0000-0000-0000000000d1',
  emma: '00000000-0000-0000-0000-0000000000e1',
}

function newId(): string {
  return crypto.randomUUID()
}

/* -------------------------------------------------------------------------- */
/* Seed — supabase/seed.sql                                                    */
/* -------------------------------------------------------------------------- */

/** Exported so `npm run verify:engine` can assert against the fixture. */
export function createSeedDb(): Db {
  const at = (seconds: number) => new Date(Date.UTC(2026, 0, 1, 9, 0, seconds)).toISOString()
  let order = 0
  const constraint = (
    participantId: string,
    kind: ConstraintKind,
    rawText: string,
    normalizedType: NormalizedType,
    normalizedValue: NormalizedValue,
    visibility: 'PUBLIC' | 'ANONYMOUS',
  ): ConstraintRow => ({
    id: newId(),
    event_id: DEMO_EVENT_ID,
    participant_id: participantId,
    kind,
    raw_text: rawText,
    normalized_type: normalizedType,
    normalized_value: normalizedValue,
    visibility,
    // Derived server-side by 0018's trigger; mirrored here so the mock matches.
    sensitivity: sensitivityFor(normalizedType),
    verification_requirement: verificationFor(kind, normalizedType),
    semantic_remainder: null,
    created_at: at(order++),
    updated_at: at(order),
  })

  const feature = (
    placeId: string,
    name: string,
    price: number,
    room: string,
    dietary: string[],
    allergySafe: string[],
    atmosphere: string[],
    travel: Record<string, number>,
  ): FeatureRow => ({
    place_id: placeId,
    name,
    price_yen_estimate: price,
    room_type: room,
    cuisine_tags: [],
    dietary_tags: dietary,
    allergy_safe_tags: allergySafe,
    atmosphere_tags: atmosphere,
    travel_minutes_by_participant: travel,
    fetched_at: at(0),
    // Exactly as seed.sql leaves them: no accessibility tags and no smoking policy. Both
    // MUST types are fail-closed since 0021, so claiming either here would be inventing
    // venue facts — and the five personas state neither requirement, so the 0-then-3
    // invariant is untouched.
    accessibility_tags: [],
    smoking_policy: null,
  })

  return {
    events: [
      {
        id: DEMO_EVENT_ID,
        name: 'Team 飲み会',
        // Identical to seed.sql, which used to seed 'DEMO01' — unreachable, because
        // fn_generate_invite_code only ever emits lowercase characters from INVITE_ALPHABET
        // and both join screens lowercase and clamp what you type. The seed now matches this.
        invite_code: 'demo01',
        organizer_participant_id: P.alice,
        objective: 'balanced',
        status: 'collecting',
        created_at: at(0),
        chosen_place_id: null,
        chosen_at: null,
        preferences_closed_at: null,
      },
    ],
    participants: [
      ['alice', P.alice, 'Alice', 'organizer', 'office'],
      ['bob', P.bob, 'Bob', 'participant', 'office'],
      ['charlie', P.charlie, 'Charlie', 'participant', 'station'],
      ['david', P.david, 'David', 'participant', 'home'],
      ['emma', P.emma, 'Emma', 'participant', 'office'],
    ].map(([slug, id, displayName, role, travel]) => ({
      id: id as string,
      event_id: DEMO_EVENT_ID,
      // Stable stand-ins for seed.sql's gen_random_uuid(); no visitor ever matches these,
      // so the demo event stays invisible until you join it with its invite code.
      auth_user_id: `demo-user-${slug}`,
      display_name: displayName as string,
      role: role as ParticipantRole,
      travel_reference: travel as 'office' | 'home' | 'station',
      travel_reference_place_id: null,
      joined_at: at(0),
    })),
    constraints: [
      constraint(P.alice, 'MUST', 'budget under 4000 yen', 'budget', { max_yen: 4000 }, 'PUBLIC'),
      constraint(P.alice, 'WANT', 'yakitori', 'cuisine', { include: ['yakitori'], exclude: [] }, 'PUBLIC'),
      constraint(P.bob, 'MUST', 'private room', 'room', { room: 'private' }, 'PUBLIC'),
      constraint(P.bob, 'WANT', 'good sake selection', 'other', { note: 'good sake' }, 'PUBLIC'),
      constraint(P.charlie, 'MUST', 'vegetarian options', 'dietary', { tags: ['vegetarian'] }, 'ANONYMOUS'),
      constraint(P.charlie, 'WANT', 'quiet atmosphere', 'atmosphere', { tags: ['quiet'] }, 'PUBLIC'),
      constraint(P.david, 'MUST', 'within 35 min travel', 'travel_time', { max_minutes: 35 }, 'PUBLIC'),
      constraint(P.david, 'WANT', 'casual', 'atmosphere', { tags: ['casual'] }, 'PUBLIC'),
      constraint(P.emma, 'MUST', 'shellfish allergy', 'allergy', { allergens: ['shellfish'] }, 'ANONYMOUS'),
      constraint(P.emma, 'WANT', 'traditional japanese atmosphere', 'atmosphere', { tags: ['traditional_japanese'] }, 'PUBLIC'),
    ],
    negotiations: [],
    restaurants: ['demo_place_001', 'demo_place_002', 'demo_place_003', 'demo_place_004'].map(
      (placeId) => ({ place_id: placeId, hotpepper_id: null, last_fetched_at: at(0) }),
    ),
    features: [
      // Names are a mock addition: seed.sql leaves restaurant_features.name null because
      // the real pipeline fills it from the Places displayName in restaurant-search.
      feature('demo_place_001', '炭火焼鳥 とり源', 3800, 'semi_private', ['vegetarian'], ['shellfish_free'], ['quiet', 'traditional_japanese'], { [P.david]: 20 }),
      feature('demo_place_002', '居酒屋 まる真', 3500, 'semi_private', ['vegetarian'], ['shellfish_free'], ['casual'], { [P.david]: 30 }),
      feature('demo_place_003', '大衆酒場 のぼる', 4200, 'open', [], ['shellfish_free'], ['quiet'], { [P.david]: 15 }),
      feature('demo_place_004', '和食堂 むすび', 3900, 'semi_private', ['vegetarian'], ['shellfish_free'], ['quiet'], { [P.david]: 25 }),
    ],
    runs: [],
    scores: [],
    travelMatrix: [],
  }
}

/**
 * Mirrors fn_constraint_sensitivity / fn_constraint_verification_requirement in
 * 0018_constraint_model_and_lifecycle.sql. The set that is `highly_sensitive` is exactly
 * the set that defaults to ANONYMOUS and is never eligible for relaxation — one notion of
 * health/religion/disability data across all three subsystems.
 */
function sensitivityFor(type: NormalizedType): ConstraintSensitivity {
  if (type === 'allergy' || type === 'dietary' || type === 'accessibility') {
    return 'highly_sensitive'
  }
  return type === 'budget' ? 'sensitive' : 'normal'
}

function verificationFor(kind: ConstraintKind, type: NormalizedType): VerificationRequirement {
  // Only a MUST can gate a venue, so WANTs never require confirmation.
  if (kind !== 'MUST') return 'none'
  if (type === 'allergy' || type === 'dietary' || type === 'accessibility') return 'required'
  if (type === 'room' || type === 'smoking') return 'recommended'
  return 'none'
}

/* -------------------------------------------------------------------------- */
/* Deterministic parser (replaces the llm-assist Edge Function)                */
/* -------------------------------------------------------------------------- */

interface Rule {
  type: NormalizedType
  match: RegExp
  build: (text: string, matched: RegExpMatchArray) => NormalizedValue | null
}

const CUISINE_WORDS: Array<[RegExp, string]> = [
  [/焼き?鳥|やきとり|yakitori/i, 'yakitori'],
  [/居酒屋|izakaya/i, 'izakaya'],
  [/和食|日本料理|japanese/i, 'japanese'],
  [/寿司|すし|sushi/i, 'sushi'],
  [/焼肉|yakiniku/i, 'yakiniku'],
  [/ラーメン|ramen/i, 'ramen'],
  [/イタリアン|italian|パスタ/i, 'italian'],
  [/中華|chinese/i, 'chinese'],
  [/韓国|korean/i, 'korean'],
  [/カレー|curry/i, 'curry'],
  [/そば|蕎麦|soba/i, 'soba'],
]

const ATMOSPHERE_WORDS: Array<[RegExp, string]> = [
  [/静か|しずか|落ち着|quiet|calm/i, 'quiet'],
  [/賑やか|にぎやか|盛り上が|lively/i, 'lively'],
  [/カジュアル|気軽|casual/i, 'casual'],
  [/和風|伝統|traditional/i, 'traditional_japanese'],
  [/おしゃれ|オシャレ|stylish|モダン/i, 'stylish'],
]

const DIETARY_WORDS: Array<[RegExp, string]> = [
  [/ヴィーガン|ビーガン|vegan/i, 'vegan'],
  [/ベジタリアン|菜食|vegetarian/i, 'vegetarian'],
  [/ハラル|ハラール|halal/i, 'halal'],
  [/グルテン|gluten/i, 'gluten_free'],
]

const ALLERGEN_WORDS: Array<[RegExp, string]> = [
  // えび/かに are crustaceans, mapped onto the fixture's `shellfish_free` tag.
  [/えび|海老|エビ|かに|蟹|カニ|甲殻|貝|shellfish|shrimp|crab/i, 'shellfish'],
  [/卵|たまご|タマゴ|egg/i, 'egg'],
  [/乳|牛乳|チーズ|milk|dairy/i, 'milk'],
  [/落花生|ピーナッツ|peanut/i, 'peanut'],
  [/小麦|wheat/i, 'wheat'],
  [/そば|蕎麦|buckwheat/i, 'buckwheat'],
]

const ACCESSIBILITY_WORDS: Array<[RegExp, string]> = [
  [/車椅子|車いす|wheelchair/i, 'wheelchair'],
  [/段差|バリアフリー|step.?free|スロープ/i, 'step_free'],
  [/エレベータ|elevator/i, 'elevator'],
]

function collect(text: string, words: Array<[RegExp, string]>): string[] {
  const found = words.filter(([pattern]) => pattern.test(text)).map(([, tag]) => tag)
  return [...new Set(found)]
}

const RULES: Rule[] = [
  {
    // Allergy before dietary: 「えびアレルギー」 must not be read as a dietary tag.
    type: 'allergy',
    match: /アレルギ|allerg|食べられない|だめ|ダメ|苦手/i,
    build: (text) => {
      const allergens = collect(text, ALLERGEN_WORDS)
      return allergens.length > 0 ? { allergens } : null
    },
  },
  {
    type: 'allergy',
    match: /えび|海老|エビ|かに|蟹|甲殻|落花生|ピーナッツ/i,
    build: (text) => {
      if (!/アレルギ|allerg|食べられない|抜き|除いて|なし/i.test(text)) return null
      const allergens = collect(text, ALLERGEN_WORDS)
      return allergens.length > 0 ? { allergens } : null
    },
  },
  {
    type: 'dietary',
    match: /ベジタリアン|ヴィーガン|ビーガン|菜食|ハラル|ハラール|グルテン|vegan|vegetarian|halal|gluten/i,
    build: (text) => {
      const tags = collect(text, DIETARY_WORDS)
      return tags.length > 0 ? { tags } : null
    },
  },
  {
    type: 'budget',
    match: /([0-9０-９][0-9０-９,，]*)\s*(?:円|yen)|予算|budget/i,
    build: (text) => {
      const amount = text.match(/([0-9０-９][0-9０-９,，]*)\s*(?:円|yen)/i)
      if (!amount) return null
      const digits = amount[1]
        .replace(/[０-９]/g, (char) => String.fromCharCode(char.charCodeAt(0) - 0xfee0))
        .replace(/[,，]/g, '')
      const value = Number.parseInt(digits, 10)
      return Number.isFinite(value) ? { max_yen: value } : null
    },
  },
  {
    type: 'travel_time',
    match: /([0-9０-９]+)\s*(?:分|min)/i,
    build: (text) => {
      const found = text.match(/([0-9０-９]+)\s*(?:分|min)/i)
      if (!found) return null
      const digits = found[1].replace(/[０-９]/g, (char) =>
        String.fromCharCode(char.charCodeAt(0) - 0xfee0),
      )
      const value = Number.parseInt(digits, 10)
      return Number.isFinite(value) ? { max_minutes: value } : null
    },
  },
  {
    type: 'room',
    match: /個室|半個室|座敷|カウンター|オープン|private room|semi.?private/i,
    build: (text) => {
      if (/半個室|semi.?private/i.test(text)) return { room: 'semi_private' }
      if (/カウンター|オープン|open/i.test(text)) return { room: 'open' }
      if (/個室|private/i.test(text)) return { room: 'private' }
      return null
    },
  },
  {
    type: 'accessibility',
    match: /車椅子|車いす|段差|バリアフリー|スロープ|エレベータ|wheelchair|step.?free|accessib/i,
    build: (text) => {
      const needs = collect(text, ACCESSIBILITY_WORDS)
      return needs.length > 0 ? { needs } : { needs: ['step_free'] }
    },
  },
  {
    type: 'smoking',
    match: /禁煙|喫煙|タバコ|たばこ|smoking/i,
    build: (text) =>
      /喫煙可|吸える|smoking_ok/i.test(text)
        ? { preference: 'smoking_ok' }
        : { preference: 'non_smoking' },
  },
  {
    type: 'atmosphere',
    match: /静か|しずか|落ち着|賑やか|にぎやか|カジュアル|気軽|和風|伝統|おしゃれ|モダン|quiet|lively|casual|traditional|stylish/i,
    build: (text) => {
      const tags = collect(text, ATMOSPHERE_WORDS)
      return tags.length > 0 ? { tags } : null
    },
  },
  {
    type: 'cuisine',
    match: /焼き?鳥|やきとり|居酒屋|和食|日本料理|寿司|すし|焼肉|ラーメン|イタリアン|パスタ|中華|韓国|カレー|yakitori|izakaya|japanese|sushi|ramen|italian|chinese|korean|curry/i,
    build: (text) => {
      const include = collect(text, CUISINE_WORDS)
      return include.length > 0 ? { include, exclude: [] } : null
    },
  },
]

/** Mirrors applyDefaultVisibility() — sensitive categories default to ANONYMOUS. */
const SENSITIVE_TYPES: NormalizedType[] = ['allergy', 'dietary', 'accessibility']

export function parseConstraintText(rawText: string, kind: ConstraintKind = 'WANT'): ParseResult {
  const text = rawText.trim()
  const fallback: ParseResult = {
    normalized_type: 'other',
    normalized_value: {},
    suggested_visibility: 'PUBLIC',
    confidence: 0,
    needs_clarification: true,
    semantic_remainder: null,
    sensitivity: 'normal',
    verification_requirement: 'none',
  }
  if (text.length === 0) return fallback

  for (const rule of RULES) {
    const matched = text.match(rule.match)
    if (!matched) continue
    const value = rule.build(text, matched)
    if (!value) continue
    return {
      normalized_type: rule.type,
      normalized_value: value,
      suggested_visibility: SENSITIVE_TYPES.includes(rule.type) ? 'ANONYMOUS' : 'PUBLIC',
      confidence: 0.9,
      needs_clarification: false,
      // The taxonomy captured this one, so there is no leftover meaning to preserve.
      semantic_remainder: null,
      sensitivity: sensitivityFor(rule.type),
      verification_requirement: verificationFor(kind, rule.type),
    }
  }

  // Nothing matched: keep the wording so P1 semantic matching has something to embed.
  return { ...fallback, normalized_value: { note: text }, semantic_remainder: text }
}

/* -------------------------------------------------------------------------- */
/* Mock backend                                                                */
/* -------------------------------------------------------------------------- */

type Topic = `event-${string}`
type BroadcastEvent = 'constraint_added' | 'run_updated' | 'event_decided' | 'preferences_closed'

export class MockBackend implements Backend {
  readonly mode = 'mock' as const
  private db: Db
  private authUserId: string
  private listeners = new Map<string, Set<(payload: unknown) => void>>()

  constructor() {
    this.db = this.load()
    this.authUserId = this.loadUser()
  }

  /* ---------------------------------------------------------------- storage */

  private load(): Db {
    try {
      // Drop snapshots from superseded schema versions rather than leaving them orphaned.
      localStorage.removeItem('matomeshi.mock.db.v1')
      const raw = localStorage.getItem(STORAGE_KEY)
      if (raw) return JSON.parse(raw) as Db
    } catch {
      // Corrupt or unavailable storage falls back to a fresh fixture.
    }
    const fresh = createSeedDb()
    this.persist(fresh)
    return fresh
  }

  private persist(db: Db = this.db): void {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(db))
    } catch {
      // Private-mode Safari and quota errors are non-fatal; state stays in memory.
    }
  }

  private loadUser(): string {
    try {
      const existing = localStorage.getItem(USER_KEY)
      if (existing) return existing
      const created = newId()
      localStorage.setItem(USER_KEY, created)
      return created
    } catch {
      return newId()
    }
  }

  /** Wipes the fixture, used by the "reset" affordance in mock mode. */
  static reset(): void {
    localStorage.removeItem(STORAGE_KEY)
    localStorage.removeItem(USER_KEY)
  }

  /* -------------------------------------------------------------- internals */

  private now(): string {
    return new Date().toISOString()
  }

  private emit(topic: Topic, event: BroadcastEvent, payload: unknown): void {
    this.listeners.get(`${topic}:${event}`)?.forEach((handler) => handler(payload))
  }

  private subscribe(
    topic: Topic,
    event: BroadcastEvent,
    handler: (payload: unknown) => void,
  ): Unsubscribe {
    const key = `${topic}:${event}`
    const set = this.listeners.get(key) ?? new Set()
    set.add(handler)
    this.listeners.set(key, set)
    return () => set.delete(handler)
  }

  /** The caller's participant row for an event, or undefined when not a member. */
  private me(eventId: string) {
    return this.db.participants.find(
      (participant) =>
        participant.event_id === eventId && participant.auth_user_id === this.authUserId,
    )
  }

  private requireParticipant(eventId: string): void {
    if (!this.me(eventId)) throw new Error('not a participant of this event')
  }

  private generateInviteCode(): string {
    for (let attempt = 0; attempt < 10; attempt += 1) {
      const bytes = crypto.getRandomValues(new Uint8Array(6))
      const code = Array.from(bytes, (byte) => INVITE_ALPHABET[byte % 31]).join('')
      if (!this.db.events.some((event) => event.invite_code === code)) return code
    }
    throw new Error('could not allocate invite code')
  }

  /** Simulates the small network delay the real client has, so loading states are visible. */
  private async latency(ms = 180): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, ms))
  }

  /* ------------------------------------------------------------- session */

  async ensureSession(): Promise<void> {
    await this.latency(40)
  }

  /* --------------------------------------------------------- EventService */

  async createEvent(input: {
    name: string
    displayName: string
    travelReference: 'office' | 'home' | 'station' | 'doesnt_matter'
    travelReferencePlaceId?: string | null
    objective: EventModel['objective']
  }) {
    await this.latency()
    const eventId = newId()
    const participantId = newId()
    const inviteCode = this.generateInviteCode()

    this.db.events.push({
      id: eventId,
      name: input.name,
      invite_code: inviteCode,
      organizer_participant_id: participantId,
      objective: input.objective,
      status: 'collecting',
      created_at: this.now(),
      chosen_place_id: null,
      chosen_at: null,
      preferences_closed_at: null,
    })
    this.db.participants.push({
      id: participantId,
      event_id: eventId,
      auth_user_id: this.authUserId,
      display_name: input.displayName,
      role: 'organizer',
      travel_reference: input.travelReference,
      travel_reference_place_id: input.travelReferencePlaceId ?? null,
      joined_at: this.now(),
    })
    this.persist()
    return { event_id: eventId, invite_code: inviteCode, participant_id: participantId }
  }

  async joinEvent(input: {
    inviteCode: string
    displayName: string
    travelReference: 'office' | 'home' | 'station' | 'doesnt_matter'
    travelReferencePlaceId?: string | null
  }) {
    await this.latency()
    const event = this.db.events.find((row) => row.invite_code === input.inviteCode)
    if (!event) throw new Error('invalid invite code')
    if (event.status === 'closed') throw new Error('event is closed')

    // fn_join_event is idempotent.
    const existing = this.me(event.id)
    if (existing) return existing.id

    const participantId = newId()
    this.db.participants.push({
      id: participantId,
      event_id: event.id,
      auth_user_id: this.authUserId,
      display_name: input.displayName,
      role: 'participant',
      travel_reference: input.travelReference,
      travel_reference_place_id: input.travelReferencePlaceId ?? null,
      joined_at: this.now(),
    })
    this.persist()
    return participantId
  }

  async event(inviteCode: string): Promise<EventModel> {
    await this.latency(60)
    const row = this.db.events.find((event) => event.invite_code === inviteCode)
    if (!row) throw new Error('event not found')
    this.requireParticipant(row.id)
    const { chosen_place_id: _place, chosen_at: _at, ...event } = row
    return event
  }

  async decision(eventId: string): Promise<EventDecision> {
    await this.latency(60)
    this.requireParticipant(eventId)
    const event = this.db.events.find((row) => row.id === eventId)
    if (!event) throw new Error('event not found')
    return { chosen_place_id: event.chosen_place_id, chosen_at: event.chosen_at }
  }

  async chooseRestaurant(eventId: string, placeId: string): Promise<EventDecision> {
    await this.latency()
    const event = this.db.events.find((row) => row.id === eventId)
    if (!event) throw new Error('event not found')
    const me = this.me(eventId)
    if (!me || event.organizer_participant_id !== me.id) {
      throw new Error('only the organizer can choose the restaurant')
    }
    if (!this.db.features.some((feature) => feature.place_id === placeId)) {
      throw new Error('unknown restaurant')
    }

    event.chosen_place_id = placeId
    event.chosen_at = this.now()
    event.status = 'closed'
    this.persist()
    this.emit(`event-${eventId}`, 'event_decided', { chosen_place_id: placeId })
    return { chosen_place_id: event.chosen_place_id, chosen_at: event.chosen_at }
  }

  async restaurantName(placeId: string): Promise<string | null> {
    await this.latency(40)
    return this.db.features.find((feature) => feature.place_id === placeId)?.name ?? null
  }

  async role(participantId: string): Promise<ParticipantRole> {
    await this.latency(40)
    const participant = this.db.participants.find((row) => row.id === participantId)
    if (!participant) throw new Error('participant not found')
    return participant.role
  }

  async participantTravel(participantId: string): Promise<ParticipantTravel> {
    await this.latency(60)
    const participant = this.db.participants.find((row) => row.id === participantId)
    if (!participant) throw new Error('participant not found')
    return {
      travel_reference: participant.travel_reference,
      travel_reference_place_id: participant.travel_reference_place_id,
    }
  }

  /**
   * Mirrors fn_set_travel_reference (0020) exactly, including the refusal: only the
   * caller's own row, only these two columns, どこでも clears the place, and the cached
   * travel legs measured from the old origin are dropped so a stale leg cannot keep
   * scoring the participant from a place they no longer start at.
   */
  async updateTravelReference(input: {
    participantId: string
    travelReference: TravelReference
    travelReferencePlaceId?: string | null
  }): Promise<ParticipantTravel> {
    await this.latency()
    const participant = this.db.participants.find((row) => row.id === input.participantId)
    if (!participant) throw new Error('participant not found')
    if (participant.auth_user_id !== this.authUserId) {
      // Same wording as the RPC, so AppCopy.errorMessage maps it to 権限がありません.
      throw new Error("not permitted to change another participant's travel reference")
    }

    const previousPlaceId = participant.travel_reference_place_id
    const nextPlaceId =
      input.travelReference === 'doesnt_matter'
        ? null
        : (input.travelReferencePlaceId?.trim() ?? null) || null

    participant.travel_reference = input.travelReference
    participant.travel_reference_place_id = nextPlaceId

    if (nextPlaceId !== previousPlaceId) {
      const travelMatrix = (this.db.travelMatrix ??= [])
      this.db.travelMatrix = travelMatrix.filter(
        (leg) =>
          !(leg.event_id === participant.event_id && leg.participant_id === input.participantId),
      )
      // fn_travel_minutes falls back to the legacy per-place JSONB, so the key has to go
      // there too — it is keyed by participant id, so no other participant is affected.
      for (const feature of this.db.features) {
        delete feature.travel_minutes_by_participant[input.participantId]
      }
    }

    this.persist()
    return {
      travel_reference: participant.travel_reference,
      travel_reference_place_id: participant.travel_reference_place_id,
    }
  }

  /* ---------------------------------------------------- ConstraintService */

  async parse(input: { rawText: string; kind: ConstraintKind; language: 'ja' | 'en' }) {
    await this.latency(320)
    return parseConstraintText(input.rawText, input.kind)
  }

  async insertConstraint(input: {
    eventId: string
    participantId: string
    kind: ConstraintKind
    rawText: string
    normalizedType: NormalizedType
    normalizedValue: NormalizedValue
    visibility: 'PUBLIC' | 'ANONYMOUS' | 'PRIVATE'
    semanticRemainder?: string | null
  }): Promise<void> {
    await this.latency()
    const me = this.me(input.eventId)
    if (!me || me.id !== input.participantId) {
      throw new Error('new row violates row-level security policy')
    }
    // 0018 puts this in the RLS `with check`, so the write fails loudly rather than
    // silently updating zero rows. Mirror that: closing collection must be enforced,
    // not merely hidden in the UI.
    const event = this.db.events.find((row) => row.id === input.eventId)
    if (event?.preferences_closed_at) {
      throw new Error('new row violates row-level security policy for table "participant_constraints"')
    }

    const row: ConstraintRow = {
      id: newId(),
      event_id: input.eventId,
      participant_id: input.participantId,
      kind: input.kind,
      raw_text: input.rawText,
      normalized_type: input.normalizedType,
      normalized_value: input.normalizedValue,
      visibility: input.visibility,
      sensitivity: sensitivityFor(input.normalizedType),
      verification_requirement: verificationFor(input.kind, input.normalizedType),
      semantic_remainder: input.semanticRemainder ?? null,
      created_at: this.now(),
      updated_at: this.now(),
    }
    this.db.constraints.push(row)
    this.persist()

    // fn_broadcast_constraint_change: PRIVATE rows are never broadcast, full stop.
    if (row.visibility === 'PRIVATE') return
    const payload: FeedItem = {
      id: row.id,
      kind: row.kind,
      normalized_type: row.normalized_type,
      normalized_value: row.normalized_value,
      visibility: row.visibility,
      display_name: row.visibility === 'PUBLIC' ? me.display_name : null,
      created_at: row.created_at,
    }
    this.emit(`event-${input.eventId}`, 'constraint_added', payload)
  }

  async ownConstraints(participantId: string): Promise<SavedConstraint[]> {
    await this.latency(80)
    return this.db.constraints
      .filter((row) => row.participant_id === participantId)
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
      .map((row) => ({ id: row.id, kind: row.kind, raw_text: row.raw_text }))
  }

  async sanitizedFeed(eventId: string): Promise<FeedItem[]> {
    await this.latency(150)
    this.requireParticipant(eventId)
    return this.db.constraints
      .filter((row) => row.event_id === eventId && row.visibility !== 'PRIVATE')
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
      .map((row) => ({
        id: row.id,
        kind: row.kind,
        normalized_type: row.normalized_type,
        normalized_value: row.normalized_value,
        visibility: row.visibility,
        display_name:
          row.visibility === 'PUBLIC'
            ? (this.db.participants.find((p) => p.id === row.participant_id)?.display_name ?? null)
            : null,
        created_at: row.created_at,
      }))
  }

  async subscribeConstraints(eventId: string, onItem: (item: FeedItem) => void) {
    return this.subscribe(`event-${eventId}`, 'constraint_added', (payload) =>
      onItem(payload as FeedItem),
    )
  }

  /* --------------------------------------------------- NegotiationService */

  async pendingNegotiation(participantId: string): Promise<PendingNegotiation | null> {
    await this.latency(60)
    const row = this.db.negotiations
      .filter((n) => n.participant_id === participantId && n.status === 'PROPOSED')
      .sort((a, b) => b.created_at.localeCompare(a.created_at))[0]
    if (!row) return null
    const constraint = this.db.constraints.find((c) => c.id === row.constraint_id)
    if (!constraint) return null
    return {
      id: row.id,
      proposed_value: row.proposed_value,
      unlocked_count: row.unlocked_count,
      participant_constraints: {
        normalized_type: constraint.normalized_type,
        normalized_value: constraint.normalized_value,
        raw_text: constraint.raw_text,
      },
    }
  }

  async respondNegotiation(negotiationId: string, accept: boolean): Promise<FeasibilityResult | null> {
    await this.latency()
    const negotiation = this.db.negotiations.find((row) => row.id === negotiationId)
    if (!negotiation) throw new Error('negotiation not found')
    const me = this.me(negotiation.event_id)
    if (!me || me.id !== negotiation.participant_id) {
      throw new Error('not authorized to respond to this negotiation')
    }
    if (negotiation.status !== 'PROPOSED') throw new Error('negotiation already resolved')

    if (accept) {
      const constraint = this.db.constraints.find((row) => row.id === negotiation.constraint_id)
      if (constraint) {
        constraint.normalized_value = negotiation.proposed_value
        constraint.updated_at = this.now()
      }
      negotiation.status = 'ACCEPTED'
      negotiation.responded_at = this.now()
      const result = this.runRecompute(negotiation.event_id)
      this.persist()
      return result
    }

    negotiation.status = 'REJECTED'
    negotiation.responded_at = this.now()
    this.persist()
    const latest = this.latestRunRow(negotiation.event_id)
    return latest ? { run_id: latest.id, feasible_count: latest.feasible_count } : null
  }

  async responseCount(eventId: string): Promise<number> {
    await this.latency(60)
    this.requireParticipant(eventId)
    return this.db.constraints.filter((row) => row.event_id === eventId).length
  }

  async pendingNegotiationCount(eventId: string): Promise<number> {
    await this.latency(60)
    this.requireParticipant(eventId)
    return this.db.negotiations.filter(
      (row) => row.event_id === eventId && row.status === 'PROPOSED',
    ).length
  }

  private latestRunRow(eventId: string) {
    return this.db.runs
      .filter((run) => run.event_id === eventId)
      .sort((a, b) => b.run_at.localeCompare(a.run_at))[0]
  }

  async latestRun(eventId: string): Promise<RecommendationRun | null> {
    await this.latency(60)
    const row = this.latestRunRow(eventId)
    if (!row) return null
    return {
      id: row.id,
      event_id: row.event_id,
      run_at: row.run_at,
      feasible_count: row.feasible_count,
    }
  }

  /** A leg this event already knows, from the per-event cache or the legacy JSONB. */
  private hasKnownLeg(eventId: string, participantId: string): boolean {
    const cached = (this.db.travelMatrix ?? []).some(
      (leg) => leg.event_id === eventId && leg.participant_id === participantId,
    )
    if (cached) return true
    return this.db.features.some(
      (feature) => feature.travel_minutes_by_participant[participantId] !== undefined,
    )
  }

  /**
   * Stands in for the restaurant-search Edge Function. It does not call any provider;
   * it fills in the travel matrix the real function would have computed for participants
   * that have no cached entry yet, then reports the candidate count.
   *
   * It also reports the same travel-origin coverage the real function does, computed from
   * the same rows: `travel_reference` is a CATEGORY, so a participant with no
   * `travel_reference_place_id` has no origin and is `unresolved`, and どこでも is
   * `unconstrained` — a deliberate answer, never a gap.
   *
   * The refusal is mirrored too. The real function 422s only when it must call the
   * providers, has no origin to search around, and has nothing cached to serve instead.
   * The mock has no discovery step, so its analogue of "nothing to work with" is: nobody
   * has a place id AND this event knows no travel leg for anyone. That is how the demo
   * fixture keeps working — place ids are deliberately null there, but David's legs are
   * seeded (see seed.sql), which is exactly the cached case the real function serves.
   * The fabricated minutes below still cover every participant, because they stand in for
   * a provider the mock does not have, not for a missing origin.
   */
  async findRestaurants(eventId: string): Promise<RestaurantSearchResult> {
    await this.latency(700)
    this.requireParticipant(eventId)
    const roster = this.db.participants.filter((row) => row.event_id === eventId)
    const participants = roster.filter((row) => row.travel_reference !== 'doesnt_matter')
    const coverage: TravelOriginCoverage = {
      unresolvedCount: participants.filter((row) => !row.travel_reference_place_id).length,
      unconstrainedCount: roster.filter((row) => row.travel_reference === 'doesnt_matter').length,
    }
    const resolvable = participants.filter(
      (row) => row.travel_reference_place_id !== null || this.hasKnownLeg(eventId, row.id),
    )
    if (resolvable.length === 0) throw new NoTravelOriginError(coverage)

    const travelMatrix = (this.db.travelMatrix ??= [])

    for (const feature of this.db.features) {
      for (const participant of participants) {
        const cached = travelMatrix.find(
          (leg) =>
            leg.event_id === eventId &&
            leg.participant_id === participant.id &&
            leg.place_id === feature.place_id,
        )
        // Read-through: a leg already cached for this event is not re-fetched.
        if (cached) continue

        const seeded = feature.travel_minutes_by_participant[participant.id]
        // Deterministic pseudo-travel time in 12-42 minutes, stable per (participant, place),
        // standing in for the Routes matrix the real function would compute.
        let minutes = seeded
        if (minutes === undefined) {
          let hash = 0
          const key = `${participant.id}:${feature.place_id}`
          for (let i = 0; i < key.length; i += 1) hash = (hash * 31 + key.charCodeAt(i)) >>> 0
          minutes = 12 + (hash % 31)
        }

        // travel_matrix_cache is authoritative and event-scoped (0017); the legacy JSONB
        // is merged, never replaced, so another event's legs survive.
        travelMatrix.push({
          event_id: eventId,
          participant_id: participant.id,
          place_id: feature.place_id,
          minutes,
        })
        feature.travel_minutes_by_participant[participant.id] = minutes
      }
      feature.fetched_at = this.now()
    }
    this.persist()
    return {
      candidateCount: this.db.restaurants.length,
      travel: coverage,
      // No provider to fail: the mock has none, so it never invents an incident.
      providerIncidentCount: 0,
    }
  }

  /* ----------------------------------------------------- lifecycle / readiness */

  private readinessFor(eventId: string): CollectionReadiness {
    const event = this.db.events.find((row) => row.id === eventId)
    const participants = this.db.participants.filter((row) => row.event_id === eventId)
    const responded = new Set(
      this.db.constraints
        .filter((row) => row.event_id === eventId)
        .map((row) => row.participant_id),
    ).size
    // fn_get_collection_readiness (0018): least(n, greatest(3, ceil(0.6n))).
    const n = participants.length
    const threshold = Math.min(n, Math.max(3, Math.ceil(0.6 * n)))
    const closed = Boolean(event?.preferences_closed_at)
    const met = n > 0 && responded >= threshold
    return {
      participant_count: n,
      responded_count: responded,
      threshold_count: threshold,
      threshold_met: met,
      provisional_ready: met || closed,
      preferences_closed: closed,
      preferences_closed_at: event?.preferences_closed_at ?? null,
    }
  }

  async collectionReadiness(eventId: string): Promise<CollectionReadiness> {
    await this.latency(60)
    this.requireParticipant(eventId)
    return this.readinessFor(eventId)
  }

  async closePreferences(eventId: string): Promise<CollectionReadiness> {
    await this.latency()
    const event = this.db.events.find((row) => row.id === eventId)
    if (!event) throw new Error('event not found')
    const me = this.me(eventId)
    if (!me || event.organizer_participant_id !== me.id) {
      throw new Error('only the organizer can close preference collection')
    }
    // Idempotent, and deliberately does NOT recompute: PRD 12 requires post-close
    // recalculation to be explicit.
    if (!event.preferences_closed_at) {
      event.preferences_closed_at = this.now()
      if (event.status === 'collecting') event.status = 'negotiating'
      this.persist()
      this.emit(`event-${eventId}`, 'preferences_closed', {
        preferences_closed_at: event.preferences_closed_at,
      })
    }
    return this.readinessFor(eventId)
  }

  /**
   * Stands in for the place-search Edge Function. A curated set of Tokyo stations, so the
   * travel-reference picker is exercisable with no provider key.
   */
  async searchPlaces(query: string): Promise<PlaceSuggestion[]> {
    await this.latency(280)
    const q = query.trim().toLowerCase()
    if (q.length === 0) return []
    return TOKYO_PLACES.filter(
      (place) =>
        place.name.toLowerCase().includes(q) ||
        place.romaji.includes(q) ||
        (place.address ?? '').toLowerCase().includes(q),
    )
      .slice(0, 6)
      .map(({ place_id, name, address }) => ({ place_id, name, address }))
  }

  private runRecompute(eventId: string): FeasibilityResult {
    const result = engineRecompute(
      this.db,
      eventId,
      () => newId(),
      () => this.now(),
    )
    this.emit(`event-${eventId}`, 'run_updated', {
      run_id: result.run_id,
      feasible_count: result.feasible_count,
    })
    return result
  }

  async recomputeFeasibility(eventId: string): Promise<FeasibilityResult> {
    await this.latency(400)
    this.requireParticipant(eventId)
    const result = this.runRecompute(eventId)
    this.persist()
    return result
  }

  async proposeRelaxation(eventId: string): Promise<string | null> {
    await this.latency(300)
    this.requireParticipant(eventId)
    const id = engineProposeRelaxation(
      this.db,
      eventId,
      () => newId(),
      () => this.now(),
    )
    this.persist()
    return id
  }

  async subscribeRuns(eventId: string, onUpdate: (update: RunUpdate) => void) {
    return this.subscribe(`event-${eventId}`, 'run_updated', (payload) =>
      onUpdate(payload as RunUpdate),
    )
  }

  /* ------------------------------------------------ RecommendationService */

  async scores(runId: string): Promise<RecommendationScore[]> {
    await this.latency(150)
    return this.db.scores
      .filter((score) => score.run_id === runId)
      .map((score) => ({ ...score }))
  }

  async features(placeIds: string[]): Promise<RestaurantFeature[]> {
    await this.latency(100)
    return this.db.features
      .filter((feature) => placeIds.includes(feature.place_id))
      .map((feature) => ({
        place_id: feature.place_id,
        name: feature.name,
        price_yen_estimate: feature.price_yen_estimate,
        room_type: feature.room_type,
        cuisine_tags: feature.cuisine_tags,
        atmosphere_tags: feature.atmosphere_tags,
      }))
  }

  /**
   * Stands in for llm-assist `explain` mode. The real function grounds the sentence in
   * data it fetches server-side; this composes the same facts deterministically.
   */
  async explanation(runId: string, restaurantPlaceId: string): Promise<string> {
    await this.latency(520)
    const score = this.db.scores.find(
      (row) => row.run_id === runId && row.restaurant_place_id === restaurantPlaceId,
    )
    const feature = this.db.features.find((row) => row.place_id === restaurantPlaceId)
    if (!score || !feature) return ''

    const run = this.db.runs.find((row) => row.id === runId)
    const parts: string[] = []
    if (feature.price_yen_estimate !== null) {
      parts.push(`予算は${feature.price_yen_estimate}円前後`)
    }
    const room = roomDescription(feature.room_type)
    if (room) parts.push(room)
    if (feature.atmosphere_tags.length > 0) {
      const words = feature.atmosphere_tags
        .map((tag) => ATMOSPHERE_JA[tag] ?? tag)
        .slice(0, 2)
        .join('と')
      parts.push(`${words}な雰囲気`)
    }

    const minutes = Object.values(feature.travel_minutes_by_participant)
    const travel =
      minutes.length > 0
        ? `参加者の移動時間は${Math.min(...minutes)}〜${Math.max(...minutes)}分です。`
        : ''

    const musts = run ? Number(run.input_snapshot.must_count ?? 0) : 0
    const lead = musts > 0 ? `${musts}件の必須条件をすべて満たしています。` : ''
    return `${lead}${parts.join('、')}${parts.length > 0 ? 'です。' : ''}${travel}`.trim()
  }
}

/**
 * Stand-in for Google Places results. Real place ids are opaque provider strings; these
 * are clearly marked as mock so they can never be mistaken for provider data.
 */
const TOKYO_PLACES: Array<PlaceSuggestion & { romaji: string }> = [
  { place_id: 'mock_place_shinjuku', name: '新宿駅', address: '東京都新宿区', romaji: 'shinjuku' },
  { place_id: 'mock_place_shibuya', name: '渋谷駅', address: '東京都渋谷区', romaji: 'shibuya' },
  { place_id: 'mock_place_tokyo', name: '東京駅', address: '東京都千代田区', romaji: 'tokyo' },
  { place_id: 'mock_place_shinagawa', name: '品川駅', address: '東京都港区', romaji: 'shinagawa' },
  { place_id: 'mock_place_ikebukuro', name: '池袋駅', address: '東京都豊島区', romaji: 'ikebukuro' },
  { place_id: 'mock_place_ueno', name: '上野駅', address: '東京都台東区', romaji: 'ueno' },
  { place_id: 'mock_place_akihabara', name: '秋葉原駅', address: '東京都千代田区', romaji: 'akihabara' },
  { place_id: 'mock_place_shimbashi', name: '新橋駅', address: '東京都港区', romaji: 'shimbashi' },
  { place_id: 'mock_place_nakameguro', name: '中目黒駅', address: '東京都目黒区', romaji: 'nakameguro' },
  { place_id: 'mock_place_kanda', name: '神田駅', address: '東京都千代田区', romaji: 'kanda' },
  { place_id: 'mock_place_roppongi', name: '六本木駅', address: '東京都港区', romaji: 'roppongi' },
  { place_id: 'mock_place_otemachi', name: '大手町駅', address: '東京都千代田区', romaji: 'otemachi' },
]

const ATMOSPHERE_JA: Record<string, string> = {
  quiet: '静か',
  lively: '賑やか',
  casual: 'カジュアル',
  traditional_japanese: '和風',
  stylish: 'おしゃれ',
}

/** Exposed so the engine port can be exercised from the browser console. */
export { candidateIsFeasible, countUnlockedIfRelaxed }
