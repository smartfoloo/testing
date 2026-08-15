/**
 * Golden-path demo verification — the PRD's §6 definition of done and acceptance
 * tests A1-A7, driven in a real browser against the deterministic five-persona
 * fixture from AIKanji/supabase/seed.sql.
 *
 * The mock backend identifies the current user by localStorage `matomeshi.mock.user.v1`,
 * and the seeded participants have stable auth ids (`demo-user-alice` ... `demo-user-emma`).
 * Swapping that key and reloading therefore gives six genuinely distinct sessions
 * (organizer + five participants) in one browser, exercising the real authorization-shaped
 * code paths rather than mocked screen transitions.
 *
 * Usage: node scripts/cdp.mjs scripts/golden-path.mjs
 */

const BASE = process.env.APP_URL ?? 'http://localhost:5173'
const USER_KEY = 'matomeshi.mock.user.v1'
const DEMO_CODE = 'demo01'

let checks = 0
let failures = 0

function assert(label, actual, expected) {
  checks += 1
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log(`  ok   ${label}`)
  } else {
    failures += 1
    console.log(`  FAIL ${label}\n         expected ${e}\n         actual   ${a}`)
  }
}

function assertThat(label, condition, detail = '') {
  checks += 1
  if (condition) {
    console.log(`  ok   ${label}`)
  } else {
    failures += 1
    console.log(`  FAIL ${label}${detail ? `\n         ${detail}` : ''}`)
  }
}

/** Become one of the seeded personas and re-enter the demo event. */
async function actAs(api, authUserId) {
  await api.evaluate(
    `(() => { localStorage.setItem('${USER_KEY}', ${JSON.stringify(authUserId)}); return true })()`,
  )
  await api.goto(BASE)
  await api.waitFor('join-event')
  await api.click('join-event')
  await api.fill('invite-code', DEMO_CODE)
  // fn_join_event is idempotent, so a seeded participant gets their existing row back.
  await api.fill('join-display-name', 'demo')
  await api.click('join-submit')
  await api.waitFor('continue-event')
  await api.click('continue-event')
  await api.waitFor('tab-requirements')
}

export default async function (api) {
  await api.viewport()
  await api.theme(false)
  await api.goto(BASE)
  await api.resetState()

  /* ---------------------------------------------------------------- A1 / A2 */
  console.log('\nA1/A2 - five seeded participants and the privacy boundary')
  await actAs(api, 'demo-user-alice')
  await api.click('tab-group')
  await api.wait(1200)

  const feed = await api.evaluate(`(() => {
    const cards = [...document.querySelectorAll('.rounded-card.bg-card')]
    return cards.map(c => c.textContent.replace(/\\s+/g,' ').trim()).filter(Boolean)
  })()`)
  assert('all ten seeded requirements are visible', feed.length, 10)

  const named = feed.filter((row) => /Alice|Bob|David/.test(row)).length
  assertThat('PUBLIC requirements show a name', named >= 6, `named rows: ${named}`)

  const anon = feed.filter((row) => row.includes('匿名の参加者'))
  assert('exactly the two sensitive requirements are anonymous', anon.length, 2)
  assertThat(
    'the anonymous rows are the dietary and allergy MUSTs',
    anon.some((r) => r.includes('食事')) && anon.some((r) => r.includes('アレルギー')),
    anon.join(' | '),
  )
  assertThat(
    'no anonymous row leaks its owner',
    !anon.some((r) => /Charlie|Emma/.test(r)),
    anon.join(' | '),
  )

  /* --------------------------------------------------------------------- A3 */
  console.log('\nA3 - the combined MUSTs are deterministically infeasible')
  assertThat('Alice is the organizer, so the organizer tab exists', await api.exists('tab-organizer'))
  await api.click('tab-organizer')
  await api.waitFor('find-restaurants')
  await api.click('find-restaurants')
  await api.wait(4000)

  const feasible = await api.text('feasible-count')
  assertThat('feasible count is zero', /^0/.test(feasible ?? ''), `tile read: ${feasible}`)
  await api.screenshot('/tmp/gp-1-zero-feasible.png')

  /* --------------------------------------------------------------------- A4 */
  console.log('\nA4 - a minimal relaxation is proposed and cannot self-apply')
  assertThat(
    'the organizer sees an adjustment in progress',
    await api.evaluate(`document.body.textContent.includes('調整中')`),
  )
  assertThat(
    'the organizer is never shown the affected participant',
    await api.evaluate(`!/Bob/.test(document.body.textContent)`),
  )
  assertThat(
    'the organizer cannot consent on the participant behalf',
    !(await api.exists('negotiation-accept')),
  )

  await actAs(api, 'demo-user-charlie')
  await api.wait(6500)
  assertThat(
    'an unaffected participant gets no proposal',
    !(await api.exists('negotiation-accept')),
  )

  await actAs(api, 'demo-user-bob')
  await api.waitFor('negotiation-accept', 15000)
  await api.screenshot('/tmp/gp-2-negotiation.png')
  const impact = await api.evaluate(
    `document.body.textContent.match(/(\\d+)件のお店が候補に加わります/)?.[1] ?? null`,
  )
  assert('the proposal quantifies the unlock', impact, '3')
  assertThat(
    'the proposal is the minimal room relaxation',
    await api.evaluate(`document.body.textContent.includes('半個室')`),
  )
  assertThat('declining is offered, so consent is explicit', await api.exists('negotiation-decline'))

  /* ---------------------------------------------------------------- A5 / A6 */
  console.log('\nA5 - consent changes group state')
  await api.click('negotiation-accept')
  await api.wait(2500)

  await actAs(api, 'demo-user-alice')
  await api.click('tab-organizer')
  await api.waitFor('feasible-count')
  await api.wait(1200)
  const after = await api.text('feasible-count')
  assertThat('feasible count is now three', /^3/.test(after ?? ''), `tile read: ${after}`)
  await api.screenshot('/tmp/gp-3-three-feasible.png')

  console.log('\nA6/A7 - at least three differentiated, explained alternatives')
  await api.waitFor('recommendations')
  await api.click('recommendations')
  await api.wait(3500)

  const cards = await api.evaluate(`(() => {
    const badges = [...document.querySelectorAll('.bg-yellow')].map(b => b.textContent.trim())
    const titles = [...document.querySelectorAll('h3')].map(h => h.textContent.trim())
    return { badges, titles, grounded: /必須条件をすべて満たしています/.test(document.body.textContent) }
  })()`)
  assertThat('three alternatives are shown', cards.titles.length >= 3, JSON.stringify(cards.titles))
  assert('every alternative has a distinct label', new Set(cards.badges).size, cards.badges.length)
  assertThat('explanations are grounded in stored data', cards.grounded)
  await api.screenshot('/tmp/gp-4-recommendations.png')

  /* -------------------------------------------------------- PRD 6 step 11 */
  console.log('\nStep 11 - the human organizer decides')
  assertThat('the organizer can choose', await api.exists('choose-restaurant'))
  await api.click('choose-restaurant')
  await api.wait(2000)
  assertThat(
    'the decision is recorded and shown',
    await api.evaluate(`document.body.textContent.includes('このお店に決まりました')`),
  )
  await api.screenshot('/tmp/gp-5-chosen.png')

  assert('no console errors during the whole flow', api.consoleErrors().slice(0, 3), [])

  console.log(`\n${checks - failures}/${checks} golden-path checks passed`)
  if (failures > 0) throw new Error(`${failures} golden-path check(s) failed`)
}
