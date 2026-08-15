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
 * Sections 17–20 cover 0021_must_coverage_and_proposal_integrity.sql, one section per bug:
 * an accessibility MUST is enforced fail-closed and stays un-negotiable (17), a smoking MUST
 * is enforced and escapable through exactly one documented step (18), a malformed integer is
 * absent rather than an exception or a loophole (19), and proposing a relaxation is idempotent
 * per event, including the different-constraint and REJECTED cases (20). The same four bugs
 * are asserted against real Postgres in AIKanji/supabase/tests/backend_tests.sql; if the two
 * suites ever disagree, the SQL is authoritative and this port is wrong.
 *
 * Sections 21–22 cover 0022_accessibility_vocabulary_and_room_unknown.sql: the closed
 * accessibility vocabulary both sides now speak, what happens to a need it cannot express, and
 * the coverage count that keeps a zero-candidate result explainable (21); and the room step
 * that stops a 個室 MUST from dead-ending on a Places-only candidate set, without ever
 * admitting a venue known to be the wrong room type (22).
 *
 * Section 23 covers 0026_allergen_vocabulary_and_unverified_coverage.sql — the same shape of bug
 * in the most safety-critical category. It asserts the closed allergen and dietary vocabularies,
 * that a Japanese allergen (what the live model actually returned for
 * 「えびとかにのアレルギーがあります」) can never match a venue, that an allergen the vocabulary
 * cannot express stays a GATING allergy MUST with the writer's words preserved rather than
 * degrading to a note, that allergy is still never negotiable, and that
 * `allergy_unverified_count` makes the resulting zero legible instead of silent.
 *
 * Run with `npm run verify:engine`.
 */

