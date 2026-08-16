/**
 * Realtime delivery — the one thing every other suite tolerates but never proves.
 *
 * `golden-path.mjs` reads group state by re-fetching after each action, so it passes whether
 * or not a single broadcast is ever delivered: the WebSocket could connect, be authorized,
 * and then drop every message, and all 21 checks would still be green. This scenario removes
 * that hole for the two pushes the product actually depends on:
 *
 *   constraint_added  0004's trg_broadcast_constraint -> fn_broadcast_constraint_change ->
 *                     realtime.send(payload, 'constraint_added', 'event-{id}', true), landing
 *                     in an OPEN 「みんなの状況」 feed (GroupFeed.tsx).
 *   run_updated       0006/0009's trg_broadcast_run on recommendation_runs, landing in the
 *                     organizer's 条件を満たすお店 tile (OrganizerDashboard.tsx).
 *   feasibility_stale 0029's statement-level trg_mark_feasibility_stale_*, landing in the same
 *                     tile — but through a recompute the SCREEN decides to make, with nobody
 *                     pressing anything. That is the claim PRD §12 rests on and the one thing no
 *                     suite could previously fail: before 0029 the count only ever moved because
 *                     a human pressed 「条件に合うお店を探す」.
 *
 * The writer is a real other participant, not a privileged shortcut: node signs Charlie, Emma
 * and Bob in with the same password grant the login sheet uses and writes through PostgREST as
 * `authenticated`, so every RLS policy and table grant applies exactly as it would on their own
 * phone. Nothing here is proven by a service-role write that RLS would have refused. (The
 * service role appears only in the cleanup at the end, and psql only for the DELETE that 0024
 * deliberately grants to nobody.)
 *
 * What makes it a delivery test rather than a coincidence:
 *   - the row is asserted ABSENT immediately before it is created, and then has to appear
 *     within a bounded wait;
 *   - `window.fetch` is instrumented, so a pass is rejected if the screen re-read
 *     `fn_get_sanitized_feed` (feed) or `recommendation_runs` (tile) in the meantime — what
 *     appears on screen can only have come off the wire;
 *   - a sentinel on `window` is checked afterwards, so a document reload cannot be mistaken
 *     for a push.
 *
 * And the privacy contract, because a delivery test that ignored it would happily prove that
 * a leak works: 0004 broadcasts a sanitized payload, so a PRIVATE row must not be pushed at
 * all, an ANONYMOUS one must arrive with a null display name, and neither may carry the
 * author's verbatim wording.
 *
 * Hosted only, and deliberately so. "Somebody else's requirement arrives in my open feed"
 * needs a writer that is not this browser; against the mock backend the broadcast is an
 * in-page emitter and the only writer IS this browser, so there is nothing here the mock
 * could fail. Run it as:
 *
 *   set -a; . <(cd AIKanji && supabase status -o env); set +a
 *   SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" \
 *     SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" \
 *     AIKANJI_TEST_PASSWORD=demo-persona-pw-1234 CDP_PORT=9855 \
 *     npm run verify:realtime
 */

import { actAsPersona, hostedPassword, mode, personaByName } from './personas.mjs'
import { asUser, hasAnonKey, personaToken, psql, service } from './hosted-db.mjs'

const BASE = process.env.APP_URL ?? 'http://localhost:5173'

/** seed.sql ids. Stable by design — bootstrap-hosted-fixture.mjs relies on the same ones. */
const DEMO_EVENT_ID = '00000000-0000-0000-0000-000000000001'
const BOB = '00000000-0000-0000-0000-0000000000b1'
const CHARLIE = '00000000-0000-0000-0000-0000000000c1'
const EMMA = '00000000-0000-0000-0000-0000000000e1'

/** Every row this scenario writes carries this, so cleanup can be exact. */
const OWNED = '[realtime-verify]'
/** Per-run, so a leftover row from a crashed run can never produce a false pass. */
const RUN_TAG = `RTV${Date.now().toString(36).toUpperCase()}`

