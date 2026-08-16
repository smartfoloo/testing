#!/usr/bin/env node
/**
 * Generate both client configuration files from the ignored root .env.
 *
 * Only the publishable Supabase URL/anon key reach clients. Provider credentials,
 * the service-role key, and hosted-test credentials remain server/test-only even
 * when they are present in the source file.
 *
 * Usage:
 *   node scripts/sync-local-secrets.mjs
 *   node scripts/sync-local-secrets.mjs --check
 */

import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE = join(repo, '.env')
const WEB_ENV = join(repo, 'web/.env.local')
const XCCONFIG = join(repo, 'AIKanji/Secrets.xcconfig')
const args = new Set(process.argv.slice(2))
const checkOnly = args.delete('--check')

if (args.size > 0) {
  console.error(`unknown option(s): ${[...args].join(', ')}`)
  process.exit(2)
}

/** Keys that must never be emitted into either client configuration. */
const SERVER_ONLY = [
  'SUPABASE_SERVICE_ROLE_KEY',
  'LLM_API_KEY',
  'LLM_BASE_URL',
  'LLM_MODEL',
  'GOOGLE_PLACES_API_KEY',
  'GOOGLE_ROUTES_API_KEY',
  'HOTPEPPER_API_KEY',
  'TABELOG_ENRICHMENT_ENABLED',
  'AIKANJI_TEST_PASSWORD',
  'TEST_RUNNER_SUPABASE_URL',
  'TEST_RUNNER_SUPABASE_ANON_KEY',
  'TEST_RUNNER_SUPABASE_SERVICE_ROLE_KEY',
  'TEST_RUNNER_AIKANJI_TEST_PASSWORD',
]

/** Secret values that must also be rejected if reused under a publishable client name. */
const SENSITIVE_SERVER_ONLY = [
  'SUPABASE_SERVICE_ROLE_KEY',
  'LLM_API_KEY',
  'GOOGLE_PLACES_API_KEY',
  'GOOGLE_ROUTES_API_KEY',
  'HOTPEPPER_API_KEY',
  'AIKANJI_TEST_PASSWORD',
  'TEST_RUNNER_SUPABASE_SERVICE_ROLE_KEY',
  'TEST_RUNNER_AIKANJI_TEST_PASSWORD',
]

function parseEnv(text) {
  const out = {}
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(trimmed)
    if (!match) continue

    let value = match[2].trim()
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1)
    }
    out[match[1]] = value
  }
  return out
}

/** Falls back to the running local stack when both client values are blank. */
function fromLocalStack() {
  try {
    const env = execFileSync('supabase', ['status', '-o', 'env'], {
      cwd: join(repo, 'AIKanji'),
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...process.env, DOCKER_HOST: process.env.DOCKER_HOST ?? dockerHost() },
    })
    const parsed = parseEnv(env)
    return { url: parsed.API_URL, anonKey: parsed.ANON_KEY }
  } catch {
    return {}
  }
}

/** Colima does not create /var/run/docker.sock, which the Supabase CLI assumes. */
function dockerHost() {
  const colima = join(process.env.HOME ?? '', '.colima/default/docker.sock')
  return existsSync(colima) ? `unix://${colima}` : ''
}

function normalizeHTTPURL(value, label) {
  let parsed
  try {
    parsed = new URL(/^https?:\/\//i.test(value) ? value : `https://${value}`)
  } catch {
    throw new Error(`${label} is not a valid HTTP(S) URL`)
  }

  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) {
    throw new Error(`${label} must be an HTTP(S) URL without embedded credentials`)
  }
  return parsed.origin
}

function serviceRoleReason(anonKey, configuredServiceRole) {
  if (configuredServiceRole && anonKey === configuredServiceRole) {
    return 'it matches SUPABASE_SERVICE_ROLE_KEY'
  }
  if (/^sb_secret_/i.test(anonKey)) return 'it uses the server-only sb_secret_ format'

  try {
    const payload = JSON.parse(Buffer.from(anonKey.split('.')[1] ?? '', 'base64url').toString('utf8'))
    if (payload.role === 'service_role') return 'its JWT role is service_role'
  } catch {
    // Modern publishable keys are opaque rather than JWTs.
  }
  return null
}

function xcconfigURL(url) {
  return url.replace('://', ':$(SLASH)$(SLASH)')
}

function assertClientOnly(contents) {
  for (const key of SERVER_ONLY) {
    if (new RegExp(`^${key}\\s*=`, 'm').test(contents)) {
      throw new Error(`internal safety check failed: attempted to emit server-only setting ${key}`)
    }
  }
}

