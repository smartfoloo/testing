#!/usr/bin/env node
/**
 * Prepares a hosted Supabase project so the five-persona demo fixture is actually usable,
 * and resets it to its starting state so a run is repeatable.
 *
 * AIKanji/README.md documents this as a manual chore: create five Auth users by hand, then
 * hand-edit five `auth_user_id` values because `seed.sql` fills them with
 * `gen_random_uuid()` — random UUIDs belonging to no real user, so every RLS check fails
 * and the seeded event is unreachable until somebody rewires it. Doing that by hand before
 * every demo is exactly how a demo breaks, so this does it.
 *
 * What it does, in order:
 *   1. ensures the five persona Auth users exist (idempotent, email pre-confirmed);
 *   2. points each seeded participant row at the real Auth uid;
 *   3. resets the mutable state the demo mutates — negotiations, recommendation runs,
 *      Bob's room MUST, and the event's decision/lifecycle columns;
 *   4. re-stamps the seeded provider cache so it is inside restaurant-search's TTLs.
 *
 * Step 4 matters more than it looks: the seeded `event_restaurant_candidates` /
 * `travel_matrix_cache` rows are what let the demo run with no provider call and no travel
 * origin, and they go stale after 6h / 24h. Seed in the morning, demo in the afternoon, and
 * discovery becomes "needed" again.
 *
 * Usage:
 *   SUPABASE_URL=https://xxx.supabase.co \
 *   SUPABASE_SERVICE_ROLE_KEY=... \
 *   AIKANJI_TEST_PASSWORD=... \
 *   node AIKanji/supabase/scripts/bootstrap-hosted-fixture.mjs [--dry-run]
 *
 * The service-role key bypasses RLS, which is the only way to rewire another user's rows —
 * so this is a setup tool, never something the app or a test assertion may use. Never commit
 * the key or the password.
 */

const DEMO_EVENT_ID = '00000000-0000-0000-0000-000000000001'

/** Stable participant ids from seed.sql, and the persona each one is. */
const PERSONAS = [
  { name: 'alice', participantId: '00000000-0000-0000-0000-0000000000a1' },
  { name: 'bob', participantId: '00000000-0000-0000-0000-0000000000b1' },
  { name: 'charlie', participantId: '00000000-0000-0000-0000-0000000000c1' },
  { name: 'david', participantId: '00000000-0000-0000-0000-0000000000d1' },
  { name: 'emma', participantId: '00000000-0000-0000-0000-0000000000e1' },
]

const dryRun = process.argv.includes('--dry-run')

function required(key) {
  const value = process.env[key]?.trim()
  if (!value) {
    console.error(`missing environment variable ${key}`)
    process.exit(1)
  }
  return value
}

const baseUrl = (() => {
  // Accept a bare host, matching what SupabaseConfig and the web client already tolerate.
  const raw = required('SUPABASE_URL')
  return raw.startsWith('http') ? raw.replace(/\/$/, '') : `https://${raw.replace(/\/$/, '')}`
})()
const serviceRoleKey = required('SUPABASE_SERVICE_ROLE_KEY')
const password = required('AIKANJI_TEST_PASSWORD')

const headers = {
  apikey: serviceRoleKey,
  Authorization: `Bearer ${serviceRoleKey}`,
  'Content-Type': 'application/json',
}