/** How long a push gets before we call it undelivered. */
const DELIVERY_TIMEOUT_MS = 15000
/** How long we watch for a push that must NEVER arrive. */
const SILENCE_MS = 6000
/**
 * A push that has to travel, be debounced (STALE_DEBOUNCE_MS = 1500 in OrganizerDashboard.tsx) and
 * then complete a recompute before the tile can change. Generous on purpose: this is the one
 * assertion whose whole point is that nobody is helping it along.
 */
const AUTO_RECOMPUTE_TIMEOUT_MS = 25000

let checks = 0
let failures = 0

function assert(label, actual, expected) {
  checks += 1
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) console.log(`  ok   ${label}`)
  else {
    failures += 1
    console.log(`  FAIL ${label}\n         expected ${e}\n         actual   ${a}`)
  }
}

function assertThat(label, condition, detail = '') {
  checks += 1
  if (condition) console.log(`  ok   ${label}`)
  else {
    failures += 1
    console.log(`  FAIL ${label}${detail ? `\n         ${detail}` : ''}`)
  }
}

/* ------------------------------------------------------------------ fixtures */

/** A real session for a seeded persona, so node can act as somebody the browser is not. */
async function sessionFor(name) {
  return asUser(await personaToken(personaByName(name).email, hostedPassword()))
}

/**
 * A WANT of type `other`, so creating one cannot change feasibility and this scenario stays
 * independent of the 0-then-3 invariant the golden path asserts. The note is what the feed
 * renders (`constraintSummary`), which is how the row is recognised on screen; the raw text is
 * verbatim human wording, which 0018 says must never leave the database — so it doubles as the
 * canary for that.
 */
function constraintRow({ participantId, visibility, suffix }) {
  return {
    event_id: DEMO_EVENT_ID,
    participant_id: participantId,
    kind: 'WANT',
    raw_text: `${OWNED} ${suffix} 参加者本人の言葉`,
    normalized_type: 'other',
    normalized_value: { note: `${RUN_TAG}-${suffix}` },
    visibility,
  }
}

/**
 * DELETE on participant_constraints is granted to no API role (0024, deliberately: there is no
 * delete policy either), so removing what this scenario created needs direct SQL. Falling back
 * to service-role UPDATE keeps a project without a psql reachable from here usable: PRIVATE
 * rows are excluded from fn_get_sanitized_feed and never broadcast, so the fixture's visible
 * surface is restored either way.
 */
function removeOwnedRows() {
  const deleted = psql(
    `delete from public.participant_constraints where event_id = '${DEMO_EVENT_ID}'` +
      ` and raw_text like '${OWNED}%'`,
  )
  if (deleted.ok) return 'deleted'
  console.log(`  note: psql cleanup unavailable (${deleted.error.split('\n')[0]})`)
  return 'hidden'
}

async function hideOwnedRows() {
  await service.patch(
    `participant_constraints?event_id=eq.${DEMO_EVENT_ID}&raw_text=like.${encodeURIComponent(OWNED)}*`,
    { visibility: 'PRIVATE' },
  )
}

/* --------------------------------------------------------------- page probes */

/**
 * The feed's own cards, minus the DEV-only "last payload received" card, which is an
 * AppCard too and would otherwise be counted as a requirement.
 */
async function readFeed(api) {
  const raw = await api.evaluate(`(() => {
    const cards = [...document.querySelectorAll('.rounded-card.bg-card')]
      .map((card) => card.textContent.replace(/\\s+/g, ' ').trim())
      .filter((text) => text.length > 0 && !text.includes('デバッグ'))
    return JSON.stringify(cards)
  })()`)
  return JSON.parse(raw ?? '[]')
}

/**
 * GroupFeed renders the raw payload it received in DEV, and only ever from the
 * `subscribeConstraints` callback — never from the history load. Its presence is therefore
 * evidence of a message off the wire, and its content is the wire payload itself.
 */
function readWirePayload(api) {
  return api.evaluate(`document.querySelector('pre')?.textContent ?? null`)
}

/**
 * Sentinel + fetch counter. `pattern` is what a REFETCH of the data under test would look
 * like; if the screen changes while this stays at zero, the change came off the socket.
 */
