/**
 * The little bit of database access a hosted browser scenario legitimately needs, and the
 * rules about which key may be used for what.
 *
 * Two very different callers live here, and conflating them is how a verification suite
 * starts proving nothing:
 *
 *   service role — SETUP ONLY. Bypasses RLS, so it is the only way to act as somebody the
 *                  browser is not (create another participant's requirement, relax Bob's
 *                  MUST, reset what a run mutated). Never used to make an assertion about
 *                  what a client can see: a service-role read can see everything, so it
 *                  would pass whether or not the policy under test works.
 *   user token   — ASSERTIONS. The access token the browser itself is holding, so a read
 *                  goes through exactly the RLS the app is subject to. This is what "the
 *                  write was refused" has to be measured with, because the interesting
 *                  question is what the *client* can do, not what postgres can.
 *
 * Keys come from the environment only (`supabase status -o env`), never from a file in the
 * repo, and never from the app's own bundle.
 */

import { execFileSync } from 'node:child_process'

const DEFAULT_URL = 'http://127.0.0.1:54321'
const DEFAULT_DB_URL = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'

export function hostedUrl() {
  const raw = (process.env.SUPABASE_URL ?? process.env.VITE_SUPABASE_URL ?? DEFAULT_URL).trim()
  return raw.replace(/\/$/, '')
}

function envKey(name, fallbackName) {
  return process.env[name]?.trim() || (fallbackName ? (process.env[fallbackName]?.trim() ?? '') : '')
}

function requiredKey(name, fallbackName) {
  const value = envKey(name, fallbackName)
  if (!value) {
    throw new Error(
      `${name} is required for a hosted run.\n` +
        '  set -a; . <(cd AIKanji && supabase status -o env); set +a\n' +
        '  SUPABASE_URL="$API_URL" SUPABASE_ANON_KEY="$ANON_KEY" \\\n' +
        '    SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" ...',
    )
  }
  return value
}

export function serviceRoleKey() {
  return requiredKey('SUPABASE_SERVICE_ROLE_KEY')
}

export function anonKey() {
  return requiredKey('SUPABASE_ANON_KEY', 'VITE_SUPABASE_ANON_KEY')
}

/** Reaching the project as a real client (persona sign-in, RLS-scoped reads and writes). */
export function hasAnonKey() {
  return Boolean(envKey('SUPABASE_ANON_KEY', 'VITE_SUPABASE_ANON_KEY'))
}

/** Reaching it as the trusted server identity, for setup and cleanup only. */
export function hasServiceRoleKey() {
  return Boolean(process.env.SUPABASE_SERVICE_ROLE_KEY?.trim())
}