async function api(method, path, body) {
  const url = `${baseUrl}${path}`
  if (dryRun && method !== 'GET') {
    console.log(`  [dry-run] ${method} ${path}${body ? ` ${JSON.stringify(body)}` : ''}`)
    return null
  }
  const response = await fetch(url, {
    method,
    headers: { ...headers, Prefer: 'return=representation' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) {
    throw new Error(`${method} ${path} -> ${response.status} ${text.slice(0, 400)}`)
  }
  return text.length === 0 ? null : JSON.parse(text)
}

/** How many users one admin-list request asks for. GoTrue's default page size is 50. */
const USERS_PER_PAGE = 200
/** Enough for 200k users; a guard so a misbehaving endpoint cannot spin here forever. */
const MAX_USER_PAGES = 1000

/**
 * The persona's Auth user, or null.
 *
 * `GET /auth/v1/admin/users?email=…` looks like a lookup and is not one: GoTrue's admin list
 * endpoint has no `email` parameter, ignores the ones it does not know, and answers with the
 * FIRST PAGE of all users, newest first. That reads as "already exists" for as long as the
 * project is young enough for the five personas to fit in one page — and stops working the
 * moment it is not. Every anonymous sign-in creates a user (which is what the app does for any
 * browser arriving without a session, and what `verify:p0:hosted` does four times a run), so a
 * local stack crosses 50 users quickly; after that this script would try to CREATE alice, get
 * `422 email_exists`, and abort before rewiring anything — leaving the fixture unreset, so the
 * next hosted run dies at the join on a still-closed event. Exactly the failure the script
 * exists to prevent.
 *
 * `filter` is the parameter GoTrue actually implements (a partial match on email/phone), and
 * paging is behaviour every version has, so try the cheap one and fall back to the certain one.
 */
async function findPersonaUser(email) {
  const filtered = await api(
    'GET',
    `/auth/v1/admin/users?filter=${encodeURIComponent(email)}&per_page=${USERS_PER_PAGE}`,
  )
  const hit = filtered?.users?.find((user) => user.email === email)
  if (hit) return hit

  for (let page = 1; page <= MAX_USER_PAGES; page += 1) {
    const batch = await api('GET', `/auth/v1/admin/users?page=${page}&per_page=${USERS_PER_PAGE}`)
    const users = batch?.users ?? []
    const found = users.find((user) => user.email === email)
    if (found) return found
    if (users.length < USERS_PER_PAGE) return null
  }
  return null
}

/** Idempotent: returns the existing user's id when the address is already registered. */
async function ensurePersonaUser(email) {
  const found = await findPersonaUser(email)
  if (found) return { id: found.id, created: false }

  if (dryRun) {
    console.log(`  [dry-run] would create Auth user ${email}`)
    return { id: '(dry-run)', created: true }
  }
  // email_confirm so the persona can sign in immediately without a mailbox.
  try {
    const created = await api('POST', '/auth/v1/admin/users', {
      email,
      password,
      email_confirm: true,
    })
    return { id: created.id, created: true }
  } catch (error) {
    // The address exists after all — a lookup that could not see it, or a second run started
    // in parallel. Either way "it already exists" is the outcome this function wants, so say
    // so loudly and carry on rather than aborting the reset the caller came for.
    if (!/email_exists|already been registered/i.test(error.message)) throw error
    console.log(`  note: ${email} already exists but was not listed; resolving it directly`)
    const resolved = await findPersonaUser(email)
    if (!resolved) {
      throw new Error(
        `${email} is registered but cannot be found through /auth/v1/admin/users. ` +
          'Delete the account or point this script at the right project.',
      )
    }
    return { id: resolved.id, created: false }
  }
}

async function main() {
  console.log(`project: ${baseUrl}${dryRun ? '  (dry run — no writes)' : ''}`)

  // Refuse to touch anything unless the seeded demo event is present. Without this guard a
  // mistyped project would have its own data reset by the steps below.
  const events = await api(
    'GET',
    `/rest/v1/events?id=eq.${DEMO_EVENT_ID}&select=id,name,status`,
  )
  if (!events || events.length === 0) {
    console.error(
      `\nthe demo event ${DEMO_EVENT_ID} is not in this project.\n` +
        'Apply AIKanji/supabase/migrations/*.sql and then seed.sql first — this script only\n' +
        'wires up and resets an already-seeded fixture, it does not create one.',
    )
    process.exit(1)
  }
  console.log(`found seeded event: ${events[0].name} (status ${events[0].status})\n`)

  console.log('1. persona Auth users')
  const uids = []
  for (const persona of PERSONAS) {
    const email = `${persona.name}@aikanji.demo`
    const { id, created } = await ensurePersonaUser(email)
    console.log(`   ${created ? 'created' : 'exists '}  ${email}  ${id}`)
    uids.push({ ...persona, email, uid: id })
  }

  console.log('\n2. pointing seeded participants at the real Auth uids')
  for (const persona of uids) {
    await api('PATCH', `/rest/v1/participants?id=eq.${persona.participantId}`, {
      auth_user_id: persona.uid,
    })
    console.log(`   ${persona.name.padEnd(8)} participant ${persona.participantId}`)
  }

  console.log('\n3. resetting the mutable demo state')
  // Order matters: recommendation_scores cascade from runs, and a negotiation referencing a
  // constraint must go before the constraint is rewritten.
  await api('DELETE', `/rest/v1/negotiations?event_id=eq.${DEMO_EVENT_ID}`)
  console.log('   negotiations cleared')
  await api('DELETE', `/rest/v1/recommendation_runs?event_id=eq.${DEMO_EVENT_ID}`)
  console.log('   recommendation runs cleared (scores cascade)')

  const bob = uids.find((persona) => persona.name === 'bob')
  await api(
    'PATCH',
    `/rest/v1/participant_constraints?participant_id=eq.${bob.participantId}` +
      '&normalized_type=eq.room',
    { normalized_value: { room: 'private' } },
  )
  console.log("   Bob's room MUST back to private (the 0-then-3 premise)")

  // The organizer's decision and the collection lifecycle are both demo-mutated, and neither
  // is covered by DemoFixture.reset() on the iOS side — a second run would start from
  // 'closed' with a restaurant already chosen.
  await api('PATCH', `/rest/v1/events?id=eq.${DEMO_EVENT_ID}`, {
    status: 'collecting',
    chosen_place_id: null,
    chosen_at: null,
    preferences_closed_at: null,
  })
  console.log('   event back to collecting, decision and close cleared')

  console.log('\n4. re-stamping the seeded provider cache')
  // Freshness is what makes the demo a pure cache hit: no provider call, and no travel
  // origin required, because restaurant-search only demands an origin when discovery must
  // actually run. Stale rows would put it back to needing one.
  const now = new Date().toISOString()
  await api('PATCH', `/rest/v1/event_restaurant_candidates?event_id=eq.${DEMO_EVENT_ID}`, {
    discovered_at: now,
  })
  console.log('   event_restaurant_candidates.discovered_at = now')
  await api('PATCH', `/rest/v1/travel_matrix_cache?event_id=eq.${DEMO_EVENT_ID}`, {
    fetched_at: now,
  })
  console.log('   travel_matrix_cache.fetched_at = now')

  console.log(
    `\ndone.${dryRun ? ' (dry run — nothing was written)' : ''}\n` +
      `Personas sign in with ${PERSONAS.map((p) => `${p.name}@aikanji.demo`).join(', ')}\n` +
      'using AIKANJI_TEST_PASSWORD. Invite code: demo01.',
  )
}

main().catch((error) => {
  console.error(`\nfailed: ${error.message}`)
  process.exit(1)
})