async function instrument(api, pattern) {
  await api.evaluate(`(() => {
    window.__rtSentinel = 'alive'
    window.__rtRefetches = 0
    window.__rtPattern = ${JSON.stringify(pattern)}
    if (!window.__rtPatched) {
      window.__rtPatched = true
      const original = window.fetch.bind(window)
      window.fetch = (...args) => {
        const first = args[0]
        const url = typeof first === 'string' ? first : (first && first.url) || ''
        if (String(url).includes(window.__rtPattern)) window.__rtRefetches += 1
        return original(...args)
      }
    }
    return true
  })()`)
}

async function instrumentation(api) {
  const raw = await api.evaluate(
    `JSON.stringify({ sentinel: window.__rtSentinel ?? null, refetches: window.__rtRefetches ?? null })`,
  )
  return JSON.parse(raw)
}

/**
 * A second, independent tally of outgoing requests, keyed by substring. `instrument` above is left
 * exactly as it was — twenty-four checks rest on what `__rtRefetches` means — so this adds counters
 * beside it rather than generalising it.
 *
 * This is how phase 3 proves a negative that matters: `restaurant-search` is invoked by
 * `findRestaurants`, which is what the 「条件に合うお店を探す」 button and nothing else calls, so a
 * count of zero there is proof the button was not used. And counting the `fn_recompute_feasibility`
 * calls is how "a burst of answers costs ONE recompute" stops being a claim about a timer.
 */
async function countCalls(api, patterns) {
  await api.evaluate(`(() => {
    window.__rtCountPatterns = ${JSON.stringify(patterns)}
    window.__rtCounts = {}
    for (const pattern of window.__rtCountPatterns) window.__rtCounts[pattern] = 0
    if (!window.__rtCountPatched) {
      window.__rtCountPatched = true
      const original = window.fetch.bind(window)
      window.fetch = (...args) => {
        const first = args[0]
        const url = typeof first === 'string' ? first : (first && first.url) || ''
        for (const pattern of window.__rtCountPatterns ?? []) {
          if (String(url).includes(pattern)) window.__rtCounts[pattern] += 1
        }
        return original(...args)
      }
    }
    return true
  })()`)
}

async function calls(api) {
  return JSON.parse(await api.evaluate(`JSON.stringify(window.__rtCounts ?? {})`))
}

/** Runs on the demo event, for the log line that says how many a burst actually produced. */
function runCount() {
  const read = psql(
    `select count(*) from public.recommendation_runs where event_id = '${DEMO_EVENT_ID}'`,
  )
  return read.ok ? Number(read.out) : null
}

async function waitForFeedRow(api, needle, timeoutMs = DELIVERY_TIMEOUT_MS) {
  const started = Date.now()
  const deadline = started + timeoutMs
  let rows = await readFeed(api)
  for (;;) {
    if (rows.some((row) => row.includes(needle))) {
      return { arrived: true, waitedMs: Date.now() - started, rows }
    }
    if (Date.now() >= deadline) return { arrived: false, waitedMs: Date.now() - started, rows }
    await api.wait(250)
    rows = await readFeed(api)
  }
}

async function waitForTile(api, testId, matcher, timeoutMs = DELIVERY_TIMEOUT_MS) {
  const started = Date.now()
  const deadline = started + timeoutMs
  let read = await api.text(testId)
  for (;;) {
    if (matcher(read ?? '')) return { arrived: true, waitedMs: Date.now() - started, read }
    if (Date.now() >= deadline) return { arrived: false, waitedMs: Date.now() - started, read }
    await api.wait(250)
    read = await api.text(testId)
  }
}

/* -------------------------------------------------------------------- phases */

/**
 * constraint_added, into an open feed, written by somebody who is not this browser: David
 * watches while Charlie and Emma save requirements from their own sessions.
 */