import {
  ACCESSIBILITY_VOCABULARY,
  ALLERGEN_VOCABULARY,
  DIETARY_VOCABULARY,
  candidateBlockingTypes,
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
  // A WANT, not a MUST. Since 0021 an accessibility MUST is a hard gate (section 17), so the
  // only way to observe how burden ORDERS venues is a requirement that does not exclude them.
  // fn_accessibility_burden counts MUST and WANT rows alike, which is exactly the point: a
  // WANT has nowhere else to be honoured at all.
  // Vocabulary members since 0022 — the venue-side CHECK refuses anything else, so a fixture
  // with invented tags would no longer be reachable in Postgres.
  addConstraint(db, eventId, p1, 'WANT', 'accessibility', {
    needs: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
  })
  addVenue(db, 'barrier_free', {
    accessibility_tags: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'step_free_only', {
    accessibility_tags: ['wheelchair_accessible_entrance'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'no_data', { travel_minutes_by_participant: travel })

  const run = recompute(db, eventId)
  // A WANT is never a feasibility gate, so it must not exclude anything — it can only
  // change the ranking.
  assert('an accessibility WANT never gates feasibility', run.feasible_count, 3)
  const rows = scoresOf(db, run.run_id)
  const row = (placeId: string) => rows.find((entry) => entry.restaurant_place_id === placeId)!

  assert('both needs met', row('barrier_free').accessibility_burden_score, 0)
  assert('one of two needs met', row('step_free_only').accessibility_burden_score, 0.5)
  assert('no data at all is full burden', row('no_data').accessibility_burden_score, 1)
  assert('and it is reported as missing data', row('no_data').score_breakdown?.accessibility, {
    burden: 1,
    needs: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
    unmet_needs: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
    venue_tags: [],
    data_present: false,
    requests: 1,
  })
  assert('the unmet need is named', row('step_free_only').score_breakdown?.accessibility.unmet_needs, [
    'wheelchair_accessible_restroom',
  ])
  assert('accessibility orders the cards', rankingOf(db, run.run_id), [
    'barrier_free',
    'step_free_only',
    'no_data',
  ])
  assert(
    'an accessibility row is never proposed for relaxation',
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

/* 17. Bug 1a: an accessibility MUST is enforced, fail-closed, and never relaxable. */
console.log('17. an accessibility MUST gates feasibility')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  addConstraint(db, eventId, p1, 'MUST', 'accessibility', {
    needs: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
  })
  addVenue(db, 'barrier_free', {
    accessibility_tags: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'step_free_only', {
    accessibility_tags: ['wheelchair_accessible_entrance'],
    travel_minutes_by_participant: travel,
  })
  // No accessibility_tags at all — the state every venue was in before 0022 gave the column a
  // writer, and the state every venue Places says nothing about is still in.
  addVenue(db, 'no_data', { travel_minutes_by_participant: travel })

  assert('every need met is feasible', candidateIsFeasible(db, eventId, 'barrier_free'), true)
  assert(
    'a partially accessible venue is infeasible',
    candidateIsFeasible(db, eventId, 'step_free_only'),
    false,
  )
  // This is the bug: 「車椅子で入れる店」 used to be silently satisfied here.
  assert(
    'absent venue data is infeasible, not satisfied',
    candidateIsFeasible(db, eventId, 'no_data'),
    false,
  )

  const run = recompute(db, eventId)
  assert('only the venue that meets every need survives', run.feasible_count, 1)
  assert('and it is the only card', rankingOf(db, run.run_id), ['barrier_free'])
  assert(
    'the need is still never proposed for relaxation',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )

  // A MUST whose own value cannot be read is not a MUST we may certify as met.
  const unreadable = emptyDb()
  const unreadableEvent = addEvent(unreadable)
  const [q1] = addParticipants(unreadable, unreadableEvent, 1)
  addConstraint(unreadable, unreadableEvent, q1, 'MUST', 'accessibility', { needs: [] })
  addVenue(unreadable, 'barrier_free', {
    accessibility_tags: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
    travel_minutes_by_participant: { [q1]: 20 },
  })
  assert(
    'an empty needs array fails closed',
    candidateIsFeasible(unreadable, unreadableEvent, 'barrier_free'),
    false,
  )
}

/* 18. Bug 1b: a smoking MUST is enforced, and escapable through one documented step. */
console.log('18. a smoking MUST gates feasibility and can be negotiated')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  const smokingId = addConstraint(db, eventId, p1, 'MUST', 'smoking', {
    preference: 'non_smoking',
  })
  addVenue(db, 'confirmed_non_smoking', {
    smoking_policy: 'non_smoking',
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'smoky_izakaya', {
    smoking_policy: 'smoking_ok',
    travel_minutes_by_participant: travel,
  })
  // No smoking_policy: the state every venue is in until somebody records one.
  addVenue(db, 'unconfirmed', { travel_minutes_by_participant: travel })

  assert(
    'a confirmed non-smoking venue passes',
    candidateIsFeasible(db, eventId, 'confirmed_non_smoking'),
    true,
  )
  assert(
    'a venue known to allow smoking fails',
    candidateIsFeasible(db, eventId, 'smoky_izakaya'),
    false,
  )
  // This is the bug: a smoking MUST used to be silently satisfied by every venue.
  assert(
    'an unconfirmed venue fails — unknown is not non-smoking',
    candidateIsFeasible(db, eventId, 'unconfirmed'),
    false,
  )
  assert('baseline feasibility', recompute(db, eventId).feasible_count, 1)

  // The escape hatch: without a relaxation step this MUST would be a dead end on real data,
  // where nothing fills smoking_policy at all.
  assert('the step unlocks the unconfirmed venue', countUnlockedIfRelaxed(db, eventId, smokingId), 1)
  const proposalId = proposeRelaxation(db, eventId, nextId, nextTime)
  assert('a smoking MUST is negotiable', proposalId !== null, true)
  const negotiation = db.negotiations.find((row) => row.id === proposalId)!
  assert('the proposal keeps the preference and only accepts unknowns', negotiation.proposed_value, {
    preference: 'non_smoking',
    accept_unknown: true,
  })
  assert('and quantifies the unlock', negotiation.unlocked_count, 1)

  // fn_respond_negotiation with p_accept = true.
  db.constraints.find((row) => row.id === negotiation.constraint_id)!.normalized_value =
    negotiation.proposed_value
  negotiation.status = 'ACCEPTED'
  assert(
    'accepting admits the unconfirmed venue',
    candidateIsFeasible(db, eventId, 'unconfirmed'),
    true,
  )
  assert(
    'but never the venue known to allow smoking',
    candidateIsFeasible(db, eventId, 'smoky_izakaya'),
    false,
  )
  assert('feasibility after accepting', recompute(db, eventId).feasible_count, 2)

  // The other direction is symmetric: somebody who wants to be able to smoke.
  const smoker = emptyDb()
  const smokerEvent = addEvent(smoker)
  const [s1] = addParticipants(smoker, smokerEvent, 1)
  addConstraint(smoker, smokerEvent, s1, 'MUST', 'smoking', { preference: 'smoking_ok' })
  addVenue(smoker, 'smoky_izakaya', {
    smoking_policy: 'smoking_ok',
    travel_minutes_by_participant: { [s1]: 20 },
  })
  addVenue(smoker, 'confirmed_non_smoking', {
    smoking_policy: 'non_smoking',
    travel_minutes_by_participant: { [s1]: 20 },
  })
  assert(
    'a smoking_ok MUST is met by a smoking venue',
    candidateIsFeasible(smoker, smokerEvent, 'smoky_izakaya'),
    true,
  )
  assert(
    'and not by a non-smoking one',
    candidateIsFeasible(smoker, smokerEvent, 'confirmed_non_smoking'),
    false,
  )

  // An unreadable preference fails closed, and its step unlocks nothing, so nobody is asked
  // a question the engine cannot phrase.
  const malformed = emptyDb()
  const malformedEvent = addEvent(malformed)
  const [m1] = addParticipants(malformed, malformedEvent, 1)
  addConstraint(malformed, malformedEvent, m1, 'MUST', 'smoking', { preference: 'たばこ' })
  addVenue(malformed, 'confirmed_non_smoking', {
    smoking_policy: 'non_smoking',
    travel_minutes_by_participant: { [m1]: 20 },
  })
  assert(
    'an unreadable smoking preference fails closed',
    candidateIsFeasible(malformed, malformedEvent, 'confirmed_non_smoking'),
    false,
  )
  assert(
    'and is not proposed, because the step would unlock nothing',
    proposeRelaxation(malformed, malformedEvent, nextId, nextTime),
    null,
  )
}

/* 19. Bug 3: one malformed constraint no longer breaks the event's engine. */
console.log('19. a malformed integer is treated as absent, never as an error')
{
  // RLS lets any participant write an arbitrary normalized_value, and in Postgres
  // (v->>'max_yen')::int raised invalid_text_representation on this row — aborting the whole
  // event's recompute. Both implementations now read it through the same NULL rule.
  const db = fresh()
  const budget = db.constraints.find(
    (row) => row.event_id === DEMO_EVENT_ID && row.normalized_type === 'budget',
  )!
  budget.normalized_value = { max_yen: 'cheap' }

  const baseline = recompute(db)
  assert('the recompute completes', baseline.feasible_count, 0)
  // …and the malformed row did not open the floodgates either: Bob's room MUST still gates.
  const proposalId = proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime)
  assert('a proposal is still produced', proposalId !== null, true)
  const negotiation = db.negotiations.find((row) => row.id === proposalId)!
  assert('and it still targets the room MUST', negotiation.proposed_value.room, 'semi_private')
  db.constraints.find((row) => row.id === negotiation.constraint_id)!.normalized_value =
    negotiation.proposed_value
  negotiation.status = 'ACCEPTED'
  assert('the 0-then-3 invariant survives a junk budget row', recompute(db).feasible_count, 3)

  // The documented semantics of "absent": `price > null` is falsey, so a PRICED venue passes
  // a ceiling it cannot read — exactly as it always did for a missing key — while an UNPRICED
  // venue still fails, because that branch is an explicit null check and not a comparison.
  const scratch = emptyDb()
  const eventId = addEvent(scratch)
  const [p1] = addParticipants(scratch, eventId, 1)
  addConstraint(scratch, eventId, p1, 'MUST', 'budget', { max_yen: 'cheap' })
  addVenue(scratch, 'priced', {
    price_yen_estimate: 3000,
    travel_minutes_by_participant: { [p1]: 20 },
  })
  addVenue(scratch, 'unpriced', {
    price_yen_estimate: null,
    travel_minutes_by_participant: { [p1]: 20 },
  })
  assert(
    'a priced venue is judged as if the ceiling were absent',
    candidateIsFeasible(scratch, eventId, 'priced'),
    true,
  )
  assert(
    'an unknown price never satisfies a budget MUST',
    candidateIsFeasible(scratch, eventId, 'unpriced'),
    false,
  )
  assert('so exactly one venue is feasible', recompute(scratch, eventId).feasible_count, 1)

  // The same rule fn_jsonb_int applies, so neither implementation invents a number the other
  // would not: a fully numeric string IS the number, a partly numeric one is absent.
  const scratchBudget = scratch.constraints.find((row) => row.normalized_type === 'budget')!
  scratchBudget.normalized_value = { max_yen: '2000' }
  assert(
    'a numeric string is read as the number it spells',
    candidateIsFeasible(scratch, eventId, 'priced'),
    false,
  )
  scratchBudget.normalized_value = { max_yen: '40abc' }
  assert(
    'a partly numeric value is absent, not 40',
    candidateIsFeasible(scratch, eventId, 'priced'),
    true,
  )

  // max_minutes has the same exposure and the same rule.
  const travelDb = emptyDb()
  const travelEvent = addEvent(travelDb)
  const [t1] = addParticipants(travelDb, travelEvent, 1)
  addConstraint(travelDb, travelEvent, t1, 'MUST', 'travel_time', { max_minutes: 'すぐ' })
  addVenue(travelDb, 'near', { travel_minutes_by_participant: { [t1]: 10 } })
  assert(
    'a malformed max_minutes is absent, not an error',
    candidateIsFeasible(travelDb, travelEvent, 'near'),
    true,
  )
  assert('and the run completes', recompute(travelDb, travelEvent).feasible_count, 1)
}

/* 20. Bug 4: proposing a relaxation is idempotent. */
console.log('20. a second propose returns the same negotiation')
{
  const db = fresh()
  recompute(db)
  const first = proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime)
  const repeats = [
    proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime),
    proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime),
    proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime),
  ]
  assert('the first press proposes something', first !== null, true)
  // Measured before the fix: 4 calls → 4 PROPOSED rows, and Bob was asked four times.
  assert('three more presses return the same negotiation', repeats, [first, first, first])
  assert(
    'exactly one negotiation exists',
    db.negotiations.filter((row) => row.event_id === DEMO_EVENT_ID).length,
    1,
  )
  assert(
    'and exactly one question is open',
    db.negotiations.filter(
      (row) => row.event_id === DEMO_EVENT_ID && row.status === 'PROPOSED',
    ).length,
    1,
  )

  // The open proposal wins even when another constraint would now unlock more: retargeting
  // would withdraw a question somebody is looking at, or ask a second person before the first
  // answered. The better target is deferred one round, not dropped.
  const other = db.constraints.find(
    (row) => row.event_id === DEMO_EVENT_ID && row.normalized_type === 'travel_time',
  )!
  const open = db.negotiations.find((row) => row.id === first)!
  open.constraint_id = other.id
  open.participant_id = other.participant_id
  open.proposed_value = { max_minutes: 45 }
  const deferred = proposeRelaxation(db, DEMO_EVENT_ID, nextId, nextTime)
  assert('an open proposal for another constraint is returned as is', deferred, first)
  assert(
    'and nothing was written for the better target',
    db.negotiations.filter((row) => row.event_id === DEMO_EVENT_ID).length,
    1,
  )

  // Rejection is final for THAT question: re-asking it is the pressure the PRD forbids.
  const rejected = fresh()
  recompute(rejected)
  const askedId = proposeRelaxation(rejected, DEMO_EVENT_ID, nextId, nextTime)
  const asked = rejected.negotiations.find((row) => row.id === askedId)!
  asked.status = 'REJECTED'
  asked.responded_at = nextTime()
  assert(
    'a rejected step is never re-proposed',
    proposeRelaxation(rejected, DEMO_EVENT_ID, nextId, nextTime),
    null,
  )
  assert('and no second row is written', rejected.negotiations.length, 1)

  // …but a genuinely different question is allowed, so one "no" cannot dead-end the event.
  const edited = emptyDb()
  const eventId = addEvent(edited)
  const [p1] = addParticipants(edited, eventId, 1)
  const budgetId = addConstraint(edited, eventId, p1, 'MUST', 'budget', { max_yen: 4000 })
  addVenue(edited, 'slightly_over', {
    price_yen_estimate: 4300,
    travel_minutes_by_participant: { [p1]: 20 },
  })
  assert('nothing fits the stated budget', recompute(edited, eventId).feasible_count, 0)
  const firstAskId = proposeRelaxation(edited, eventId, nextId, nextTime)
  const firstAsk = edited.negotiations.find((row) => row.id === firstAskId)!
  assert('+500 yen is proposed', firstAsk.proposed_value, { max_yen: 4500 })
  firstAsk.status = 'REJECTED'
  firstAsk.responded_at = nextTime()
  assert(
    'the same +500 step is not asked again',
    proposeRelaxation(edited, eventId, nextId, nextTime),
    null,
  )

  // The participant moves their own ceiling, so the step is a different question now.
  edited.constraints.find((row) => row.id === budgetId)!.normalized_value = { max_yen: 4200 }
  const secondAskId = proposeRelaxation(edited, eventId, nextId, nextTime)
  assert('a different step may be asked', secondAskId !== null, true)
  assert(
    'and it is the new step, not the rejected one',
    edited.negotiations.find((row) => row.id === secondAskId)?.proposed_value,
    { max_yen: 4700 },
  )
}

