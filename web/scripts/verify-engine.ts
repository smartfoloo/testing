/**
 * Asserts the TypeScript engine port reproduces the Postgres engine's behaviour on the
 * seed.sql fixture. Sections 1–8 mirror
 * AIKanji/Tests/AIKanjiDomainTests/FeasibilityEngineTests.swift tests 1–4 and were confirmed
 * against a real postgres:16 container running the actual migrations; they are the demo's
 * definition of done (0 feasible at baseline, exactly demo_place_001/002/004 after Bob
 * relaxes his room MUST) and must never be weakened.
 *
 * Sections 9–16 cover 0016_scoring_and_objective.sql, which this port mirrors statement for
 * statement: the objective weight table, the review-volume-adjusted quality signal with its
 * honest fallback, cost and accessibility burden, the fact that missing data can never
 * outscore measured data, honest labels, and the event-scoped travel lookup. Their expected
 * numbers are hand-derived from the formulas documented in engine.ts, not captured from a
 * run, so a formula change has to be justified rather than re-recorded.
 *
 * Run with `npm run verify:engine`.
 */

import {
  candidateIsFeasible,
  countUnlockedIfRelaxed,
  proposeRelaxation,
  recomputeFeasibility,
  travelMinutesFor,
  OBJECTIVE_WEIGHTS,
  type ConstraintRow,
  type Db,
  type FeatureRow,
  type ScoreRow,
} from '../src/backend/engine'
import { createSeedDb, parseConstraintText } from '../src/backend/mock'
import { SCORE_DIMENSIONS } from '../src/models/types'
import type {
  ConstraintKind,
  EventObjective,
  NormalizedType,
  NormalizedValue,
  RecommendationLabel,
} from '../src/models/types'

const DEMO_EVENT_ID = '00000000-0000-0000-0000-000000000001'
const BOB = '00000000-0000-0000-0000-0000000000b1'

let failures = 0
let checks = 0

function assert(label: string, actual: unknown, expected: unknown): void {
  checks += 1
  const left = JSON.stringify(actual)
  const right = JSON.stringify(expected)
  if (left === right) {
    console.log(`  ok   ${label}`)
  } else {
    failures += 1
    console.log(`  FAIL ${label}\n         expected ${right}\n         actual   ${left}`)
  }
}

// A single monotonic id/clock source for the whole script: two runs must never collide
// on run_id, or scores from different runs would be indistinguishable.
let idCounter = 0
const nextId = () => `00000000-0000-4000-8000-${String(idCounter++).padStart(12, '0')}`
let clockCounter = 0
const nextTime = () => new Date(Date.UTC(2026, 0, 2, 0, 0, clockCounter++)).toISOString()

function fresh(): Db {
  return createSeedDb()
}

function recompute(db: Db, eventId = DEMO_EVENT_ID) {
  return recomputeFeasibility(db, eventId, nextId, nextTime)
}

/* -------------------------------------------------------------------------- */
/* Scratch fixtures for the scoring assertions                                 */
/* -------------------------------------------------------------------------- */

const FIXED_TIME = '2026-01-02T00:00:00.000Z'

/**
 * A database with no restaurants at all. The seed fixture's four venues are a global pool,
 * so a scoring fixture has to start empty to control exactly which candidates exist.
 */
function emptyDb(): Db {
  return {
    events: [],
    participants: [],
    constraints: [],
    negotiations: [],
    restaurants: [],
    features: [],
    runs: [],
    scores: [],
  }
}

function addEvent(db: Db, objective: EventObjective = 'balanced'): string {
  const id = nextId()
  db.events.push({
    id,
    name: `scratch ${objective}`,
    invite_code: id.slice(-6),
    organizer_participant_id: null,
    objective,
    status: 'collecting',
    created_at: FIXED_TIME,
    chosen_place_id: null,
    chosen_at: null,
    preferences_closed_at: null,
  })
  return id
}

