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
 */

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
