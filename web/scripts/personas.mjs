/**
 * How a browser scenario becomes one of the five seeded personas — in either backend.
 *
 * The demo fixture (`AIKanji/supabase/seed.sql`) identifies its participants by
 * `auth_user_id`, so "act as Bob" means something different depending on what is behind
 * the app:
 *
 *   mock    — the identity IS a localStorage value (`matomeshi.mock.user.v1`), so swapping
 *             it and reloading is the whole operation. Fast, offline, and what the suites
 *             have always done.
 *   hosted  — the identity is a real Supabase session, so the scenario has to sign in the
 *             way a person would, through the login screen, as
 *             `<persona>@aikanji.demo` with AIKANJI_TEST_PASSWORD.
 *
 * Both paths end in the same place: signed in as that persona, inside the demo event. That
 * matters because it is what lets ONE scenario file prove the golden path against the mock
 * and against a real project, instead of the hosted claim resting on a second, less-tested
 * script.
 *
 * Before the hosted path can work, the project needs
 * `AIKanji/supabase/scripts/bootstrap-hosted-fixture.mjs` run against it: `seed.sql` fills
 * `auth_user_id` with `gen_random_uuid()`, so until those rows point at the real Auth users
 * the seeded event belongs to nobody and every RLS check fails.
 *
 * `becomeEphemeralUser` (bottom of this file) is the same idea for somebody who is NOT a
 * seeded persona — the people `p0-features.mjs` invents to make a four-person event. They have
 * no email, so hosted they cannot be signed in; a fresh identity there is a fresh ANONYMOUS
 * session, which is exactly what the app hands a browser that arrives with no session. One
 * browser holds one session, so each is captured as it is created and put back when it is that
 * identity's turn again.
 */

import { browserSession, restoreSession } from './hosted-db.mjs'

export const DEMO_CODE = 'demo01'
const USER_KEY = 'matomeshi.mock.user.v1'

/** The five seeded personas: their mock identity and their hosted address. */
export const PERSONAS = ['alice', 'bob', 'charlie', 'david', 'emma'].map((name) => ({
  name,
  mockUserId: `demo-user-${name}`,
  email: `${name}@aikanji.demo`,
  /**
   * The name seed.sql gives this participant. It has to be sent back on re-entry:
   * fn_join_event upserts `on conflict (event_id, auth_user_id) do update set
   * display_name = excluded.display_name` (0007), so joining as 'demo' RENAMES the seeded
   * participant — and then A1/A2's 「PUBLIC requirements show a name」 counts four named
   * rows instead of six, because the scenario destroyed the very names it asserts on.
   */
  displayName: `${name[0].toUpperCase()}${name.slice(1)}`,
}))

export function personaByName(name) {
  const persona = PERSONAS.find((candidate) => candidate.name === name)
  if (!persona) throw new Error(`unknown persona: ${name}`)
  return persona
}

/**
 * `hosted` only when explicitly asked for, so a stray environment variable can never turn a
 * local mock run into something that talks to a real project.
 */
export function mode() {
  return process.env.AIKANJI_MODE === 'hosted' ? 'hosted' : 'mock'
}

export function hostedPassword() {
  const password = process.env.AIKANJI_TEST_PASSWORD
  if (!password) {
    throw new Error(
      'AIKANJI_MODE=hosted needs AIKANJI_TEST_PASSWORD (the shared persona password).',
    )
  }
  return password
}

/** Signs in as `persona`, leaving the app on the welcome screen. */
export async function becomePersona(api, persona, base) {
  if (mode() === 'mock') {
    // The mock's identity is the stored value, so this is the sign-in.
    await api.evaluate(
      `(() => { localStorage.setItem('${USER_KEY}', ${JSON.stringify(persona.mockUserId)}); return true })()`,
    )
    await api.goto(base)
    await api.waitFor('join-event')
    return
  }

  // Hosted: a real session, obtained through the real screen.
  //
  // Sign the previous persona OUT rather than clearing storage. Clearing looks tidier and is
  // harmless against a real project, but it also wipes the mock's `matomeshi.mock.db.v2` —
  // so it would destroy a negotiation this scenario just created, and this code path could
  // then never be rehearsed against the mock. Signing out ends the session in both backends
  // and leaves event state alone, which is what makes one scenario file usable for both.
  await api.goto(base)
  await api.waitFor('login')
  if (await api.exists('signed-in-email')) {
    await api.click('login')
    await api.waitFor('login-sheet')
    // The sheet shows the signed-in view, whose only action is logout; it dismisses itself
    // on success, so re-opening below gets the empty form.
    await api.click('logout')
    await api.waitFor('login', 15000)
  }
  await api.click('login')
  await api.waitFor('login-sheet')
  await api.fill('login-email', persona.email)
  await api.fill('login-password', hostedPassword())
  await api.click('login-submit')
  // The sheet closes on success; a failure leaves it open with an InlineErrorView, so the
  // absence of the sheet is the signal that the session actually changed.
  await api.waitFor('signed-in-email', 15000)
  const shown = await api.text('signed-in-email')
  if (!shown || !shown.includes(persona.email)) {
    throw new Error(`hosted sign-in as ${persona.email} failed (screen shows: ${shown})`)
  }
  await api.waitFor('join-event')
}

