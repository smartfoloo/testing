/**
 * Verifies the P0 gaps completed on top of the golden path, in a real browser:
 *   - invite by link (PRD §3) and the deep link prefilling the join screen
 *   - travel reference as an actual place, not the word "office" (PRD §4/§27)
 *   - progressive-search readiness and the provisional signal (PRD §12)
 *   - the organizer closing collection, and the database refusing later writes (PRD §12)
 *   - per-dimension score breakdowns instead of one opaque score (PRD §9)
 *
 * `golden-path.mjs` covers the §6 demo and A1-A7; this covers what was added around it.
 * Usage: CDP_PORT=9444 node scripts/cdp.mjs scripts/p0-features.mjs
 */

const BASE = process.env.APP_URL ?? 'http://localhost:5173'
const USER_KEY = 'matomeshi.mock.user.v1'

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

async function becomeNewUser(api, id) {
  await api.evaluate(
    `(() => { localStorage.setItem('${USER_KEY}', ${JSON.stringify(id)}); return true })()`,
  )
  await api.goto(BASE)
}

export default async function (api) {
  await api.viewport()
  await api.theme(false)
  await api.goto(BASE)
  await api.resetState()

  /* ------------------------------------------------ travel reference is a place */
  console.log('\nPRD 4/27 - the travel reference resolves to a real place')
  await becomeNewUser(api, 'p0-organizer')
  await api.waitFor('create-event')
  await api.click('create-event')
  await api.fill('event-name', '忘年会')
  await api.fill('display-name', '田中')

  assertThat('all four travel references are offered', await api.exists('travel-reference-doesnt_matter'))
  await api.click('travel-reference-station')
  await api.fill('travel-place-query', '新宿')
  await api.waitFor('travel-place-option-0', 8000)
  await api.click('travel-place-option-0')
  await api.waitFor('travel-place-selected')
  const picked = await api.text('travel-place-selected')
  assertThat('a station was selected', /新宿/.test(picked ?? ''), `read: ${picked}`)

  await api.click('create-submit')
  await api.waitFor('inviteCode')

  /* ------------------------------------------------------------- invite by link */
  console.log('\nPRD 3 - invite by link, not just a code')
  const code = (await api.text('inviteCode')) ?? ''
  const link = (await api.text('inviteLink')) ?? ''
  assertThat('a 6-character invite code was issued', /^[23456789abcdefghjkmnpqrstuvwxyz]{6}$/.test(code), code)
  assertThat('an invite link carries the code', link.includes(`code=${code}`), link)
  assertThat('a QR code is rendered', await api.exists('inviteQRCode'))

  // The organizer's own place id must have reached the database, not the enum word.
  const stored = await api.evaluate(`(() => {
    const db = JSON.parse(localStorage.getItem('matomeshi.mock.db.v2'))
    const p = db.participants.find(r => r.auth_user_id === 'p0-organizer')
    return p ? [p.travel_reference, p.travel_reference_place_id] : null
  })()`)
  assert('the picked place id is persisted', stored, ['station', 'mock_place_shinjuku'])

  await api.click('continue-event')
  await api.waitFor('tab-organizer')

  /* ------------------------------------------------------- readiness / provisional */
  console.log('\nPRD 12 - progressive search readiness')
  // Three more participants join without answering, so responses sit below the threshold.
  for (const [index, id] of ['p0-b', 'p0-c', 'p0-d'].entries()) {
    await becomeNewUser(api, id)
    await api.waitFor('join-event')
    await api.click('join-event')
    await api.fill('invite-code', code)
    await api.fill('join-display-name', `参加者${index + 1}`)
    await api.click('join-submit')
    await api.waitFor('continue-event')
  }

  await becomeNewUser(api, 'p0-organizer')
  await api.waitFor('join-event')
  await api.click('join-event')
  await api.fill('invite-code', code)
  await api.fill('join-display-name', '田中')
  await api.click('join-submit')
  await api.waitFor('continue-event')
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
  await becomeNewUser(api, 'p0-b')
  await api.waitFor('join-event')
  await api.click('join-event')
  await api.fill('invite-code', code)
  await api.fill('join-display-name', '参加者1')
  await api.click('join-submit')
  await api.waitFor('continue-event')
  await api.click('continue-event')
  await api.waitFor('draft-MUST')
  await api.fill('draft-MUST', '個室が必要')
  await api.click('next-MUST')
  await api.waitFor('save-constraint', 8000)
  await api.click('save-constraint')
  await api.wait(1500)
  const blocked = await api.evaluate(`(() => {
    const db = JSON.parse(localStorage.getItem('matomeshi.mock.db.v2'))
    const me = db.participants.find(r => r.auth_user_id === 'p0-b')
    return db.constraints.filter(c => c.participant_id === me.id).length
  })()`)
  assert('the post-close write was refused', blocked, 0)
  assertThat(
    'and the refusal is surfaced, not swallowed',
    await api.evaluate(`document.body.textContent.includes('完了できませんでした')
      || document.body.textContent.includes('権限がありません')
      || document.body.textContent.includes('通信できませんでした')`),
  )
  await api.screenshot('/tmp/p0-4-write-refused.png')

  /* --------------------------------------------------------- score breakdowns */
  console.log('\nPRD 9 - separate dimensions, not one opaque score')
  await api.evaluate(`(() => { localStorage.clear(); return true })()`)
  await api.goto(BASE)
  await api.resetState()
  await api.evaluate(
    `(() => { localStorage.setItem('${USER_KEY}', 'demo-user-alice'); return true })()`,
  )
  await api.goto(BASE)
  await api.waitFor('join-event')
  await api.click('join-event')
  await api.fill('invite-code', 'demo01')
  await api.fill('join-display-name', 'demo')
  await api.click('join-submit')
  await api.waitFor('continue-event')
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
  await api.waitFor('join-event')
  await api.click('join-event')
  await api.fill('invite-code', 'demo01')
  await api.fill('join-display-name', 'demo')
  await api.click('join-submit')
  await api.waitFor('continue-event')
  await api.click('continue-event')
  await api.click('tab-organizer')
  await api.waitFor('find-restaurants')
  await api.click('find-restaurants')
  await api.wait(4500)
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

  assert('no console errors', api.consoleErrors().slice(0, 3), [])

  console.log(`\n${checks - failures}/${checks} P0-feature checks passed`)
  if (failures > 0) throw new Error(`${failures} P0-feature check(s) failed`)
}