function addParticipants(db: Db, eventId: string, count: number): string[] {
  const ids: string[] = []
  for (let index = 0; index < count; index += 1) {
    const id = nextId()
    db.participants.push({
      id,
      event_id: eventId,
      auth_user_id: `scratch-user-${id}`,
      display_name: `P${index + 1}`,
      role: index === 0 ? 'organizer' : 'participant',
      travel_reference: 'office',
      travel_reference_place_id: null,
      joined_at: FIXED_TIME,
    })
    ids.push(id)
  }
  return ids
}

/** Every venue is identical unless the test says otherwise, so one dimension moves at a time. */
function addVenue(db: Db, placeId: string, feature: Partial<FeatureRow> = {}): void {
  db.restaurants.push({ place_id: placeId, hotpepper_id: null, last_fetched_at: FIXED_TIME })
  db.features.push({
    place_id: placeId,
    name: placeId,
    price_yen_estimate: 3000,
    room_type: 'open',
    cuisine_tags: [],
    dietary_tags: [],
    allergy_safe_tags: [],
    atmosphere_tags: [],
    travel_minutes_by_participant: {},
    fetched_at: FIXED_TIME,
    ...feature,
  })
}

function addConstraint(
  db: Db,
  eventId: string,
  participantId: string,
  kind: ConstraintKind,
  normalizedType: NormalizedType,
  normalizedValue: NormalizedValue,
): string {
  const id = nextId()
  db.constraints.push({
    id,
    event_id: eventId,
    participant_id: participantId,
    kind,
    raw_text: `${kind} ${normalizedType}`,
    normalized_type: normalizedType,
    normalized_value: normalizedValue,
    visibility: 'PUBLIC',
    sensitivity: 'normal',
    verification_requirement: 'none',
    semantic_remainder: null,
    created_at: FIXED_TIME,
    updated_at: FIXED_TIME,
  })
  return id
}

/** Scored rows in stored order — which is the objective ranking order. */
function scoresOf(db: Db, runId: string): ScoreRow[] {
  return db.scores.filter((score) => score.run_id === runId)
}

function rankingOf(db: Db, runId: string): string[] {
  return scoresOf(db, runId).map((score) => score.restaurant_place_id)
}

/** The metric each badge claims to lead, mirroring LABEL_METRICS in engine.ts. */
const LABEL_METRIC: Record<RecommendationLabel, (row: ScoreRow) => number | null> = {
  fairest: (row) => row.fairness_score,
  best_access: (row) => row.score_breakdown?.components.travel_access ?? null,
  best_value: (row) => row.score_breakdown?.components.cost_fit ?? null,
  best_experience: (row) => row.quality_score,
  crowd_pleaser: (row) => row.satisfaction_score,
}

/**
 * The invariant behind gap 5(b): a badge may only sit on a row that actually holds the best
 * value for the metric that badge names. Anything else is the engine lying to the group.
 */
function assertLabelsAreEarned(label: string, db: Db, runId: string): void {
  const rows = scoresOf(db, runId)
  const lies: string[] = []
  for (const row of rows) {
    if (row.label === null) continue
    const metric = LABEL_METRIC[row.label]
    const value = metric(row)
    const best = Math.max(...rows.map((other) => metric(other) ?? Number.NEGATIVE_INFINITY))
    if (value === null || value !== best) lies.push(`${row.restaurant_place_id}:${row.label}`)
  }
  assert(label, lies, [])
}

/* 1. Baseline: the five personas' MUSTs leave nothing feasible. */
console.log('1. baseline feasibility is zero')
{
  const db = fresh()
  assert('feasible_count', recompute(db).feasible_count, 0)
}

/* 2. Relaxation picks Bob's room MUST and quantifies the unlock. */
console.log('2. relaxation targets Bob\u2019s room constraint')
{
  const db = fresh()
  recompute(db)
  const negotiationId = proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime)
  assert('a proposal was created', negotiationId !== null, true)

  const row = db.negotiations.at(-1)
  assert('participant_id is Bob', row?.participant_id, BOB)
  assert('unlocked_count', row?.unlocked_count, 3)
  assert('proposed_value.room', row?.proposed_value.room, 'semi_private')

  const constraint = db.constraints.find((c) => c.id === row?.constraint_id)
  assert('constraint type', constraint?.normalized_type, 'room')
}

