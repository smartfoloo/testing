/**
 * Verifies the P0 gaps completed on top of the golden path, in a real browser:
 *   - invite by link (PRD §3) and the deep link prefilling the join screen
 *   - travel reference as an actual place, not the word "office" (PRD §4/§27)
 *   - progressive-search readiness and the provisional signal (PRD §12)
 *   - the organizer closing collection, and the database refusing later writes (PRD §12)
 *   - per-dimension score breakdowns instead of one opaque score (PRD §9)
 *
 * `golden-path.mjs` covers the §6 demo and A1-A7; this covers what was added around it.
 *
 * Usage:
 *   CDP_PORT=9444 node scripts/cdp.mjs scripts/p0-features.mjs          # mock backend
 *   AIKANJI_MODE=hosted AIKANJI_TEST_PASSWORD=… SUPABASE_ANON_KEY=… \
 *     SUPABASE_SERVICE_ROLE_KEY=… npm run verify:p0:hosted              # real project
 *
 * ONE scenario, two backends — the same rule `golden-path.mjs` follows, because these 22
 * checks had never once run against a real PostgREST, and that is the exact blind spot that
 * hid 23 migrations' worth of missing table grants (0024). `scripts/personas.mjs` owns the
 * mock/hosted difference; what changes here is only where an assertion READS from:
 *
 *   mock    identities are `matomeshi.mock.user.v1`, and the database is
 *           `matomeshi.mock.db.v2` in localStorage — so "was the write refused?" is a
 *           localStorage read.
 *   hosted  identities are real sessions (a fresh one is an ANONYMOUS sign-in, which is what
 *           the app gives a browser with no session), and the same questions are asked of
 *           PostgREST — with the PARTICIPANT'S OWN token, never the service role, because the
 *           interesting question is what a client can see and do.
 *
 * Two checks depend on something no code change can supply: a real GOOGLE_PLACES_API_KEY, without
 * which `place-search` answers `502 place provider unavailable` and no place can be picked. The
 * suite asks the picker which world it is in rather than assuming: given suggestions it makes the
 * same two assertions as the mock, and given a dead provider it skips them LOUDLY (printed as
 * SKIP, with the reason, and counted in the summary line) while asserting everything that IS
 * reachable — the four reference chips, the failure branch with its retry, どこでも clearing the
 * place, and the skip notice. Configure the key and those two checks start running themselves.
 */

import { actAsPersona, becomeEphemeralUser, currentSession, mode } from './personas.mjs'
import { asUser, hasAnonKey, hasServiceRoleKey, service } from './hosted-db.mjs'

const BASE = process.env.APP_URL ?? 'http://localhost:5173'
const USER_KEY = 'matomeshi.mock.user.v1'
const DEMO_EVENT_ID = '00000000-0000-0000-0000-000000000001'
const BOB = '00000000-0000-0000-0000-0000000000b1'

const hosted = () => mode() === 'hosted'

let checks = 0
let failures = 0
/** Checks that cannot be made in this backend, with the reason. Never silent. */
const skips = []

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

/**
 * A check this backend cannot make. Printed as loudly as a failure, and counted in the
 * summary line, because a silently skipped check is worse than a failing one: it reads as
 * proof it never was.
 */
function skip(label, why) {
  skips.push({ label, why })
  console.log(`  SKIP ${label}\n         ${why}`)
}

/* --------------------------------------------------------------- shared steps */

/** Join an event by code as whoever is signed in, and land on the event home. */
async function joinWithCode(api, code, displayName) {
  await api.waitFor('join-event')
  await api.click('join-event')
  await api.fill('invite-code', code)
  await api.fill('join-display-name', displayName)
  await api.click('join-submit')
  await api.waitFor('continue-event')
}

/**
 * What the place picker settled on: a list of suggestions, a provider that could not be
 * reached, or a provider that answered and knows no such place. Read rather than assumed,
 * because whether `place-search` can work is a property of the environment (its
 * `GOOGLE_PLACES_API_KEY`) and not of the code under test — so the suite reports which world
 * it is in instead of hard-coding one.
 */
async function placePickerOutcome(api, timeoutMs = 12000) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (await api.exists('travel-place-option-0')) return { kind: 'suggestions', status: null }
    const status = await api.text('travel-place-status')
    if (status && !status.includes('探しています')) {
      if (status.includes('検索できませんでした')) return { kind: 'unreachable', status }
      if (status.includes('見つかりませんでした')) return { kind: 'empty', status }
    }
    if (Date.now() >= deadline) return { kind: 'timeout', status }
    await api.wait(250)
  }
}