/**
 * Enters the demo event as whoever is signed in. `fn_join_event` is idempotent, so a seeded
 * participant gets their existing row (and role) back rather than a second one — but it does
 * overwrite `display_name`, so callers pass the persona's seeded name to leave the fixture as
 * it found it.
 */
export async function enterDemoEvent(api, displayName = 'demo') {
  await api.click('join-event')
  await api.fill('invite-code', DEMO_CODE)
  await api.fill('join-display-name', displayName)
  await api.click('join-submit')
  await api.waitFor('continue-event')
  await api.click('continue-event')
  await api.waitFor('tab-requirements')
}

/** Become a persona and end up inside the event, which is what every scenario wants. */
export async function actAsPersona(api, name, base) {
  const persona = personaByName(name)
  await becomePersona(api, persona, base)
  await enterDemoEvent(api, persona.displayName)
}

/* -------------------------------------------------------------------------- */
/* Identities that are nobody in particular                                    */
/* -------------------------------------------------------------------------- */

/**
 * Hosted sessions captured by `becomeEphemeralUser`, keyed by the name the scenario uses.
 * A browser holds ONE session at a time, so acting as four people in turn means putting the
 * right one back — which is all a returning browser does with its persisted session.
 */
const ephemeralSessions = new Map()

/**
 * The p0 suite's `p0-organizer` / `p0-b` / `p0-c` / `p0-d`: people with no seeded fixture and
 * no email, who exist only to be a second, third and fourth participant.
 *
 *   mock    — the identity IS `matomeshi.mock.user.v1`, so writing it is the whole operation.
 *   hosted  — a fresh identity is a fresh ANONYMOUS session, because that is what the app
 *             gives a browser that arrives with no session (`ensureSession()` ->
 *             `signInAnonymously()`). So: clear storage, reload, and let the app sign in;
 *             then capture the session so this identity can be resumed later, since the next
 *             `becomeEphemeralUser` for somebody else will replace it.
 *
 * Returns `{ id, isNew }`. `id` is the mock user id or the anonymous user's uid, which is what
 * lets a caller assert that these really are DIFFERENT participants and not the same session
 * joining four times (`fn_join_event` upserts on (event_id, auth_user_id), so a repeat would
 * silently be one participant renamed — and every readiness count downstream would be wrong
 * in a way that still looks plausible).
 */
export async function becomeEphemeralUser(api, name, base) {
  if (mode() === 'mock') {
    await api.evaluate(
      `(() => { localStorage.setItem('${USER_KEY}', ${JSON.stringify(name)}); return true })()`,
    )
    await api.goto(base)
    return { id: name, isNew: true }
  }

  const saved = ephemeralSessions.get(name)
  if (saved) {
    await restoreSession(api, base, saved)
    const resumed = await waitForSession(api)
    if (!resumed || resumed.userId !== saved.userId) {
      throw new Error(
        `restoring the hosted session for ${name} yielded ${resumed?.userId ?? 'no session'},` +
          ` expected ${saved.userId}`,
      )
    }
    // The refreshed token replaces the stored one; keep the newest so the next resume works.
    ephemeralSessions.set(name, resumed)
    return { id: resumed.userId, isNew: false }
  }

  // Nobody yet: clear everything and let the app introduce itself to the project.
  await api.evaluate(`(() => { localStorage.clear(); return true })()`)
  await api.goto(base)
  const session = await waitForSession(api)
  if (!session) throw new Error(`no session appeared for the new hosted identity ${name}`)
  if (!session.isAnonymous) {
    // A persona session surviving a localStorage.clear() would mean this identity is really
    // somebody else — exactly the confusion that makes a multi-participant test meaningless.
    throw new Error(
      `the fresh identity ${name} is not anonymous (user ${session.userId}); ` +
        'clearing storage did not end the previous session',
    )
  }
  ephemeralSessions.set(name, session)
  return { id: session.userId, isNew: true }
}

/** The app signs in asynchronously on load, so the session appears a moment after the page. */
async function waitForSession(api, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const session = await browserSession(api)
    if (session?.userId) return session
    if (Date.now() >= deadline) return null
    await api.wait(250)
  }
}

/** The session the page is holding now — used to make a query as exactly this participant. */
export function currentSession(api) {
  return browserSession(api)
}