/* 3. Bob accepting unlocks exactly demo_place_001 / 002 / 004 — never 003. */
console.log('3. accepting unlocks exactly three venues')
{
  const db = fresh()
  recompute(db)
  const negotiationId = proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime)
  const negotiation = db.negotiations.find((row) => row.id === negotiationId)!

  // fn_respond_negotiation with p_accept = true.
  const constraint = db.constraints.find((row) => row.id === negotiation.constraint_id)!
  constraint.normalized_value = negotiation.proposed_value
  negotiation.status = 'ACCEPTED'

  const accepted = recompute(db)
  assert('feasible_count after accepting', accepted.feasible_count, 3)

  const rerun = recompute(db)
  assert('durable across a rerun', rerun.feasible_count, 3)

  const scored = db.scores
    .filter((score) => score.run_id === rerun.run_id)
    .map((score) => score.restaurant_place_id)
    .sort()
  assert('scored venues', scored, ['demo_place_001', 'demo_place_002', 'demo_place_004'])
  assert('demo_place_003 excluded', scored.includes('demo_place_003'), false)

  const labels = db.scores
    .filter((score) => score.run_id === rerun.run_id)
    .map((score) => score.label)
    .filter((label): label is NonNullable<typeof label> => label !== null)
  assert('each card gets a distinct label', new Set(labels).size, labels.length)

  // Honest labelling (0016): 001 has the shortest known commute, 002 is the cheapest, and
  // 004 leads nothing at all — so it carries no badge rather than a borrowed one. With only
  // David's travel time known, no venue is demonstrably the "fairest" either.
  const labelOf = (placeId: string) =>
    db.scores.find(
      (score) => score.run_id === rerun.run_id && score.restaurant_place_id === placeId,
    )?.label ?? null
  assert('001 genuinely leads access', labelOf('demo_place_001'), 'best_access')
  assert('002 genuinely leads value', labelOf('demo_place_002'), 'best_value')
  assert('004 leads nothing, so it is not mislabelled', labelOf('demo_place_004'), null)
  assertLabelsAreEarned('every demo badge is earned', db, rerun.run_id)
}

/* 4. Safety rule: an allergy MUST is never proposed for relaxation. */
console.log('4. a sensitive MUST is never proposed')
{
  const db = fresh()
  const scratchEventId = '00000000-0000-0000-0000-0000000000ee'
  const participantId = '00000000-0000-0000-0000-0000000000ef'
  db.events.push({
    id: scratchEventId,
    name: 'scratch allergy fixture',
    invite_code: 'scratch',
    organizer_participant_id: participantId,
    objective: 'balanced',
    status: 'collecting',
    created_at: '2026-01-02T00:00:00.000Z',
    chosen_place_id: null,
    chosen_at: null,
    preferences_closed_at: null,
  })
  db.participants.push({
    id: participantId,
    event_id: scratchEventId,
    auth_user_id: 'scratch-user',
    display_name: 'Emma',
    role: 'organizer',
    travel_reference: 'office',
    travel_reference_place_id: null,
    joined_at: '2026-01-02T00:00:00.000Z',
  })
  const peanut: ConstraintRow = {
    id: '00000000-0000-0000-0000-0000000000f0',
    event_id: scratchEventId,
    participant_id: participantId,
    kind: 'MUST',
    raw_text: 'peanut allergy',
    normalized_type: 'allergy',
    normalized_value: { allergens: ['peanut'] },
    visibility: 'ANONYMOUS',
    sensitivity: 'normal',
    verification_requirement: 'none',
    semantic_remainder: null,
    created_at: '2026-01-02T00:00:00.000Z',
    updated_at: '2026-01-02T00:00:00.000Z',
  }
  db.constraints.push(peanut)

  assert('no seeded venue is peanut-safe', recompute(db, scratchEventId).feasible_count, 0)
  const before = db.negotiations.length
  const proposal = proposeRelaxation(db, scratchEventId, nextId, nextTime)
  assert('no proposal returned', proposal, null)
  assert('nothing was written', db.negotiations.length, before)
}