async function request(path, { method = 'GET', body, apikey, token, prefer } = {}) {
  const response = await fetch(`${hostedUrl()}${path}`, {
    method,
    headers: {
      apikey,
      Authorization: `Bearer ${token ?? apikey}`,
      'Content-Type': 'application/json',
      ...(prefer ? { Prefer: prefer } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) {
    const error = new Error(`${method} ${path} -> ${response.status} ${text.slice(0, 400)}`)
    error.status = response.status
    error.body = text
    throw error
  }
  return text.length === 0 ? null : JSON.parse(text)
}

/**
 * Setup client. Every method is a mutation or a fixture read the scenario is *arranging*,
 * never checking. Keep it that way.
 */
export const service = {
  select: (path) => request(`/rest/v1/${path}`, { apikey: serviceRoleKey() }),
  insert: (table, rows) =>
    request(`/rest/v1/${table}`, {
      method: 'POST',
      body: rows,
      apikey: serviceRoleKey(),
      prefer: 'return=representation',
    }),
  patch: (path, patch) =>
    request(`/rest/v1/${path}`, {
      method: 'PATCH',
      body: patch,
      apikey: serviceRoleKey(),
      prefer: 'return=representation',
    }),
  remove: (path) =>
    request(`/rest/v1/${path}`, { method: 'DELETE', apikey: serviceRoleKey() }),
  rpc: (name, args = {}) =>
    request(`/rest/v1/rpc/${name}`, { method: 'POST', body: args, apikey: serviceRoleKey() }),
}

/**
 * A real session for a seeded persona, obtained the way the login sheet obtains one. This is
 * how a scenario acts as somebody the browser is not WITHOUT bypassing anything: the token
 * carries the `authenticated` role, so every RLS policy and every table grant applies exactly
 * as it would to that person's own phone.
 */
export async function personaToken(email, password) {
  const response = await fetch(`${hostedUrl()}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: anonKey(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`sign-in as ${email} -> ${response.status} ${text}`)
  const token = JSON.parse(text).access_token
  if (!token) throw new Error(`sign-in as ${email} returned no access token`)
  return token
}

/**
 * Direct SQL, for the one thing no API role may do: DELETE on `participant_constraints`.
 * 0024 grants that to nobody on purpose (there is no delete policy either), so a scenario
 * that creates a requirement cannot remove it through the API — and it must remove it, or the
 * next golden-path run counts eleven rows where the fixture defines ten. Cleanup is
 * housekeeping, not an assertion, so a superuser connection is the right tool; adding a
 * DELETE grant to make a test tidy would be widening the schema for the test's convenience.
 */
export function dbUrl() {
  return (process.env.SUPABASE_DB_URL ?? DEFAULT_DB_URL).trim()
}

export function psql(sql) {
  try {
    const out = execFileSync('psql', [dbUrl(), '-v', 'ON_ERROR_STOP=1', '-A', '-t', '-c', sql], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    return { ok: true, out: out.trim() }
  } catch (error) {
    return { ok: false, error: (error.stderr || error.message || String(error)).trim() }
  }
}

/**
 * Assertion client: the browser's own token against the anon apikey, which is precisely the
 * path the app itself uses. A refusal here is the refusal a real client would get.
 */
export function asUser(accessToken) {
  const common = { apikey: anonKey(), token: accessToken }
  return {
    select: (path) => request(`/rest/v1/${path}`, { ...common }),
    insert: (table, rows) =>
      request(`/rest/v1/${table}`, {
        ...common,
        method: 'POST',
        body: rows,
        prefer: 'return=representation',
      }),
    patch: (path, patch) =>
      request(`/rest/v1/${path}`, {
        ...common,
        method: 'PATCH',
        body: patch,
        prefer: 'return=representation',
      }),
    rpc: (name, args = {}) =>
      request(`/rest/v1/rpc/${name}`, { ...common, method: 'POST', body: args }),
  }
}

/**
 * The access token the page is holding right now, read out of the SDK's own storage
 * (`sb-<ref>-auth-token`) — the same value the app puts on every request, so a query made
 * with it is indistinguishable from one the app made.
 */
export async function browserSession(api) {
  const raw = await api.evaluate(`(() => {
    const key = Object.keys(localStorage).find((k) => /^sb-.*-auth-token$/.test(k))
    if (!key) return null
    const stored = localStorage.getItem(key)
    let parsed
    try { parsed = JSON.parse(stored) } catch { return null }
    const token = parsed?.access_token
    if (!token) return null
    let claims = {}
    try { claims = JSON.parse(atob(token.split('.')[1])) } catch { /* opaque token */ }
    return JSON.stringify({
      storageKey: key,
      stored,
      accessToken: token,
      userId: claims.sub ?? null,
      isAnonymous: claims.is_anonymous === true,
      role: claims.role ?? null,
    })
  })()`)
  return raw ? JSON.parse(raw) : null
}

/**
 * Puts a previously captured session back into the page and reloads, which is exactly what
 * a returning browser does with its persisted session. This is what lets one browser hold
 * several hosted identities in turn without a second Chrome: capture each one's session as
 * it is created, restore it when it is that identity's turn again.
 */
export async function restoreSession(api, base, session) {
  await api.evaluate(`(() => {
    localStorage.clear()
    localStorage.setItem(${JSON.stringify(session.storageKey)}, ${JSON.stringify(session.stored)})
    return true
  })()`)
  await api.goto(base)
}
