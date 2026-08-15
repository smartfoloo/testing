#!/usr/bin/env node
/**
 * One place to put credentials; both clients generated from it.
 *
 * The two clients need the SAME backend but want it in different, mutually hostile formats:
 *
 *   web    web/.env.local          VITE_SUPABASE_URL=http://127.0.0.1:54321
 *   iOS    AIKanji/Secrets.xcconfig SUPABASE_URL = 127.0.0.1:54321
 *
 * and keeping them in step by hand is how a demo ends up pointed at two different projects.
 * xcconfig is the awkward one: `//` begins a COMMENT there, so writing a URL with its scheme
 * silently truncates `http://127.0.0.1:54321` to `http:`. That is why `Config.xcconfig` asks
 * for a bare host and `SupabaseConfig` prepends `https://` — which works for a hosted project
 * but cannot express a LOCAL http stack. This script emits the xcconfig form that can:
 * `$(SUPABASE_SCHEME)$(SLASHES)host`, built from variables so no literal `//` ever appears.
 *
 * Provider keys are deliberately NOT copied into either client. They belong to the Edge
 * Functions, both clients reach them only by calling those functions, and a Places or LLM key
 * in web/.env.local would be compiled into the browser bundle and shipped to every visitor.
 * This script refuses to write one, rather than trusting everyone to remember.
 *
 * Usage:
 *   node scripts/sync-local-secrets.mjs            # write both client configs
 *   node scripts/sync-local-secrets.mjs --check    # verify they agree, write nothing
 *
 * Source of truth: AIKanji/supabase/.env.local (gitignored). SUPABASE_URL / SUPABASE_ANON_KEY
 * may be omitted, in which case they are read from the running local stack.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE = join(repo, 'AIKanji/supabase/.env.local')
const WEB_ENV = join(repo, 'web/.env.local')
const XCCONFIG = join(repo, 'AIKanji/Secrets.xcconfig')
const checkOnly = process.argv.includes('--check')

/** Keys that must never reach a client: they are the Edge Functions' alone. */
const SERVER_ONLY = [
  'GOOGLE_PLACES_API_KEY',
  'GOOGLE_ROUTES_API_KEY',
  'HOTPEPPER_API_KEY',
  'LLM_API_KEY',
  'LLM_BASE_URL',
  'LLM_MODEL',
  'SUPABASE_SERVICE_ROLE_KEY',
]

function parseEnv(text) {
  const out = {}
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const eq = trimmed.indexOf('=')
    if (eq === -1) continue
    const value = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '')
    if (value) out[trimmed.slice(0, eq).trim()] = value
  }
  return out
}

/** Falls back to the running local stack, so a local setup needs no URL or key written down. */
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

function write(path, contents) {
  if (checkOnly) {
    const current = existsSync(path) ? readFileSync(path, 'utf8') : ''
    const same = current.trim() === contents.trim()
    console.log(`${same ? '  ok   ' : '  STALE'} ${path.replace(`${repo}/`, '')}`)
    return same
  }
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, contents)
  console.log(`  wrote ${path.replace(`${repo}/`, '')}`)
  return true
}

if (!existsSync(SOURCE)) {
  console.error(`missing ${SOURCE.replace(`${repo}/`, '')} — create it and put the keys there.`)
  process.exit(1)
}

const source = parseEnv(readFileSync(SOURCE, 'utf8'))
const fallback = source.SUPABASE_URL && source.SUPABASE_ANON_KEY ? {} : fromLocalStack()
const url = source.SUPABASE_URL ?? fallback.url
const anonKey = source.SUPABASE_ANON_KEY ?? fallback.anonKey

if (!url || !anonKey) {
  console.error(
    'no SUPABASE_URL / SUPABASE_ANON_KEY in AIKanji/supabase/.env.local, and no local stack\n' +
      'is running to read them from. Either start it (cd AIKanji && supabase start) or add the\n' +
      'two values to that file for a hosted project.',
  )
  process.exit(1)
}

// A client key that is actually a service-role key would hand every visitor RLS bypass.
if (/service_role/.test(Buffer.from(anonKey.split('.')[1] ?? '', 'base64').toString('utf8'))) {
  console.error('SUPABASE_ANON_KEY looks like a SERVICE ROLE key. Refusing to write it to a client.')
  process.exit(1)
}

const leaked = SERVER_ONLY.filter((key) => key in source && source[key])
const parsed = new URL(url.startsWith('http') ? url : `https://${url}`)

console.log(`backend: ${parsed.origin}`)
if (leaked.length > 0) {
  console.log(`  (${leaked.length} server-only key(s) present and deliberately not copied)`)
}

const web = `# GENERATED by scripts/sync-local-secrets.mjs — edit AIKanji/supabase/.env.local instead.
# Only these two values may live here: this file is compiled into the browser bundle, so a
# provider key placed here would be shipped to every visitor.
VITE_SUPABASE_URL=${parsed.origin}
VITE_SUPABASE_ANON_KEY=${anonKey}
`

// `//` starts a comment in xcconfig, so the scheme is assembled from variables and the literal
// never appears. SupabaseConfig passes through anything starting with "http".
const hostAndPort = `${parsed.host}${parsed.pathname === '/' ? '' : parsed.pathname}`
const xcconfig = `// GENERATED by scripts/sync-local-secrets.mjs — edit AIKanji/supabase/.env.local instead.
// The scheme is assembled from SLASH because a literal // starts a COMMENT in xcconfig and
// would silently truncate the URL. Note \`SLASHES = //\` does not work either — that line is
// itself a comment, so the variable comes out empty and you get "http:host" with no slashes,
// which URL(string:) still parses, so nothing complains until every request fails. A single
// slash is not a comment, so two of them are concatenated instead. Verified with
// \`xcodebuild -showBuildSettings\`. SupabaseConfig uses the value as-is when it starts "http".
SLASH = /
SUPABASE_SCHEME = ${parsed.protocol}
SUPABASE_URL = $(SUPABASE_SCHEME)$(SLASH)$(SLASH)${hostAndPort}
SUPABASE_ANON_KEY = ${anonKey}
${source.INVITE_LINK_BASE_URL ? `INVITE_LINK_BASE_URL = ${source.INVITE_LINK_BASE_URL}\n` : ''}`

const results = [write(WEB_ENV, web), write(XCCONFIG, xcconfig)]

if (checkOnly && results.includes(false)) {
  console.error('\nclient configs are stale — run without --check to regenerate.')
  process.exit(1)
}
console.log(
  checkOnly
    ? '\nboth clients agree with the source of truth.'
    : '\nboth clients now point at the same backend. Rebuild the iOS app for xcconfig changes;\n' +
        'Vite picks up web/.env.local on its own.',
)