/* 5. The what-if counter never mutates state. */
console.log('5. what-if counting writes nothing')
{
  const db = fresh()
  recompute(db)
  const snapshot = JSON.stringify({ n: db.negotiations, c: db.constraints })
  const room = db.constraints.find(
    (row) => row.event_id === DEMO_EVENT_ID && row.normalized_type === 'room',
  )!
  assert('relaxing the room MUST unlocks 3', countUnlockedIfRelaxed(db, DEMO_EVENT_ID, room.id), 3)
  const budget = db.constraints.find(
    (row) => row.event_id === DEMO_EVENT_ID && row.normalized_type === 'budget',
  )!
  assert('relaxing the budget MUST unlocks 0', countUnlockedIfRelaxed(db, DEMO_EVENT_ID, budget.id), 0)
  assert(
    'constraints and negotiations untouched',
    JSON.stringify({ n: db.negotiations, c: db.constraints }),
    snapshot,
  )
}

/* 6. Per-venue feasibility matches the fixture's documented intent. */
console.log('6. individual venue feasibility')
{
  const db = fresh()
  for (const placeId of ['demo_place_001', 'demo_place_002', 'demo_place_003', 'demo_place_004']) {
    assert(`${placeId} infeasible at baseline`, candidateIsFeasible(db, DEMO_EVENT_ID, placeId), false)
  }
  assert('unknown place is infeasible', candidateIsFeasible(db, DEMO_EVENT_ID, 'nope'), false)
}

/* 7. The parser emits the shapes the engine and llm-assist agree on. */
console.log('7. parser emits engine-compatible shapes')
{
  const cases: Array<[string, string, unknown]> = [
    ['4000円以内', 'budget', { max_yen: 4000 }],
    ['ベジタリアン対応', 'dietary', { tags: ['vegetarian'] }],
    ['個室が必要', 'room', { room: 'private' }],
    ['えびが食べられない', 'allergy', { allergens: ['shellfish'] }],
    ['静かに話せる場所', 'atmosphere', { tags: ['quiet'] }],
    ['和食がいい', 'cuisine', { include: ['japanese'], exclude: [] }],
    ['30分以内で行ける店', 'travel_time', { max_minutes: 30 }],
  ]
  for (const [text, type, value] of cases) {
    const parsed = parseConstraintText(text)
    assert(`"${text}" type`, parsed.normalized_type, type)
    assert(`"${text}" value`, parsed.normalized_value, value)
  }
  const vague = parseConstraintText('お酒が充実')
  assert('"お酒が充実" falls back to other', vague.normalized_type, 'other')
  assert('"お酒が充実" needs clarification', vague.needs_clarification, true)
  assert(
    'allergy defaults to ANONYMOUS',
    parseConstraintText('えびアレルギー').suggested_visibility,
    'ANONYMOUS',
  )
}

/* 8. A single-participant event can run the whole loop, which is the web demo path. */
console.log('8. solo organizer golden path')
{
  const db = fresh()
  const eventId = '00000000-0000-0000-0000-0000000000aa'
  const participantId = '00000000-0000-0000-0000-0000000000ab'
  db.events.push({
    id: eventId,
    name: '忘年会',
    invite_code: 'solo22',
    organizer_participant_id: participantId,
    objective: 'balanced',
    status: 'collecting',
    created_at: '2026-01-02T00:00:00.000Z',
    chosen_place_id: null,
    chosen_at: null,
    preferences_closed_at: null,
  })
  db.participants.push({
    id: participantId,
    event_id: eventId,
    auth_user_id: 'solo-user',
    display_name: '田中',
    role: 'organizer',
    travel_reference: 'office',
    travel_reference_place_id: null,
    joined_at: '2026-01-02T00:00:00.000Z',
  })
  const parsed = parseConstraintText('個室が必要')
  db.constraints.push({
    id: '00000000-0000-0000-0000-0000000000ac',
    event_id: eventId,
    participant_id: participantId,
    kind: 'MUST',
    raw_text: '個室が必要',
    normalized_type: parsed.normalized_type,
    normalized_value: parsed.normalized_value,
    visibility: 'PUBLIC',
    sensitivity: 'normal',
    verification_requirement: 'none',
    semantic_remainder: null,
    created_at: '2026-01-02T00:00:00.000Z',
    updated_at: '2026-01-02T00:00:00.000Z',
  })

  assert('no venue is fully private', recompute(db, eventId).feasible_count, 0)
  const proposal = proposeRelaxation(db, eventId, nextId, nextTime)
  assert('the organizer is asked about their own MUST', proposal !== null, true)
  const negotiation = db.negotiations.find((row) => row.id === proposal)!
  assert('targets the organizer', negotiation.participant_id, participantId)
  assert('unlocks three venues', negotiation.unlocked_count, 3)

  const constraint = db.constraints.find((row) => row.id === negotiation.constraint_id)!
  constraint.normalized_value = negotiation.proposed_value
  assert('accepting unlocks them', recompute(db, eventId).feasible_count, 3)
}