async function feedDelivery(api) {
  console.log('\n1. constraint_added reaches an open 「みんなの状況」 feed')
  const charlie = await sessionFor('charlie')
  const emma = await sessionFor('emma')

  await actAsPersona(api, 'david', BASE)
  await api.click('tab-group')
  await api.wait(1500)

  const before = await readFeed(api)
  assert('the feed starts from the ten seeded requirements', before.length, 10)
  assertThat(
    "none of this run's rows is on screen before it exists",
    !before.some((row) => row.includes(RUN_TAG)),
    before.join(' | '),
  )
  await instrument(api, 'fn_get_sanitized_feed')
  assert('no push has been received yet', await readWirePayload(api), null)

  /* -- PRIVATE: must never be pushed at all (0004 returns before realtime.send) -------- */
  await charlie.insert(
    'participant_constraints',
    constraintRow({ participantId: CHARLIE, visibility: 'PRIVATE', suffix: 'private' }),
  )
  await api.wait(SILENCE_MS)
  const afterPrivate = await readFeed(api)
  assertThat(
    `a PRIVATE requirement is never broadcast (silent for ${SILENCE_MS}ms)`,
    !afterPrivate.some((row) => row.includes(`${RUN_TAG}-private`)),
    afterPrivate.join(' | '),
  )
  assert('and the feed is unchanged by it', afterPrivate.length, before.length)
  assert('and nothing at all arrived on the socket', await readWirePayload(api), null)

  /* -- ANONYMOUS: delivered, with the name stripped ------------------------------------ */
  await charlie.insert(
    'participant_constraints',
    constraintRow({ participantId: CHARLIE, visibility: 'ANONYMOUS', suffix: 'anon' }),
  )
  const anon = await waitForFeedRow(api, `${RUN_TAG}-anon`)
  assertThat(
    'an ANONYMOUS requirement arrives in the open feed without a reload',
    anon.arrived,
    anon.arrived ? '' : `still absent after ${anon.waitedMs}ms; rows: ${anon.rows.join(' | ')}`,
  )
  console.log(`       delivered in ${anon.waitedMs}ms`)
  assert('the feed grew by exactly that one row', anon.rows.length, before.length + 1)
  const anonRow = anon.rows.find((row) => row.includes(`${RUN_TAG}-anon`)) ?? ''
  assertThat(
    'the pushed ANONYMOUS row is shown as 匿名の参加者',
    anonRow.includes('匿名の参加者'),
    anonRow,
  )
  assertThat('and does not name its author', !anonRow.includes('Charlie'), anonRow)

  const anonPayload = (await readWirePayload(api)) ?? ''
  assertThat(
    'the ANONYMOUS payload carries a null display name',
    /display_name:\s*null/.test(anonPayload),
    anonPayload,
  )
  assertThat(
    'the ANONYMOUS payload leaks neither the author nor their verbatim wording',
    !anonPayload.includes('Charlie') && !anonPayload.includes('参加者本人の言葉'),
    anonPayload,
  )

  /* -- PUBLIC: delivered, with the name ------------------------------------------------ */
  await emma.insert(
    'participant_constraints',
    constraintRow({ participantId: EMMA, visibility: 'PUBLIC', suffix: 'public' }),
  )
  const pub = await waitForFeedRow(api, `${RUN_TAG}-public`)
  assertThat(
    'a PUBLIC requirement arrives in the open feed without a reload',
    pub.arrived,
    pub.arrived ? '' : `still absent after ${pub.waitedMs}ms; rows: ${pub.rows.join(' | ')}`,
  )
  console.log(`       delivered in ${pub.waitedMs}ms`)
  const pubRow = pub.rows.find((row) => row.includes(`${RUN_TAG}-public`)) ?? ''
  assertThat('the pushed PUBLIC row shows its author', pubRow.includes('Emma'), pubRow)
  const pubPayload = (await readWirePayload(api)) ?? ''
  assertThat(
    'the PUBLIC payload carries the display name and still no raw text',
    /display_name:\s*"Emma"/.test(pubPayload) && !pubPayload.includes('参加者本人の言葉'),
    pubPayload,
  )

  /* -- and it really was a push -------------------------------------------------------- */
  const probe = await instrumentation(api)
  assert('the page was never reloaded during the pushes', probe.sentinel, 'alive')
  assert('the feed was never re-fetched, so this was not a poll', probe.refetches, 0)
  await api.screenshot('/tmp/rt-1-feed-push.png')
}

/**
 * run_updated, into the organizer's live feasible count. Alice sits on her dashboard while Bob
 * — from his own session, with his own token — does exactly what accepting a relaxation does:
 * widens his room MUST and recomputes. No second browser, and no privileged write.
 */