function writeGenerated(path, contents) {
  if (checkOnly) {
    const current = existsSync(path) ? readFileSync(path, 'utf8') : ''
    const same = current.trim() === contents.trim()
    console.log(`${same ? '  ok   ' : '  STALE'} ${path.replace(`${repo}/`, '')}`)
    return same
  }

  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, contents, { mode: 0o600 })
  chmodSync(path, 0o600)
  console.log(`  wrote ${path.replace(`${repo}/`, '')}`)
  return true
}

if (!existsSync(SOURCE)) {
  console.error('missing root .env — copy .env.example to .env and fill the values you need.')
  process.exit(1)
}

const source = parseEnv(readFileSync(SOURCE, 'utf8'))
const hasURL = Boolean(source.SUPABASE_URL)
const hasAnonKey = Boolean(source.SUPABASE_ANON_KEY)

if (hasURL !== hasAnonKey) {
  console.error(
    'SUPABASE_URL and SUPABASE_ANON_KEY must either both be set or both be blank for local-stack discovery.',
  )
  process.exit(1)
}

const fallback = hasURL ? {} : fromLocalStack()
const rawURL = source.SUPABASE_URL || fallback.url
const anonKey = source.SUPABASE_ANON_KEY || fallback.anonKey

if (!rawURL || !anonKey) {
  console.error(
    'no publishable Supabase URL/anon key found in root .env, and no running local stack was discovered.',
  )
  process.exit(1)
}

let supabaseURL
let inviteLinkBaseURL = ''
try {
  supabaseURL = normalizeHTTPURL(rawURL, 'SUPABASE_URL')
  if (source.INVITE_LINK_BASE_URL) {
    inviteLinkBaseURL = normalizeHTTPURL(source.INVITE_LINK_BASE_URL, 'INVITE_LINK_BASE_URL')
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : 'invalid client URL configuration')
  process.exit(1)
}

if (!/^[A-Za-z0-9._-]+$/.test(anonKey)) {
  console.error('SUPABASE_ANON_KEY has an invalid format; refusing to write client files.')
  process.exit(1)
}

const roleReason = serviceRoleReason(anonKey, source.SUPABASE_SERVICE_ROLE_KEY)
if (roleReason) {
  console.error(`SUPABASE_ANON_KEY is not publishable (${roleReason}); refusing to write client files.`)
  process.exit(1)
}

const selectedClientValues = new Set([
  source.SUPABASE_URL,
  source.SUPABASE_ANON_KEY,
  source.INVITE_LINK_BASE_URL,
])
const serverOnlyCollision = SENSITIVE_SERVER_ONLY.find(
  (key) => source[key] && selectedClientValues.has(source[key]),
)
if (serverOnlyCollision) {
  console.error(
    `${serverOnlyCollision} matches a publishable client setting; refusing to write client files.`,
  )
  process.exit(1)
}

const configuredServerOnly = SERVER_ONLY.filter((key) => {
  const value = source[key]
  return value && !/^\$\{[A-Z][A-Z0-9_]*\}$/.test(value)
})
if (configuredServerOnly.length > 0) {
  console.log(
    `  omitted ${configuredServerOnly.length} configured server/test-only setting(s) from client outputs`,
  )
}

const web = `# GENERATED by scripts/sync-local-secrets.mjs from the root .env — do not edit.
# This Vite file contains publishable client configuration only.
VITE_SUPABASE_URL=${supabaseURL}
VITE_SUPABASE_ANON_KEY=${anonKey}
`

// xcconfig treats a literal double slash as a comment, so URL slashes are assembled at build time.
const xcconfig = `// GENERATED by scripts/sync-local-secrets.mjs from the root .env — do not edit.
// This file contains publishable client configuration only.
SLASH = /
SUPABASE_URL = ${xcconfigURL(supabaseURL)}
SUPABASE_ANON_KEY = ${anonKey}
INVITE_LINK_BASE_URL = ${inviteLinkBaseURL ? xcconfigURL(inviteLinkBaseURL) : ''}
`

try {
  assertClientOnly(web)
  assertClientOnly(xcconfig)
} catch (error) {
  console.error(error instanceof Error ? error.message : 'client-output safety check failed')
  process.exit(1)
}

const results = [writeGenerated(WEB_ENV, web), writeGenerated(XCCONFIG, xcconfig)]

if (checkOnly && results.includes(false)) {
  console.error('\nclient configs are stale — run the sync script without --check to regenerate them.')
  process.exit(1)
}

console.log(
  checkOnly
    ? '\nclient configs match the root .env.'
    : '\nclient configs generated. Rebuild iOS for xcconfig changes; Vite reads web/.env.local automatically.',
)