/* 9. The objective weight table is well formed and cannot trade away the burden floors. */
console.log('9. objective weight table')
{
  for (const objective of ['balanced', 'access', 'cost', 'experience', 'custom'] as const) {
    const weights = OBJECTIVE_WEIGHTS[objective]
    const total = SCORE_DIMENSIONS.reduce((sum, dimension) => sum + weights[dimension], 0)
    assert(`${objective} weights sum to 1`, Math.round(total * 10000) / 10000, 1)
    assert(`${objective} keeps a fairness floor`, weights.travel_fairness >= 0.1, true)
    assert(`${objective} keeps an accessibility floor`, weights.accessibility_fit >= 0.1, true)
  }
  assert(
    'custom behaves as balanced',
    OBJECTIVE_WEIGHTS.custom,
    OBJECTIVE_WEIGHTS.balanced,
  )
}

/* 10. The 幹事's objective re-orders the same feasible set, and never overrides a MUST. */
console.log('10. the event objective changes the ranking')
{
  // Two venues that disagree: one is cheap and unremarkable, one is expensive and loved.
  const build = (objective: EventObjective) => {
    const db = emptyDb()
    const eventId = addEvent(db, objective)
    const [p1, p2] = addParticipants(db, eventId, 2)
    addVenue(db, 'cheap_dive', {
      price_yen_estimate: 2500,
      rating: 3.6,
      user_rating_count: 200,
      travel_minutes_by_participant: { [p1]: 20, [p2]: 20 },
    })
    addVenue(db, 'lux_room', {
      price_yen_estimate: 9000,
      rating: 4.8,
      user_rating_count: 900,
      travel_minutes_by_participant: { [p1]: 20, [p2]: 20 },
    })
    return { db, eventId }
  }

  const cost = build('cost')
  const costRun = recompute(cost.db, cost.eventId)
  assert('cost ranks the cheap venue first', rankingOf(cost.db, costRun.run_id), [
    'cheap_dive',
    'lux_room',
  ])
  assert(
    'cost objective_score for the cheap venue',
    scoresOf(cost.db, costRun.run_id)[0]?.objective_score,
    0.7724,
  )

  const experience = build('experience')
  const experienceRun = recompute(experience.db, experience.eventId)
  assert('experience ranks the loved venue first', rankingOf(experience.db, experienceRun.run_id), [
    'lux_room',
    'cheap_dive',
  ])

  const balanced = build('balanced')
  const balancedRun = recompute(balanced.db, balanced.eventId)
  const custom = build('custom')
  const customRun = recompute(custom.db, custom.eventId)
  assert(
    'custom scores identically to balanced',
    scoresOf(custom.db, customRun.run_id).map((score) => score.objective_score),
    scoresOf(balanced.db, balancedRun.run_id).map((score) => score.objective_score),
  )

  // A weight set may only re-emphasize. The expensive venue breaks a budget MUST, and the
  // objective that loves it most still cannot bring it back.
  const gated = build('experience')
  const owner = gated.db.participants[0]!.id
  addConstraint(gated.db, gated.eventId, owner, 'MUST', 'budget', { max_yen: 4000 })
  const gatedRun = recompute(gated.db, gated.eventId)
  assert('the MUST still gates the candidate set', gatedRun.feasible_count, 1)
  assert('the objective cannot resurrect it', rankingOf(gated.db, gatedRun.run_id), ['cheap_dive'])
}