async function runDelivery(api) {
  console.log("\n2. run_updated reaches the organizer's live feasible count")
  const bob = await sessionFor('bob')

  // One run BEFORE the organizer opens her dashboard, so the tile's starting value is a
  // deterministic 0 that it FETCHED (latestRun), rather than whatever runs the project
  // happens to hold. The push under test is then the change away from that value, which is
  // what makes 「a coincidental value on screen」 impossible.
  const existing = psql(
    `select count(*) from public.recommendation_runs where event_id = '${DEMO_EVENT_ID}'`,
  )
  if (existing.ok) console.log(`       runs already on the event: ${existing.out}`)
  const baseline = await bob.rpc('fn_recompute_feasibility', { p_event_id: DEMO_EVENT_ID })
  assert('the seeded fixture is still infeasible, as the demo premise requires', baseline?.feasible_count, 0)

  await actAsPersona(api, 'alice', BASE)
  await api.click('tab-organizer')
  await api.waitFor('feasible-count')
  await api.wait(1500)

  const initial = await api.text('feasible-count')
  console.log(`       tile before the push: ${initial}`)
  // The property the delivery proof rests on is that the number the push will bring is NOT
  // already on screen. 0 is what this fixture produces (and what the tile fetches through
  // latestRun); — is also acceptable, and is what appears if the run above is cleared by
  // something else before the dashboard loads. What must never be true is 3.
  assertThat(
    'the tile does not already show the count the push will bring',
    /^(0|—)/.test(initial ?? ''),
    `tile read: ${initial}`,
  )
  await instrument(api, 'recommendation_runs')

  // Bob widening his own room MUST and recomputing is exactly what fn_respond_negotiation
  // does when he accepts (golden-path.mjs proves the consent path itself); the point here is
  // that Alice's tile learns the new number without asking for it.
  await bob.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
    normalized_value: { room: 'semi_private' },
  })
  const relaxed = await bob.rpc('fn_recompute_feasibility', { p_event_id: DEMO_EVENT_ID })
  assert('and three candidates unlock, as the demo premise requires', relaxed?.feasible_count, 3)
  const three = await waitForTile(api, 'feasible-count', (text) => /^3/.test(text))
  assertThat(
    "a run computed on another device pushes its count onto the organizer's tile",
    three.arrived,
    three.arrived
      ? ''
      : `tile still reads ${three.read} after ${three.waitedMs}ms (run_updated never arrived)`,
  )
  console.log(`       delivered in ${three.waitedMs}ms`)

  const probe = await instrumentation(api)
  assert('the page was never reloaded during the pushes', probe.sentinel, 'alive')
  assert('recommendation_runs was never re-read, so this was not a poll', probe.refetches, 0)
  await api.screenshot('/tmp/rt-2-run-push.png')
}

/**
 * feasibility_stale, into a recompute NOBODY ASKED FOR.
 *
 * This is the check the whole of 0029 exists for, and the one every other suite is structurally
 * unable to make: `golden-path.mjs` and `p0-features.mjs` move the count by clicking
 * 「条件に合うお店を探す」, so they pass on a dashboard that is only ever right when a human
 * remembers to refresh it. Here Alice touches nothing at all. Three of her group answer at once and
 * her count moves; one of them widens a MUST and it moves back.
 *
 * What makes it more than "the number changed":
 *   - `restaurant-search` is invoked only by `findRestaurants`, which is only reachable from the
 *     button, so a count of ZERO there is proof the button was not pressed;
 *   - the `fn_recompute_feasibility` calls are counted, so a burst of THREE writes has to cost
 *     exactly ONE recompute — the debounce coalescing them, not three runs arriving in a row;
 *   - the second beat has to cost exactly one MORE, which is how "the component's own recompute
 *     does not retrigger it" is verified rather than assumed (a recompute writes
 *     recommendation_runs and recommendation_scores, never participant_constraints);
 *   - `recommendation_runs` is never re-read and the page is never reloaded, so the count on screen
 *     came from a recompute this screen chose to make, off the back of a message on the socket;
 *   - one of the three writes is PRIVATE. It moves the organizer's count — a PRIVATE MUST changes
 *     feasibility like any other — while its wording and its author appear nowhere on the screen.
 */
