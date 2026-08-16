# Local development notes

Verified on macOS 26.6 (Apple Silicon), Xcode 26.6, Supabase CLI 2.114.0.

## iOS toolchain

Xcode 26.6 with the iOS 26.5 SDK. Since Xcode 16 the app bundle is slim (~3.5 GB) and
platform SDKs are separate downloads, so a fresh machine needs:

```
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
```

Build and test from `AIKanji/`:

```
xcodebuild -project AIKanji.xcodeproj -scheme AIKanji \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild test -project AIKanji.xcodeproj -scheme AIKanji \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:AIKanjiUITests
```

`test04_submittedConstraintReachesTheGroupFeed` needs a real `LLM_API_KEY`; without one
`llm-assist` returns its `needs_clarification` fallback and the parse-confirmation sheet
never offers `save-constraint`. The other three pass with no provider key at all.

Pass `-parallel-testing-enabled NO` and target a device by **UDID** if you care which
simulator runs: `xcodebuild test` clones simulators otherwise, and `xcrun simctl io booted`
is ambiguous the moment two are booted — it will happily screenshot the wrong one.

**A short screen used to break these tests, and it was the app's fault, not the tests'.**
On iPhone 17 Pro (402x874) `create-submit` sat at y=862.7 with height 62, so its tap centre
was below the screen, and the keyboard covered everything past y=539. Every test that
created an event failed with "no invite code after creating the event" and made no network
request, which looks exactly like a backend fault. `CreateEventView` now pins the action in
the keyboard's accessory band while a keyboard is up and in a bottom bar when it is not, so
the whole suite passes on iPhone 17 Pro. If you reintroduce an inline bottom button, note
the constraint that forced this: with the keyboard up there are only 75.7 points between
the 「あなたの名前」 field's centre and the top of the keyboard, and the button is 62 —
a pinned bar lands on that field and swallows its taps. CI only compiles
(`generic/platform=iOS Simulator`) and never runs these tests, so it cannot catch either
failure.

## Running against a local Supabase (no hosted credentials needed)

The hosted project is not required for development. `supabase start` gives a full local
stack whose anon key is the public `supabase-demo` JWT.

From the repository root, create and load the sole hand-maintained local environment, then start
the stack and generate both client configurations:

```
cp .env.example .env
set -a
. ./.env
set +a
cd AIKanji
supabase start
supabase db reset     # applies all migrations in order, then seed.sql
cd ..
node scripts/sync-local-secrets.mjs
node scripts/sync-local-secrets.mjs --check
```

Leave `SUPABASE_URL` and `SUPABASE_ANON_KEY` blank in root `.env` to let the sync script discover
the running local stack.

`supabase/config.toml` is gitignored-adjacent local config created with `supabase init`,
with these deliberate deviations from the defaults:

- `auth.enable_anonymous_sign_ins = true` — the app calls `signInAnonymously()` in
  `Supa.ensureSession()`, so the stack is unusable without it.
- `studio`, `local_smtp`, `storage`, `analytics` all disabled. The app uses no Storage
  (no buckets in any migration, no client calls) and the rest are conveniences. Disabling
  them removes ~4.7 GB of images and 8 containers, which matters on a small Docker VM.

### Client configuration

Root `.env` is the only hand-maintained local source. `scripts/sync-local-secrets.mjs` writes
only `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `INVITE_LINK_BASE_URL` to the gitignored
`Secrets.xcconfig`, which overrides the placeholders in `Config.xcconfig` via its trailing
`#include?`. The same run writes only `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` to the
gitignored `web/.env.local`.

xcconfig treats `//` as a comment, so the generator carries URL slashes through a `SLASH = /`
variable instead of writing a literal `http://`. Never hand-edit either generated file.
Supabase anon keys are publishable; service-role, provider, and test credentials are not and must
never enter `Secrets.xcconfig` or a `VITE_*` value.

Verify what actually shipped rather than trusting the xcconfig:

```
plutil -extract SUPABASE_URL raw <DerivedData>/Build/Products/Debug-iphonesimulator/AIKanji.app/Info.plist
```

App Transport Security does **not** need an exception: the app reaches
`http://127.0.0.1:54321` from the simulator as-is, confirmed by a new `auth.users` row
appearing on launch. Do not add an ATS entry for this.

### Edge Function keys

`[edge_runtime.secrets]` in `config.toml` reads provider settings from the shell. Load the
ignored root `.env` with `set -a; . ./.env; set +a` before `supabase start`; do not maintain a
second env file under `AIKanji/supabase`. For hosted functions, register each configured provider
variable from that environment with `supabase secrets set NAME="$NAME"`; Supabase keeps those
values in its encrypted secret store. Do not set provider or service-role values in either client.

Confirm presence without printing a value:

```
docker exec supabase_edge_runtime_AIKanji sh -c 'test -n "$LLM_API_KEY" && echo "LLM_API_KEY is set"'
```

Without `LLM_API_KEY`, `llm-assist` returns its fail-closed fallback
(`normalized_type: "other"`, `needs_clarification: true`). The app then asks for
clarification instead of offering save, so `test04_submittedConstraintReachesTheGroupFeed`
cannot pass — it needs a real key. The other three UI tests pass without any provider key.

### Domain tests

`AIKanjiDomainTests` skip themselves unless `TEST_RUNNER_SUPABASE_URL`,
`TEST_RUNNER_SUPABASE_ANON_KEY`, `TEST_RUNNER_SUPABASE_SERVICE_ROLE_KEY` and
`TEST_RUNNER_AIKANJI_TEST_PASSWORD` are set. Root `.env.example` maps those names to the generic
values; shell-source the copied root `.env` before `xcodebuild` so the references expand. The tests
also need the five `<persona>@aikanji.demo` Auth users wired to the seeded participant IDs (see
`AIKanji/README.md`). A bare local stack has none of these, so they skip.

## Docker (Colima)

This machine runs Colima, not Docker Desktop. Two failure modes hit during setup:

- **`initdb: No space left on device`** — `/var/lib/docker` is a fixed 16 GiB volume
  (`disk: 16` in `~/.colima/default/colima.yaml`), and the Supabase images nearly fill it.
  Check with `colima ssh -- df -h /var/lib/docker`. Trimming the unused services above was
  enough; `colima stop && colima start --disk N` grows it if needed.
- **Published ports stop forwarding to the host.** New containers become unreachable at
  `127.0.0.1:<port>` while containers started earlier keep working, so `supabase start`
  fails with `ECONNREFUSED 127.0.0.1:54322`. A `colima stop && colima start` fixes it.
  Test with `docker run -d -p 55997:5000 registry:2` then `curl 127.0.0.1:55997/v2/`.