/* 11. Gap 5(a): a venue we barely have travel data for can never win on fairness. */
console.log('11. missing travel data never wins on fairness')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1, p2, p3] = addParticipants(db, eventId, 3)
  // One known leg out of three participants — this used to score a perfect 1.0000.
  addVenue(db, 'sparse_data', { travel_minutes_by_participant: { [p1]: 20 } })
  // Fully measured, and genuinely unfair: 5 / 30 / 75 minutes.
  addVenue(db, 'measured_spread', {
    travel_minutes_by_participant: { [p1]: 5, [p2]: 30, [p3]: 75 },
  })

  const run = recompute(db, eventId)
  const rows = scoresOf(db, run.run_id)
  const sparse = rows.find((row) => row.restaurant_place_id === 'sparse_data')!
  const measured = rows.find((row) => row.restaurant_place_id === 'measured_spread')!

  assert('one known leg out of three is not perfect fairness', sparse.fairness_score, 0.0667)
  assert('a measured 70-minute spread scores above it', measured.fairness_score, 0.44)
  assert('missing data loses', measured.fairness_score! > sparse.fairness_score!, true)
  assert('incomplete travel is banded below complete travel', sparse.fairness_score! < 0.2, true)
  assert('complete travel is banded at or above 0.2', measured.fairness_score! >= 0.2, true)
  assert('the breakdown records the coverage', sparse.score_breakdown?.travel, {
    participants: 3,
    known: 1,
    spread_minutes: 0,
    average_minutes: 20,
    complete: false,
    fairness: 0.0667,
    access: 0.0556,
  })
  assert('the fairest badge goes to the measured venue', measured.label, 'fairest')
  assert('the sparse venue leads nothing and gets no badge', sparse.label, null)
  assertLabelsAreEarned('no badge is unearned', db, run.run_id)
}

/* 12. Gap 5(b): the badge a row cannot earn is dropped, not passed to the next row. */
console.log('12. labels are never handed to a row that does not lead')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1, p2, p3] = addParticipants(db, eventId, 3)
  addVenue(db, 'even_commute', {
    travel_minutes_by_participant: { [p1]: 10, [p2]: 10, [p3]: 10 },
  })
  // 75 minutes for one participant. The old greedy pass called this `best_access`, because
  // `even_commute` had already taken `fairest`.
  addVenue(db, 'lopsided_commute', {
    travel_minutes_by_participant: { [p1]: 10, [p2]: 10, [p3]: 75 },
  })

  const run = recompute(db, eventId)
  const rows = scoresOf(db, run.run_id)
  const even = rows.find((row) => row.restaurant_place_id === 'even_commute')!
  const lopsided = rows.find((row) => row.restaurant_place_id === 'lopsided_commute')!

  assert('the even commute is the fairest', even.label, 'fairest')
  assert('a 75-minute leg is not "best access"', lopsided.label === 'best_access', false)
  assert('and it is not given some other badge either', lopsided.label, null)
  assert('access is scored, just not led', lopsided.score_breakdown?.components.travel_access, 0.7889)
  assertLabelsAreEarned('no badge is unearned', db, run.run_id)
}