async function staleDelivery(api) {
  console.log('\n3. feasibility_stale drives a recompute nobody asked for')
  const bob = await sessionFor('bob')
  const charlie = await sessionFor('charlie')
  const emma = await sessionFor('emma')

  // Alice is still on the dashboard from phase 2, holding the run that phase 2's push brought.
  // `hasRun` is the first of the screen's three gates: before a search there are no candidates, so
  // an automatic recompute would render a meaningless 0 and this phase would be testing nothing.
  const start = await api.text('feasible-count')
  assertThat(
    'the organizer is holding a real run before any of this, which is what allows an auto-recompute',
    /^3/.test(start ?? ''),
    `tile read: ${start}`,
  )
  await instrument(api, 'recommendation_runs')
  await countCalls(api, ['rpc/fn_recompute_feasibility', 'restaurant-search'])
  const runsBeforeBurst = runCount()

  /* -- three people answer at once ----------------------------------------------------- */
  // Sent together on purpose: this is the five-people-in-the-same-moment case, and the debounce has
  // to close it once. Bob's revert is what moves the number (個室 is unsatisfiable in this fixture);
  // the other two are `other` WANTs, which change no feasibility and are there to prove that the
  // burst is coalesced rather than that three separate things each recomputed.
  const burstStarted = Date.now()
  await Promise.all([
    bob.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
      normalized_value: { room: 'private' },
    }),
    charlie.insert(
      'participant_constraints',
      constraintRow({ participantId: CHARLIE, visibility: 'PRIVATE', suffix: 'stale-private' }),
    ),
    emma.insert(
      'participant_constraints',
      constraintRow({ participantId: EMMA, visibility: 'ANONYMOUS', suffix: 'stale-anon' }),
    ),
  ])

  const dropped = await waitForTile(
    api,
    'feasible-count',
    (text) => /^0/.test(text),
    AUTO_RECOMPUTE_TIMEOUT_MS,
  )
  assertThat(
    "requirements written by other people move the organizer's count with nobody pressing anything",
    dropped.arrived,
    dropped.arrived
      ? ''
      : `tile still reads ${dropped.read} after ${dropped.waitedMs}ms (no auto-recompute happened)`,
  )
  console.log(`       recomputed and rendered ${dropped.waitedMs}ms after the burst`)

  // Settle past one more debounce window, so a second recompute would have to show up in the count.
  await api.wait(3000)
  const afterBurst = await calls(api)
  assert(
    'three answers in one burst cost exactly ONE recompute, not three',
    afterBurst['rpc/fn_recompute_feasibility'],
    1,
  )
  assert(
    'and 「条件に合うお店を探す」 was never used — restaurant-search was not called at all',
    afterBurst['restaurant-search'],
    0,
  )
  const runsAfterBurst = runCount()
  if (runsBeforeBurst !== null && runsAfterBurst !== null) {
    console.log(`       runs on the event: ${runsBeforeBurst} -> ${runsAfterBurst}`)
  }

  const screen = await api.evaluate(`document.body.textContent.replace(/\\s+/g, ' ')`)
  assertThat(
    'the PRIVATE requirement that moved the count is nowhere on the screen it moved',
    !(screen ?? '').includes(`${RUN_TAG}-stale-private`) &&
      !(screen ?? '').includes('参加者本人の言葉') &&
      !(screen ?? '').includes('Charlie'),
    (screen ?? '').slice(0, 240),
  )

  /* -- and the demo's own 0-then-3 beat, unattended --------------------------------------- */
  await bob.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
    normalized_value: { room: 'semi_private' },
  })
  const unlocked = await waitForTile(
    api,
    'feasible-count',
    (text) => /^3/.test(text),
    AUTO_RECOMPUTE_TIMEOUT_MS,
  )
  assertThat(
    'the 0-then-3 beat the whole demo rests on now lands on the dashboard on its own',
    unlocked.arrived,
    unlocked.arrived
      ? ''
      : `tile still reads ${unlocked.read} after ${unlocked.waitedMs}ms`,
  )
  console.log(`       and back up ${unlocked.waitedMs}ms after Bob widened his MUST`)
  await api.wait(3000)
  const afterBeat = await calls(api)
  assert(
    'that is one more recompute and not a loop: a recompute writes no requirement, so it marks nothing stale',
    afterBeat['rpc/fn_recompute_feasibility'],
    2,
  )

  const probe = await instrumentation(api)
  assert('the page was never reloaded during any of it', probe.sentinel, 'alive')
  assert('and recommendation_runs was never re-read, so this was not a poll', probe.refetches, 0)
  await api.screenshot('/tmp/rt-3-stale-recompute.png')
  console.log(`       whole phase took ${Date.now() - burstStarted}ms`)

  /* -- unmount stops it ------------------------------------------------------------------- */
  // Leaving the dashboard has to clear the pending timer, or a recompute would run for a screen
  // that is gone (and would call setState on it). Asserted by unmounting the component the way a
  // person does — EventHome renders one tab at a time — and then making a real change.
  //
  // It is also what makes the cleanup below safe: with nobody watching, restoring the fixture
  // cannot provoke the runs it is about to delete.
  await api.click('tab-requirements')
  await api.wait(500)
  await countCalls(api, ['rpc/fn_recompute_feasibility'])
  await bob.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
    normalized_value: { room: 'private' },
  })
  await api.wait(5000)
  const afterUnmount = await calls(api)
  assert(
    'and once the organizer leaves the dashboard, a change recomputes nothing at all',
    afterUnmount['rpc/fn_recompute_feasibility'],
    0,
  )
}

