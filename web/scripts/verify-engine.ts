/**
 * Asserts the TypeScript engine port reproduces the Postgres engine's behaviour on the
 * seed.sql fixture. The assertions mirror
 * AIKanji/Tests/AIKanjiDomainTests/FeasibilityEngineTests.swift tests 1–4, and were also
 * confirmed against a real postgres:16 container running the actual migrations.
 *
 * Run with `npm run verify:engine`.
 */

import {
  candidateIsFeasible,
  countUnlockedIfRelaxed,
  proposeRelaxation,
  recomputeFeasibility,
  type ConstraintRow,
  type Db,
} from '../src/backend/engine'
import { createSeedDb, parseConstraintText } from '../src/backend/mock'

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

console.log(`\n${checks - failures}/${checks} checks passed`)
if (failures > 0) {
  console.error(`${failures} check(s) failed`)
  process.exit(1)
}