/* 13. Gap 2: quality is review-volume adjusted, and falls back honestly. */
console.log('13. quality is adjusted for review volume')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  addVenue(db, 'hype_new', { rating: 5, user_rating_count: 3, travel_minutes_by_participant: travel })
  addVenue(db, 'proven', { rating: 4.3, user_rating_count: 800, travel_minutes_by_participant: travel })
  addVenue(db, 'unrated_rich_tags', {
    atmosphere_tags: ['quiet', 'casual', 'lively'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'rated_terrible', {
    rating: 1,
    user_rating_count: 5000,
    travel_minutes_by_participant: travel,
  })

  const run = recompute(db, eventId)
  const rows = scoresOf(db, run.run_id)
  const quality = (placeId: string) =>
    rows.find((row) => row.restaurant_place_id === placeId)!.quality_score!
  const method = (placeId: string) =>
    rows.find((row) => row.restaurant_place_id === placeId)!.score_breakdown?.quality.method

  assert('5.0 from 3 reviews is shrunk toward the prior', quality('hype_new'), 0.7925)
  assert('4.3 from 800 reviews holds', quality('proven'), 0.8553)
  assert('volume beats a small perfect score', quality('proven') > quality('hype_new'), true)
  assert('rated venues report the method', method('proven'), 'rating_bayesian_shrunk')

  assert('no rating falls back to the tag proxy', quality('unrated_rich_tags'), 0.2)
  assert('the fallback is recorded', method('unrated_rich_tags'), 'atmosphere_tag_proxy')
  assert(
    'missing rating data never scores better than present data',
    quality('unrated_rich_tags') < quality('rated_terrible'),
    true,
  )
  assert('a 1.0 from 5000 reviews still beats "unknown"', quality('rated_terrible'), 0.2057)
  assert('the best experience badge follows the real signal', 
    rows.find((row) => row.label === 'best_experience')?.restaurant_place_id, 'proven')
  assertLabelsAreEarned('no badge is unearned', db, run.run_id)
}

/* 14. Gap 3: cost burden is measured against the tightest budget in the group. */
console.log('14. cost burden is populated and tracks the tightest budget')
{
  const db = fresh()
  recompute(db)
  const negotiationId = proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime)
  const negotiation = db.negotiations.find((row) => row.id === negotiationId)!
  db.constraints.find((row) => row.id === negotiation.constraint_id)!.normalized_value =
    negotiation.proposed_value
  const run = recompute(db)
  const rows = scoresOf(db, run.run_id)
  const burden = (placeId: string) =>
    rows.find((row) => row.restaurant_place_id === placeId)!.cost_burden_score

  // Alice's 4000 yen MUST is the only budget in the fixture.
  assert('3800 against a 4000 ceiling', burden('demo_place_001'), 0.95)
  assert('3500 against a 4000 ceiling', burden('demo_place_002'), 0.875)
  assert('3900 against a 4000 ceiling', burden('demo_place_004'), 0.975)
  assert(
    'the breakdown names the ceiling it used',
    rows[0]?.score_breakdown?.cost.tightest_budget_yen,
    4000,
  )
  assert('nobody asked for accessibility here', burden('demo_place_002') !== null, true)
  assert(
    'so accessibility burden is zero, not unknown',
    rows.map((row) => row.accessibility_burden_score),
    [0, 0, 0],
  )
  assert('the cheapest venue takes the value badge',
    rows.find((row) => row.label === 'best_value')?.restaurant_place_id, 'demo_place_002')
  assertLabelsAreEarned('no badge is unearned', db, run.run_id)

  // An unpriced venue is the worst case, never a free one.
  const scratch = emptyDb()
  const eventId = addEvent(scratch)
  const [p1] = addParticipants(scratch, eventId, 1)
  addVenue(scratch, 'priced', { price_yen_estimate: 3000, travel_minutes_by_participant: { [p1]: 10 } })
  addVenue(scratch, 'unpriced', {
    price_yen_estimate: null,
    travel_minutes_by_participant: { [p1]: 10 },
  })
  const scratchRun = recompute(scratch, eventId)
  const unpriced = scoresOf(scratch, scratchRun.run_id).find(
    (row) => row.restaurant_place_id === 'unpriced',
  )!
  assert('an unknown price is full cost burden', unpriced.cost_burden_score, 1)
  assert('with no budget MUST the documented reference is used',
    unpriced.score_breakdown?.cost.reference_yen, 6000)
  assert('and the priced venue is ranked first', rankingOf(scratch, scratchRun.run_id)[0], 'priced')
}