/* ---------------------------------------------------------------------------- */

export default async function (api) {
  if (mode() !== 'hosted' || !hasAnonKey()) {
    console.log(
      '\nSKIPPED (loudly): realtime delivery is a hosted-only scenario.\n' +
        '  It proves that a broadcast written by SOMEBODY ELSE arrives in this browser.\n' +
        '  Against the mock backend the "broadcast" is an in-page emitter and the only\n' +
        '  possible writer is this same page, so there is nothing the mock could fail —\n' +
        '  a green run would be worth nothing. Run it with AIKANJI_MODE=hosted,\n' +
        '  SUPABASE_ANON_KEY and AIKANJI_TEST_PASSWORD set (see the header of this file).\n' +
        `  mode=${mode()} anon key=${hasAnonKey() ? 'present' : 'missing'}`,
    )
    throw new Error('realtime-delivery requires AIKANJI_MODE=hosted and SUPABASE_ANON_KEY')
  }

  await api.viewport()
  await api.theme(false)
  await api.goto(BASE)
  await api.resetState()
  console.log(`backend: ${mode()}  (${BASE})   run tag: ${RUN_TAG}`)

  // A crashed earlier run could otherwise leave rows that make the feed counts wrong.
  if (removeOwnedRows() === 'hidden') await hideOwnedRows()

  try {
    await feedDelivery(api)
    await runDelivery(api)
    await staleDelivery(api)
  } finally {
    // Leave the fixture as it was found: the extra rows would break golden-path.mjs's
    // 「all ten seeded requirements are visible」, and Bob's MUST is the 0-then-3 premise.
    // (bootstrap-hosted-fixture.mjs resets the runs and Bob, but knows nothing about these
    // rows, so this scenario cleans up after itself.)
    const how = removeOwnedRows()
    if (how === 'hidden') await hideOwnedRows()
    await service.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
      normalized_value: { room: 'private' },
    })
    await service.remove(`recommendation_runs?event_id=eq.${DEMO_EVENT_ID}`)
    console.log(
      `\nfixture restored (rows ${how}, Bob back to 個室, runs cleared).` +
        ' Re-run bootstrap-hosted-fixture.mjs before a golden-path run either way.',
    )
  }

  assert('no console errors during the whole flow', api.consoleErrors().slice(0, 3), [])

  console.log(`\n${checks - failures}/${checks} realtime-delivery checks passed`)
  if (failures > 0) throw new Error(`${failures} realtime-delivery check(s) failed`)
}