/**
 * The event id behind an invite code, read as the caller themselves: RLS on `events` only
 * shows it to a participant, so this doubles as proof the join really happened.
 */
async function eventIdFor(api, code) {
  const session = await currentSession(api)
  const rows = await asUser(session.accessToken).select(`events?invite_code=eq.${code}&select=id`)
  if (!rows?.length) throw new Error(`the signed-in participant cannot see event ${code}`)
  return rows[0].id
}

/* ---------------------------------------------------------------------------- */

export default async function (api) {
  if (hosted() && !hasAnonKey()) {
    throw new Error(
      'AIKANJI_MODE=hosted needs SUPABASE_ANON_KEY: the hosted assertions query PostgREST as ' +
        'the participant themselves (their own token + the anon apikey), which is the only ' +
        'way to test what a client can actually see.',
    )
  }

  await api.viewport()
  await api.theme(false)
  await api.goto(BASE)
  await api.resetState()
  console.log(`backend: ${mode()}  (${BASE})`)

  /* ------------------------------------------------ travel reference is a place */
  console.log('\nPRD 4/27 - the travel reference resolves to a real place')
  const organizer = await becomeEphemeralUser(api, 'p0-organizer', BASE)
  await api.waitFor('create-event')
  await api.click('create-event')
  await api.fill('event-name', '忘年会')
  await api.fill('display-name', '田中')

  assertThat('all four travel references are offered', await api.exists('travel-reference-doesnt_matter'))
  await api.click('travel-reference-station')
  await api.fill('travel-place-query', '新宿')

  // Whether a place can be picked at all depends on the environment's Places key, not on the
  // code: `place-search` answers `502 {"error":"place provider unavailable"}` without a real
  // GOOGLE_PLACES_API_KEY. So read which world this is, assert everything that world can
  // prove, and skip the rest loudly — rather than faking a provider response, which would
  // prove the picker works against a fixture nobody ships.
  const picker = hosted() ? await placePickerOutcome(api) : { kind: 'suggestions' }
  let placeWasPicked = false

  if (picker.kind === 'suggestions') {
    await api.waitFor('travel-place-option-0', 8000)
    await api.click('travel-place-option-0')
    await api.waitFor('travel-place-selected')
    const picked = await api.text('travel-place-selected')
    assertThat('a station was selected', /新宿/.test(picked ?? ''), `read: ${picked}`)
    placeWasPicked = true
  } else {
    // The branch that matters most when a provider dies: 「見つかりませんでした」 must never be
    // shown for 「探せませんでした」, because the first sends the participant looking for a
    // different station and the second is not their problem at all.
    assertThat(
      'a dead place provider is reported as a failure, not as "no such place"',
      picker.kind === 'unreachable',
      `picker outcome: ${picker.kind}, status line: ${picker.status}`,
    )
    assertThat('and a retry is offered', await api.exists('travel-place-retry'))

    // どこでも is a real answer that carries no place, and the two notes have to differ.
    await api.click('travel-reference-doesnt_matter')
    const unconstrained = await api.text('travel-place-note')
    assertThat(
      'どこでも clears the place and says the travel condition is waived',
      (unconstrained ?? '').includes('移動の条件は出しません'),
      `note: ${unconstrained}`,
    )
    assert('and the place question disappears with it', await api.exists('travel-place-query'), false)

    await api.click('travel-reference-station')
    const missing = await api.text('travel-place-note')
    assertThat(
      'skipping the place is allowed, but never silent',
      (missing ?? '').includes('場所は未設定'),
      `note: ${missing}`,
    )
    skip(
      'a station was selected',
      `place-search returned no suggestion (${picker.kind}${picker.status ? `: ${picker.status}` : ''}), ` +
        'which needs a real GOOGLE_PLACES_API_KEY in the Edge Function secrets. The picker ' +
        'states that ARE reachable without one are asserted above instead. Set the key and ' +
        'this check runs itself — the suite picks the branch from what the provider does.',
    )
  }

  await api.click('create-submit')
  await api.waitFor('inviteCode')

  /* ------------------------------------------------------------- invite by link */
  console.log('\nPRD 3 - invite by link, not just a code')
  const code = (await api.text('inviteCode')) ?? ''
  const link = (await api.text('inviteLink')) ?? ''
  assertThat('a 6-character invite code was issued', /^[23456789abcdefghjkmnpqrstuvwxyz]{6}$/.test(code), code)
  assertThat('an invite link carries the code', link.includes(`code=${code}`), link)
  assertThat('a QR code is rendered', await api.exists('inviteQRCode'))

  // The organizer's own reference must have reached the database as data, not as the enum
  // word standing in for a location.
  let eventId = null
  if (hosted()) {
    eventId = await eventIdFor(api, code)
    const session = await currentSession(api)
    const rows = await asUser(session.accessToken).select(
      `participants?event_id=eq.${eventId}&select=travel_reference,travel_reference_place_id`,
    )
    const stored = rows.map((row) => [row.travel_reference, row.travel_reference_place_id])
    if (placeWasPicked) {
      // A provider place id is opaque, so the shape is what can be asserted: the category the
      // participant chose, plus a non-empty id that is NOT the enum word standing in for a
      // location (PRD §27's complaint, and the reason this column exists).
      assertThat(
        'the picked place id is persisted',
        stored.length === 1 &&
          stored[0][0] === 'station' &&
          typeof stored[0][1] === 'string' &&
          stored[0][1].length > 0 &&
          stored[0][1] !== 'station',
        JSON.stringify(stored),
      )
    } else {
      // The category is the half that can be proven without a Places key, and it is the half
      // that used to be the whole story. The null is the honest state, asserted rather than
      // glossed over: nobody picked a place, so nothing may claim one.
      assert('the travel reference is persisted (category half)', stored, [['station', null]])
      skip(
        'the picked place id is persisted',
        'no place could be picked without a real GOOGLE_PLACES_API_KEY, so there is no id to ' +
          'find in the row. The null asserted above is the honest state, not a pass.',
      )
    }
  } else {
    const stored = await api.evaluate(`(() => {
      const db = JSON.parse(localStorage.getItem('matomeshi.mock.db.v2'))
      const p = db.participants.find(r => r.auth_user_id === 'p0-organizer')
      return p ? [p.travel_reference, p.travel_reference_place_id] : null
    })()`)
    assert('the picked place id is persisted', stored, ['station', 'mock_place_shinjuku'])
  }

  await api.click('continue-event')
  await api.waitFor('tab-organizer')

  /* ------------------------------------------------------- readiness / provisional */
  console.log('\nPRD 12 - progressive search readiness')
  // Three more participants join without answering, so responses sit below the threshold.
  const identities = [organizer.id]
  for (const [index, id] of ['p0-b', 'p0-c', 'p0-d'].entries()) {
    const joiner = await becomeEphemeralUser(api, id, BASE)
    identities.push(joiner.id)
    await joinWithCode(api, code, `参加者${index + 1}`)
  }
  if (hosted()) {
    // Hosted-only, and load-bearing: a fresh identity here is a fresh ANONYMOUS session, and
    // if clearing storage did NOT yield a new user then fn_join_event's
    // `on conflict (event_id, auth_user_id)` would quietly rename one participant instead of
    // adding three — leaving every count below plausible and wrong.
    assert(
      'each fresh identity is a distinct participant [hosted-only]',
      new Set(identities).size,
      identities.length,
    )
  }

  await becomeEphemeralUser(api, 'p0-organizer', BASE)
  await joinWithCode(api, code, '田中')
  await api.click('continue-event')
  await api.waitFor('tab-organizer')
  await api.click('tab-organizer')
  await api.waitFor('collection-readiness')

  const counts = await api.text('readiness-counts')
  assertThat('readiness counts people against a threshold', /4人中0人|4人中1人/.test(counts ?? ''), `read: ${counts}`)
  assertThat('the threshold is stated', /目安/.test(counts ?? ''), `read: ${counts}`)
  assertThat('searching early is allowed, not blocked', await api.exists('find-restaurants'))
  assertThat('the provisional nature is signalled', await api.exists('provisional-badge'))
  await api.screenshot('/tmp/p0-1-readiness.png')

  /* ------------------------------------------------ closing preference collection */
  console.log('\nPRD 12 - the organizer closes collection and the database enforces it')
  assertThat('a close action is offered', await api.exists('close-preferences'))
  await api.click('close-preferences')
  await api.waitFor('close-preferences-sheet')
  assertThat(
    'the consequences are spelled out before confirming',
    await api.evaluate(`document.body.textContent.includes('条件を追加・変更できなくなります')`),
  )
  await api.screenshot('/tmp/p0-2-close-sheet.png')
  await api.click('close-preferences-confirm')
  await api.waitFor('preferences-closed', 8000)
  assertThat('the closed state shows when it happened', await api.exists('preferences-closed-at'))
  assertThat(
    'explicit recalculation is required, not automatic',
    await api.exists('recompute-required'),
  )
  await api.screenshot('/tmp/p0-3-closed.png')

  // A participant must now be refused by RLS, not silently ignored.
  await becomeEphemeralUser(api, 'p0-b', BASE)
  await joinWithCode(api, code, '参加者1')
  await api.click('continue-event')
  await api.waitFor('draft-MUST')
  await api.fill('draft-MUST', '個室が必要')
  await api.click('next-MUST')
  await api.waitFor('save-constraint', 12000)
  await api.click('save-constraint')
  await api.wait(1500)
  if (hosted()) {
    // Asked as the participant themselves: RLS shows a client only its own constraint rows,
    // so an empty answer here is exactly "my write did not happen" from the client's own
    // point of view. A service-role read would see every row in the event and could not tell
    // the difference between refused and hidden.
    const session = await currentSession(api)
    const mine = await asUser(session.accessToken).select(
      `participant_constraints?event_id=eq.${eventId}&select=id,kind,raw_text`,
    )
    assert('the post-close write was refused', mine.length, 0)
  } else {
    const blocked = await api.evaluate(`(() => {
      const db = JSON.parse(localStorage.getItem('matomeshi.mock.db.v2'))
      const me = db.participants.find(r => r.auth_user_id === 'p0-b')
      return db.constraints.filter(c => c.participant_id === me.id).length
    })()`)
    assert('the post-close write was refused', blocked, 0)
  }
  assertThat(
    'and the refusal is surfaced, not swallowed',
    await api.evaluate(`document.body.textContent.includes('完了できませんでした')
      || document.body.textContent.includes('権限がありません')
      || document.body.textContent.includes('通信できませんでした')`),
  )
  // WHICH of the three it is matters for the report rather than for the check: a refusal that
  // is surfaced as a network problem is still mis-explained, and only a real database can
  // show that.
  const refusal = await api.evaluate(`(() => {
    const wanted = ['完了できませんでした', '権限がありません', '通信できませんでした']
    const hits = [...document.querySelectorAll('p, span')]
      .map((node) => node.textContent.replace(/\\s+/g, ' ').trim())
      .filter((text) => text.length < 200 && wanted.some((w) => text.includes(w)))
    return hits[hits.length - 1] ?? null
  })()`)
  if (refusal) console.log(`       shown to the participant: ${refusal}`)
  await api.screenshot('/tmp/p0-4-write-refused.png')

  /* --------------------------------------------------------- score breakdowns */
  console.log('\nPRD 9 - separate dimensions, not one opaque score')
  if (hosted()) {
    // The demo event, as its organizer. Relaxing Bob's room MUST with the service role is the
    // same shortcut the mock branch below takes by patching its localStorage database — this
    // scenario is about the breakdown UI, and golden-path.mjs proves the consent path that
    // normally causes the relaxation. It is undone at the end of this file.
    if (!hasServiceRoleKey()) {
      throw new Error(
        'the hosted score-breakdown section needs SUPABASE_SERVICE_ROLE_KEY to set up a ' +
          'feasible shortlist (the same way bootstrap-hosted-fixture.mjs resets it).',
      )
    }
    await actAsPersona(api, 'alice', BASE)
    await api.click('tab-organizer')
    await api.waitFor('find-restaurants')
    await api.click('find-restaurants')
    await api.wait(5000)

    await service.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
      normalized_value: { room: 'semi_private' },
    })
    await api.click('find-restaurants')
    await api.wait(5000)
  } else {
    await api.evaluate(`(() => { localStorage.clear(); return true })()`)
    await api.goto(BASE)
    await api.resetState()
    await api.evaluate(
      `(() => { localStorage.setItem('${USER_KEY}', 'demo-user-alice'); return true })()`,
    )
    await api.goto(BASE)
    await joinWithCode(api, 'demo01', 'demo')
    await api.click('continue-event')
    await api.waitFor('tab-organizer')
    await api.click('tab-organizer')
    await api.waitFor('find-restaurants')
    await api.click('find-restaurants')
    await api.wait(4500)

    // Relax Bob's room MUST directly so this scenario stays about the breakdown UI;
    // golden-path.mjs already proves the consent path.
    await api.evaluate(`(() => {
      const key = 'matomeshi.mock.db.v2'
      const db = JSON.parse(localStorage.getItem(key))
      const room = db.constraints.find(c => c.normalized_type === 'room')
      room.normalized_value = { room: 'semi_private' }
      localStorage.setItem(key, JSON.stringify(db))
      return true
    })()`)
    await api.goto(BASE)
    await joinWithCode(api, 'demo01', 'demo')
    await api.click('continue-event')
    await api.click('tab-organizer')
    await api.waitFor('find-restaurants')
    await api.click('find-restaurants')
    await api.wait(4500)
  }

  await api.waitFor('recommendations', 10000)
  await api.click('recommendations')
  await api.waitFor('score-breakdown', 10000)

  assertThat('the event objective emphasis is stated once', await api.exists('score-legend'))
  const dimensions = await api.evaluate(`(() => {
    const names = ['travel_fairness','travel_access','satisfaction','quality','cost_fit','accessibility_fit']
    return names.filter(n => document.querySelector('[data-testid="dimension-' + n + '"]'))
  })()`)
  assert('all six dimensions are shown separately', dimensions.length, 6)

  assertThat(
    'unknown data is marked, not shown as a low score',
    await api.evaluate(`document.body.textContent.includes('未確認')`),
  )
  assertThat('the breakdown can be expanded', await api.exists('score-breakdown-toggle'))
  await api.click('score-breakdown-toggle')
  await api.waitFor('score-breakdown-detail')
  assertThat(
    'the composite is shown as labelled arithmetic of the rows',
    await api.exists('objective-score-total'),
  )
  await api.screenshot('/tmp/p0-5-breakdown.png')
  await api.theme(true)
  await api.screenshot('/tmp/p0-6-breakdown-dark.png')
  await api.theme(false)

  // Two of this scenario's steps deliberately provoke a failed request, and the browser logs
  // both as console errors. They are named here — with the reason they are expected and the
  // assertion that already covered them — so that everything NOT on this list still fails the
  // run. Widening it to "ignore 502s" would have hidden the provider incident this suite is
  // partly here to notice.
  const expectedFailures = hosted()
    ? [
        // Only when the provider actually failed: if a Places key is configured, a 502 from
        // place-search is a real incident and must fail the run like any other.
        ...(placeWasPicked
          ? []
          : [
              {
                match: /place-search/,
                why: 'the unreachable place provider asserted above (no real GOOGLE_PLACES_API_KEY)',
              },
            ]),
        {
          match: /participant_constraints/,
          why: 'the post-close RLS refusal (403) asserted above — the write MUST fail',
        },
      ]
    : []
  const consoleErrors = api.consoleErrors()
  const expected = consoleErrors.filter((line) => expectedFailures.some((e) => e.match.test(line)))
  const unexpected = consoleErrors.filter((line) => !expectedFailures.some((e) => e.match.test(line)))
  for (const entry of expectedFailures) {
    const seen = consoleErrors.filter((line) => entry.match.test(line)).length
    if (seen > 0) console.log(`       expected failure logged ${seen}x: ${entry.why}`)
  }
  assert(
    expected.length > 0 ? 'no console errors beyond the failures this scenario provokes' : 'no console errors',
    unexpected.slice(0, 3),
    [],
  )

  if (hosted()) {
    // Put the demo fixture back: Bob's 個室 is the 0-then-3 premise every other suite rests
    // on. The event this scenario CREATED is left in place deliberately — it is a real event
    // with real participants, and deleting other people's rows is not something a verification
    // run should be able to do.
    await service.patch(`participant_constraints?participant_id=eq.${BOB}&normalized_type=eq.room`, {
      normalized_value: { room: 'private' },
    })
    await service.remove(`recommendation_runs?event_id=eq.${DEMO_EVENT_ID}`)
    console.log(
      '\ndemo fixture restored (Bob back to 個室, runs cleared).' +
        ' Re-run bootstrap-hosted-fixture.mjs before the next golden-path run.',
    )
  }

  const summary =
    `\n${checks - failures}/${checks} P0-feature checks passed` +
    (skips.length > 0
      ? ` (${skips.length} skipped: ${skips.map((s) => s.label).join('; ')})`
      : '')
  console.log(summary)
  if (skips.length > 0) {
    console.log('skipped, and why:')
    for (const s of skips) console.log(`  - ${s.label}: ${s.why}`)
  }
  if (failures > 0) throw new Error(`${failures} P0-feature check(s) failed`)
}