/* 21. 0022 bug A: one closed accessibility vocabulary, and a zero that explains itself. */
console.log('21. the accessibility vocabulary is closed, and its exclusions are legible')
{
  // The vocabulary is the four nullable booleans Places returns in `accessibilityOptions`,
  // named after them. Asserted against a literal, exactly as backend_tests.sql asserts
  // fn_accessibility_vocabulary(), so the two implementations cannot drift.
  assert('the vocabulary is the four Places accessibilityOptions booleans', [...ACCESSIBILITY_VOCABULARY], [
    'wheelchair_accessible_entrance',
    'wheelchair_accessible_parking',
    'wheelchair_accessible_restroom',
    'wheelchair_accessible_seating',
  ])

  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  addConstraint(db, eventId, p1, 'MUST', 'budget', { max_yen: 4000 })
  const needsId = addConstraint(db, eventId, p1, 'MUST', 'accessibility', {
    needs: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
  })
  addVenue(db, 'confirmed', {
    accessibility_tags: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'partly_confirmed', {
    accessibility_tags: ['wheelchair_accessible_entrance'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'unverified', { travel_minutes_by_participant: travel })
  // Over budget as well, so confirming its entrance would NOT put it on the shortlist.
  addVenue(db, 'unverified_and_pricey', {
    price_yen_estimate: 9000,
    travel_minutes_by_participant: travel,
  })

  assert(
    'an accessibility MUST is met when the recorded tags cover the needs',
    candidateIsFeasible(db, eventId, 'confirmed'),
    true,
  )
  assert(
    'tags covering only part of the needs stay infeasible',
    candidateIsFeasible(db, eventId, 'partly_confirmed'),
    false,
  )
  assert(
    'and no recorded tags at all stays infeasible',
    candidateIsFeasible(db, eventId, 'unverified'),
    false,
  )

  // The single MUST chain, now answerable: which types stand in the way?
  assert('blocking types name accessibility alone', candidateBlockingTypes(db, eventId, 'unverified'), [
    'accessibility',
  ])
  assert(
    'and name both obstacles when there are two',
    candidateBlockingTypes(db, eventId, 'unverified_and_pricey'),
    ['accessibility', 'budget'],
  )
  assert('a feasible venue is blocked by nothing', candidateBlockingTypes(db, eventId, 'confirmed'), [])
  assert('an unknown venue is not an accessibility exclusion', candidateBlockingTypes(db, eventId, 'nope'), [
    'unknown_venue',
  ])

  const run = recompute(db, eventId)
  assert('only the fully confirmed venue is feasible', run.feasible_count, 1)
  // The whole point: 「N件は車椅子対応が確認できませんでした（お店に確認できます）」 rather than 「0件」.
  // `unverified_and_pricey` is excluded from the count because a phone call cannot fix its price.
  assert('the payload counts the venues only missing accessibility proof', run.accessibility_unverified_count, 2)
  assert(
    'the accessibility MUST is still never proposed for relaxation',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )

  // What the boundary protects against: one unmatchable need excludes all of Tokyo, and there
  // is no relaxation to escape through — which is why llm-assist filters `needs` server-side
  // and keeps the wording in semantic_remainder instead of storing it.
  db.constraints.find((row) => row.id === needsId)!.normalized_value = { needs: ['elevator'] }
  const dead = recompute(db, eventId)
  assert('an out-of-vocabulary need can never be matched by any venue', dead.feasible_count, 0)
  assert('and every candidate is reported as accessibility-only', dead.accessibility_unverified_count, 3)
  assert(
    'and it is still not negotiable',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )

  // So the parser never produces one. It emits vocabulary members, and an accessibility need
  // the vocabulary cannot express becomes a non-gating note that keeps the participant's own
  // words and asks for clarification — never {"needs": []}, which would be that same dead end.
  const entrance = parseConstraintText('車椅子で入れる店がいい', 'MUST')
  assert('「車椅子で入れる店」 is an accessibility MUST', entrance.normalized_type, 'accessibility')
  assert('mapped onto the entrance boolean', entrance.normalized_value, {
    needs: ['wheelchair_accessible_entrance'],
  })
  assert('and it still requires human confirmation', entrance.verification_requirement, 'required')
  const restroom = parseConstraintText('車椅子対応のトイレがある店', 'MUST')
  assert('a restroom request adds its own member', restroom.normalized_value, {
    needs: ['wheelchair_accessible_entrance', 'wheelchair_accessible_restroom'],
  })
  const elevator = parseConstraintText('エレベーターがある店', 'MUST')
  assert('an unexpressible need is not an accessibility MUST', elevator.normalized_type, 'other')
  assert('it is not silently dropped either', elevator.semantic_remainder, 'エレベーターがある店')
  assert('a human is asked about it', elevator.needs_clarification, true)
  assert('and it keeps the private default', elevator.suggested_visibility, 'ANONYMOUS')

  // Whatever the phrasing, the parser can only ever emit vocabulary members: anything else
  // would be a MUST no venue tag could match.
  const emitted = [
    '車椅子で入れる店',
    'バリアフリーのお店',
    '段差がないところ',
    '車椅子対応のトイレと車椅子席がある店',
    '車椅子で使える駐車場がほしい',
    'wheelchair accessible please',
  ].flatMap((text) => {
    const parsed = parseConstraintText(text, 'MUST')
    const needs = parsed.normalized_value.needs
    return Array.isArray(needs) ? needs.map(String) : []
  })
  assert('the parser only ever emits vocabulary members', emitted.length > 0, true)
  assert(
    'and never invents one outside it',
    emitted.filter((need) => !(ACCESSIBILITY_VOCABULARY as readonly string[]).includes(need)),
    [],
  )
}

/* 22. 0022 bug B: a room MUST no longer dead-ends on a Places-only candidate set. */
console.log('22. a room MUST is escapable, and consent does not admit the wrong room type')
{
  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  const roomId = addConstraint(db, eventId, p1, 'MUST', 'room', { room: 'private' })
  // room_type is filled only from Hot Pepper, so a candidate Places found and Hot Pepper did
  // not match has NULL — which is most of Tokyo, and which used to be infeasible before AND
  // after the private → semi_private step, so no question was ever asked.
  addVenue(db, 'unconfirmed_room', { room_type: null, travel_minutes_by_participant: travel })
  addVenue(db, 'confirmed_semi', {
    room_type: 'semi_private',
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'known_open', { room_type: 'open', travel_minutes_by_participant: travel })

  assert('a 個室 MUST leaves nothing feasible', recompute(db, eventId).feasible_count, 0)
  assert(
    'an unconfirmed room type is infeasible, never silently satisfied',
    candidateIsFeasible(db, eventId, 'unconfirmed_room'),
    false,
  )
  assert('and the room MUST is what blocks it', candidateBlockingTypes(db, eventId, 'unconfirmed_room'), [
    'room',
  ])

  // This is the bug: before 0022 the step unlocked 0 and no proposal was ever offered.
  assert('the room step unlocks the unconfirmed venue and the 半個室', countUnlockedIfRelaxed(db, eventId, roomId), 2)
  const proposalId = proposeRelaxation(db, eventId, nextId, nextTime)
  assert('a room MUST is escapable through a proposal', proposalId !== null, true)
  const negotiation = db.negotiations.find((row) => row.id === proposalId)!
  assert('the proposal targets the room MUST', negotiation.constraint_id, roomId)
  assert('and widens the room type AND accepts an unconfirmed one, in one question', negotiation.proposed_value, {
    room: 'semi_private',
    accept_unknown: true,
  })
  assert('advertising exactly what the step delivers', negotiation.unlocked_count, 2)

  // fn_respond_negotiation with p_accept = true.
  db.constraints.find((row) => row.id === negotiation.constraint_id)!.normalized_value =
    negotiation.proposed_value
  negotiation.status = 'ACCEPTED'
  assert(
    'accepting admits the unconfirmed venue',
    candidateIsFeasible(db, eventId, 'unconfirmed_room'),
    true,
  )
  assert('and the confirmed 半個室', candidateIsFeasible(db, eventId, 'confirmed_semi'), true)
  // The composition rule: consenting to 半個室 must not smuggle in a venue we KNOW is a
  // counter-only 大衆酒場.
  assert(
    'but never a venue known to be the wrong room type',
    candidateIsFeasible(db, eventId, 'known_open'),
    false,
  )
  const accepted = recompute(db, eventId)
  assert('so exactly two venues are feasible', accepted.feasible_count, 2)
  assert('and accessibility coverage is 0 when nobody asked', accepted.accessibility_unverified_count, 0)

  // The ladder terminates: the relaxed value is a fixed point, so the same question is not
  // asked twice.
  assert('a second room step unlocks nothing', countUnlockedIfRelaxed(db, eventId, roomId), 0)
  assert(
    'so no further room proposal is offered',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )

  // An unreadable room preference fails closed (0021 does the same for smoking) and its step
  // unlocks nothing, so nobody is asked a question the engine cannot phrase.
  const malformed = emptyDb()
  const malformedEvent = addEvent(malformed)
  const [m1] = addParticipants(malformed, malformedEvent, 1)
  addConstraint(malformed, malformedEvent, m1, 'MUST', 'room', { room: 'たたみ' })
  addVenue(malformed, 'confirmed_semi', {
    room_type: 'semi_private',
    travel_minutes_by_participant: { [m1]: 20 },
  })
  addVenue(malformed, 'unconfirmed_room', {
    room_type: null,
    travel_minutes_by_participant: { [m1]: 20 },
  })
  assert('an unreadable room preference fails closed', recompute(malformed, malformedEvent).feasible_count, 0)
  assert(
    'and is not proposed, because the step would unlock nothing',
    proposeRelaxation(malformed, malformedEvent, nextId, nextTime),
    null,
  )

  // The demo invariant, one more time and specifically against the new step: the seeded venues
  // all HAVE a room_type, so `accept_unknown` admits none of them and the three unlocked venues
  // are still exactly 001/002/004.
  const demo = fresh()
  recompute(demo)
  const demoProposal = proposeRelaxation(demo, DEMO_EVENT_ID, nextId, nextTime)
  const demoNegotiation = demo.negotiations.find((row) => row.id === demoProposal)!
  assert('the demo still asks Bob about his room MUST', demoNegotiation.participant_id, BOB)
  assert('with the composed step', demoNegotiation.proposed_value, {
    room: 'semi_private',
    accept_unknown: true,
  })
  assert('unlocking exactly three venues', demoNegotiation.unlocked_count, 3)
  demo.constraints.find((row) => row.id === demoNegotiation.constraint_id)!.normalized_value =
    demoNegotiation.proposed_value
  demoNegotiation.status = 'ACCEPTED'
  const demoRun = recompute(demo)
  assert('the 0-then-3 invariant survives the new room step', demoRun.feasible_count, 3)
  assert(
    'and it is still 001, 002 and 004 — never 003',
    demo.scores
      .filter((score) => score.run_id === demoRun.run_id)
      .map((score) => score.restaurant_place_id)
      .sort(),
    ['demo_place_001', 'demo_place_002', 'demo_place_004'],
  )
}

/* 23. 0026: one closed allergen vocabulary, and an allergy zero that explains itself. */
console.log('23. the allergen vocabulary is closed, and its exclusions are legible')
{
  // Asserted against literals, exactly as backend_tests.sql asserts fn_allergen_vocabulary() and
  // fn_dietary_vocabulary(), so the two implementations cannot drift.
  assert('the allergen vocabulary is the six labelled members', [...ALLERGEN_VOCABULARY], [
    'buckwheat',
    'egg',
    'milk',
    'peanut',
    'shellfish',
    'wheat',
  ])
  assert('and the dietary vocabulary is the four patterns', [...DIETARY_VOCABULARY], [
    'gluten_free',
    'halal',
    'vegan',
    'vegetarian',
  ])

  const db = emptyDb()
  const eventId = addEvent(db)
  const [p1] = addParticipants(db, eventId, 1)
  const travel = { [p1]: 20 }
  addConstraint(db, eventId, p1, 'MUST', 'budget', { max_yen: 4000 })
  const allergyId = addConstraint(db, eventId, p1, 'MUST', 'allergy', {
    allergens: ['shellfish', 'egg'],
  })
  addVenue(db, 'confirmed', {
    allergy_safe_tags: ['shellfish_free', 'egg_free'],
    travel_minutes_by_participant: travel,
  })
  addVenue(db, 'partly_confirmed', {
    allergy_safe_tags: ['shellfish_free'],
    travel_minutes_by_participant: travel,
  })
  // What every provider-discovered venue looks like: nobody publishes restaurant allergen data,
  // so the column stays empty forever.
  addVenue(db, 'unverified', { travel_minutes_by_participant: travel })
  // Over budget too, so confirming its kitchen would NOT put it on the shortlist.
  addVenue(db, 'unverified_and_pricey', {
    price_yen_estimate: 9000,
    travel_minutes_by_participant: travel,
  })

  assert(
    'an allergy MUST is met when the recorded _free tags cover every allergen',
    candidateIsFeasible(db, eventId, 'confirmed'),
    true,
  )
  assert(
    'tags covering only part of the allergens stay infeasible',
    candidateIsFeasible(db, eventId, 'partly_confirmed'),
    false,
  )
  assert(
    'and no recorded tags at all stays infeasible — unknown is not safe',
    candidateIsFeasible(db, eventId, 'unverified'),
    false,
  )
  assert('blocking types name allergy alone', candidateBlockingTypes(db, eventId, 'unverified'), [
    'allergy',
  ])
  assert(
    'and name both obstacles when there are two',
    candidateBlockingTypes(db, eventId, 'unverified_and_pricey'),
    ['allergy', 'budget'],
  )

  const run = recompute(db, eventId)
  assert('only the fully confirmed venue is feasible', run.feasible_count, 1)
  // The whole point: 「N件はアレルギー対応が確認できませんでした（お店に確認できます）」 rather than
  // 「0件」. `unverified_and_pricey` is excluded because a phone call cannot fix its price.
  assert('the payload counts the venues only missing allergy proof', run.allergy_unverified_count, 2)
  assert('and 0022 accessibility coverage is untouched', run.accessibility_unverified_count, 0)
  assert('every pre-0026 key is still there', Object.keys(run).sort(), [
    'accessibility_unverified_count',
    'allergy_unverified_count',
    'feasible_count',
    'run_id',
  ])
  assert(
    'an allergy MUST is still never proposed for relaxation',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )

  // THE BUG, exactly as the live model produced it before 0026: the prompt gave allergy no
  // example, so 「えびとかにのアレルギーがあります」 came back as {"allergens":["えび","かに"]}.
  // Feasibility looks for 'えび_free', no venue has it, and allergy is never relaxable.
  db.constraints.find((row) => row.id === allergyId)!.normalized_value = {
    allergens: ['えび', 'かに'],
  }
  const dead = recompute(db, eventId)
  assert('a Japanese allergen can never be matched by any venue', dead.feasible_count, 0)
  assert(
    'and every candidate in budget is reported as allergy-only, never a silent zero',
    dead.allergy_unverified_count,
    3,
  )
  assert(
    'still not negotiable — consent is never asked for an unverified allergen claim',
    proposeRelaxation(db, eventId, nextId, nextTime),
    null,
  )
  // 0026 canonicalises exactly this row on the way in (llm-assist server-side, the parser below,
  // and the one-shot backfill in the migration), which is what makes the venue reachable again.
  db.constraints.find((row) => row.id === allergyId)!.normalized_value = {
    allergens: ['egg', 'shellfish'],
  }
  assert(
    'the canonical form matches the venue again',
    candidateIsFeasible(db, eventId, 'confirmed'),
    true,
  )

  // A MUST the vocabulary cannot express at all ({"allergens":[]}, what 「マンゴーアレルギー」
  // becomes) still gates and still fails closed — but every candidate is now reported as
  // unverified, which for a mango allergy is simply true: no dataset has that flag.
  db.constraints.find((row) => row.id === allergyId)!.normalized_value = { allergens: [] }
  const inexpressible = recompute(db, eventId)
  assert('an inexpressible allergen fails closed', inexpressible.feasible_count, 0)
  assert('and is reported rather than silent', inexpressible.allergy_unverified_count, 3)

  /* The parser: it can only ever emit vocabulary members, and it never drops an allergen. */
  const shellfish = parseConstraintText('えびとかにのアレルギーがあります', 'MUST')
  assert('「えびとかにのアレルギー」 is an allergy MUST', shellfish.normalized_type, 'allergy')
  assert('mapped onto the crustacean member', shellfish.normalized_value, {
    allergens: ['shellfish'],
  })
  assert('and it still requires human confirmation', shellfish.verification_requirement, 'required')
  assert('and defaults to ANONYMOUS', shellfish.suggested_visibility, 'ANONYMOUS')
  const buckwheat = parseConstraintText('そばアレルギーです', 'MUST')
  assert('「そばアレルギー」 is buckwheat, not the soba cuisine', buckwheat.normalized_value, {
    allergens: ['buckwheat'],
  })
  assert('and needs no clarification', buckwheat.needs_clarification, false)
  const eggMilk = parseConstraintText('卵と乳製品がだめです', 'MUST')
  assert('「卵と乳製品がだめです」 is an allergy, not a dietary tag', eggMilk.normalized_type, 'allergy')
  assert('with both ingredients named', eggMilk.normalized_value, { allergens: ['egg', 'milk'] })
  const vegetarian = parseConstraintText('ベジタリアンです', 'MUST')
  assert('「ベジタリアンです」 is still dietary', vegetarian.normalized_type, 'dietary')
  assert('with the canonical tag', vegetarian.normalized_value, { tags: ['vegetarian'] })

  // The case that must never be a silent weakening: an allergen with no member and no venue tag.
  const mango = parseConstraintText('マンゴーアレルギー', 'MUST')
  assert('an inexpressible allergen STAYS a gating allergy MUST', mango.normalized_type, 'allergy')
  assert('with an empty list rather than an unmatchable one', mango.normalized_value, {
    allergens: [],
  })
  assert('the writer’s own words are kept', mango.semantic_remainder, 'マンゴーアレルギー')
  assert('and a human is asked before it is saved', mango.needs_clarification, true)
  assert('while it still demands verification', mango.verification_requirement, 'required')
  // 貝 is molluscs; `shellfish` is the CRUSTACEAN tag. Mapping it would record a weaker
  // requirement than was stated, so it is preserved and asked about instead.
  const mollusc = parseConstraintText('貝アレルギーです', 'MUST')
  assert('貝 is not folded into the crustacean member', mollusc.normalized_value, { allergens: [] })
  assert('it stays an allergy MUST', mollusc.normalized_type, 'allergy')
  assert('and is asked about', mollusc.needs_clarification, true)
  // Partial: what maps gates the search, what does not is kept and asked about.
  const partial = parseConstraintText('えびと貝のアレルギーがあります', 'MUST')
  assert('the expressible half still gates', partial.normalized_value, { allergens: ['shellfish'] })
  assert('the whole wording survives', partial.semantic_remainder, 'えびと貝のアレルギーがあります')
  assert('and the weakening is never silent', partial.needs_clarification, true)
  // No allergy word at all: 「だめ」 must not turn a dietary statement into an empty allergy MUST.
  const stillDietary = parseConstraintText('ベジタリアンなので肉がだめです', 'MUST')
  assert('a dietary statement is not captured by the allergy rule', stillDietary.normalized_type, 'dietary')

  // Whatever the phrasing, the parser can only ever emit vocabulary members.
  const emitted = [
    'えびアレルギーです',
    '海老と蟹がだめです',
    '卵アレルギーがあります',
    '牛乳がだめです',
    '落花生アレルギー',
    '小麦アレルギーです',
    'そばアレルギー',
    'peanut allergy',
    'shellfish allergy please',
  ].flatMap((text) => {
    const parsed = parseConstraintText(text, 'MUST')
    const allergens = parsed.normalized_value.allergens
    return Array.isArray(allergens) ? allergens.map(String) : []
  })
  assert('the parser only ever emits vocabulary members', emitted.length > 0, true)
  assert(
    'and never invents one outside it',
    emitted.filter((allergen) => !(ALLERGEN_VOCABULARY as readonly string[]).includes(allergen)),
    [],
  )

  // The demo invariant, once more against the new count: Emma's shellfish MUST is MET by every
  // seeded venue, so allergy coverage is 0 and the 0-then-3 outcome is untouched.
  const demo = fresh()
  const demoBaseline = recompute(demo)
  assert('the demo is still 0 feasible at baseline', demoBaseline.feasible_count, 0)
  assert('and allergy coverage is 0 when the allergy MUST is met', demoBaseline.allergy_unverified_count, 0)
  const demoProposal = proposeRelaxation(demo, DEMO_EVENT_ID, nextId, nextTime)
  const demoNegotiation = demo.negotiations.find((row) => row.id === demoProposal)!
  assert('the proposal still targets Bob, never Emma', demoNegotiation.participant_id, BOB)
  demo.constraints.find((row) => row.id === demoNegotiation.constraint_id)!.normalized_value =
    demoNegotiation.proposed_value
  demoNegotiation.status = 'ACCEPTED'
  const demoRun = recompute(demo)
  assert('the 0-then-3 invariant survives 0026', demoRun.feasible_count, 3)
  assert(
    'and it is still 001, 002 and 004 — never 003',
    demo.scores
      .filter((score) => score.run_id === demoRun.run_id)
      .map((score) => score.restaurant_place_id)
      .sort(),
    ['demo_place_001', 'demo_place_002', 'demo_place_004'],
  )
}

console.log(`\n${checks - failures}/${checks} checks passed`)
if (failures > 0) {
  console.error(`${failures} check(s) failed`)
  process.exit(1)
}
