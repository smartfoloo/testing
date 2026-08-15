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

From `AIKanji/`:

```
supabase start
supabase db reset     # applies the 19 migrations in order, then seed.sql
supabase status -o env
```

`supabase/config.toml` is gitignored-adjacent local config created with `supabase init`,
with these deliberate deviations from the defaults:

- `auth.enable_anonymous_sign_ins = true` — the app calls `signInAnonymously()` in
  `Supa.ensureSession()`, so the stack is unusable without it.
- `studio`, `local_smtp`, `storage`, `analytics` all disabled. The app uses no Storage
  (no buckets in any migration, no client calls) and the rest are conveniences. Disabling
  them removes ~4.7 GB of images and 8 containers, which matters on a small Docker VM.

### Client configuration

`Secrets.xcconfig` (gitignored) overrides the placeholders in `Config.xcconfig` via its
trailing `#include?`, and the values reach `SupabaseConfig` through `Info.plist`.

xcconfig treats `//` as a comment, so a local `http://` URL cannot be written literally —
it silently truncates to `http:`. Carry the slashes in a variable instead:

```
SLASH = /
SUPABASE_URL = http:$(SLASH)$(SLASH)127.0.0.1:54321
```

Verify what actually shipped rather than trusting the xcconfig:

```
plutil -extract SUPABASE_URL raw <DerivedData>/Build/Products/Debug-iphonesimulator/AIKanji.app/Info.plist
```

App Transport Security does **not** need an exception: the app reaches
`http://127.0.0.1:54321` from the simulator as-is, confirmed by a new `auth.users` row
appearing on launch. Do not add an ATS entry for this.

### Edge Function keys

`[edge_runtime.secrets]` in `config.toml` reads the provider keys from the shell, so no
key is ever committed. Export them before starting:

```
LLM_API_KEY=... GOOGLE_PLACES_API_KEY=... HOTPEPPER_API_KEY=... supabase start
```

Confirm they landed: `docker exec supabase_edge_runtime_AIKanji env | grep LLM_API_KEY`.

Without `LLM_API_KEY`, `llm-assist` returns its fail-closed fallback
(`normalized_type: "other"`, `needs_clarification: true`). The app then asks for
clarification instead of offering save, so `test04_submittedConstraintReachesTheGroupFeed`
cannot pass — it needs a real key. The other three UI tests pass without any provider key.

### Domain tests

`AIKanjiDomainTests` skip themselves unless `TEST_RUNNER_SUPABASE_URL`,
`TEST_RUNNER_SUPABASE_ANON_KEY`, `TEST_RUNNER_SUPABASE_SERVICE_ROLE_KEY` and
`TEST_RUNNER_AIKANJI_TEST_PASSWORD` are set, and they additionally need the five
`<persona>@aikanji.demo` Auth users wired to the seeded participant IDs (see
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