/* 15. Gap 3: accessibility burden, where "no data" is never "supported". */
console.log('15. accessibility burden treats unknown as unmet')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  addConstraint(db, eventId, p1, 'MUST', 'accessibility', { needs: ['step_free', 'wheelchair'] })
  addVenue(db, 'barrier_free', {
    accessibility_tags: ['step_free', 'wheelchair'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'step_free_only', {
    accessibility_tags: ['step_free'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'no_data', { travel_minutes_by_participant: travel })

  const run = recompute(db, eventId)
  // The accessibility MUST is not a feasibility gate (no branch in fn_candidate_is_feasible),
  // so it must not silently exclude anything — it can only change the ranking.
  assert('accessibility never gates feasibility', run.feasible_count, 3)
  const rows = scoresOf(db, run.run_id)
  const row = (placeId: string) => rows.find((entry) => entry.restaurant_place_id === placeId)!

  assert('both needs met', row('barrier_free').accessibility_burden_score, 0)
  assert('one of two needs met', row('step_free_only').accessibility_burden_score, 0.5)
  assert('no data at all is full burden', row('no_data').accessibility_burden_score, 1)
  assert('and it is reported as missing data', row('no_data').score_breakdown?.accessibility, {
    burden: 1,
    needs: ['step_free', 'wheelchair'],
    unmet_needs: ['step_free', 'wheelchair'],
    venue_tags: [],
    data_present: false,
    requests: 1,
  })
  assert('the unmet need is named', row('step_free_only').score_breakdown?.accessibility.unmet_needs, [
    'wheelchair',
  ])
  assert('accessibility orders the cards', rankingOf(db, run.run_id), [
    'barrier_free',
    'step_free_only',
    'no_data',
  ])
  assert(
    'an accessibility MUST is still never proposed for relaxation',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )
}

/* 16. The travel contract: event-scoped cache first, legacy JSONB second, unknown last. */
console.log('16. travel minutes are read event-scoped, with a fallback')
{
  const db = emptyDb()
  const eventA = addEvent(db)
  const eventB = addEvent(db)
  const [a1] = addParticipants(db, eventA, 1)
  const [b1] = addParticipants(db, eventB, 1)
  // The legacy map is global: both events share it, which is what broke event-scoping.
  addVenue(db, 'shared_place', { travel_minutes_by_participant: { [a1]: 45, [b1]: 12 } })
  db.travelMatrix = [{ event_id: eventA, participant_id: a1, place_id: 'shared_place', minutes: 15 }]

  assert('the cache wins for its own event', travelMinutesFor(db, eventA, 'shared_place', a1), 15)
  assert('other events fall back to the JSONB', travelMinutesFor(db, eventB, 'shared_place', b1), 12)
  assert(
    'unknown means null, not zero',
    travelMinutesFor(db, eventA, 'shared_place', 'nobody'),
    null,
  )

  addConstraint(db, eventA, a1, 'MUST', 'travel_time', { max_minutes: 20 })
  addConstraint(db, eventB, b1, 'MUST', 'travel_time', { max_minutes: 10 })
  assert(
    'event A is judged on its own cached 15 minutes',
    candidateIsFeasible(db, eventA, 'shared_place'),
    true,
  )
  assert(
    "event B is judged on its own 12 minutes, not A's",
    candidateIsFeasible(db, eventB, 'shared_place'),
    false,
  )

  const runA = recompute(db, eventA)
  assert(
    'scoring reads the cache too',
    scoresOf(db, runA.run_id)[0]?.score_breakdown?.travel.average_minutes,
    15,
  )

  // Existing callers have no travelMatrix at all, and must keep working off the JSONB.
  delete db.travelMatrix
  assert('without a cache the JSONB decides', travelMinutesFor(db, eventA, 'shared_place', a1), 45)
  assert(
    'and the same MUST now fails',
    candidateIsFeasible(db, eventA, 'shared_place'),
    false,
  )
}

console.log(`\n${checks - failures}/${checks} checks passed`)
if (failures > 0) {
  console.error(`${failures} check(s) failed`)
  process.exit(1)
}
