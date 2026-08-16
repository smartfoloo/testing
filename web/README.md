# まとメシ (matomeshi-web)

Web/PWA port of the **AIKanji** iOS app in `../AIKanji`, taken from
`design/japanese-matomeshi-ui` at commit `68e67bb`.

Same product, same Japanese copy, same design system, same backend contract — it talks to
the identical Supabase RPCs, Edge Functions and realtime topics as the SwiftUI client.

## Running it

```bash
cd web
npm install
npm run dev
```

With no configuration it boots on an **in-browser mock backend** seeded from
`AIKanji/supabase/seed.sql`, so the whole flow is usable offline. Invite code `demo01` joins the
five-person demo event.

To point it at a real project, use the repository-root environment as the only hand-maintained
local source:

```bash
# Run from the repository root.
cp .env.example .env
# Fill the root .env, then generate both Web and iOS client configuration.
node scripts/sync-local-secrets.mjs
node scripts/sync-local-secrets.mjs --check
cd web
```

The script creates gitignored `web/.env.local`; do not copy or edit `web/.env.example` as a
second source. The Supabase anon key is publishable client configuration. Service-role, provider,
and hosted-test credentials are server/test-only and must never use a `VITE_*` name or enter a
browser bundle. The same setup `AIKanji/README.md` describes is required: apply the migrations,
enable anonymous sign-ins, disable public Realtime access, register provider settings in
Supabase's encrypted Edge Function secret store, and deploy the functions.

## Scripts

| Command | What it does |
| --- | --- |
| `npm run dev` | Vite dev server |
| `npm run build` | Typecheck, bundle, generate the service worker |
| `npm run preview` | Serve the production build (needed to exercise the PWA) |
| `npm run lint` | oxlint |
| `npm run typecheck` | `tsc -b --noEmit` |
| `npm run verify:engine` | Asserts the ported feasibility engine against the seed fixture |
| `npm run verify:golden` | The §6 golden path + A1–A7, in a real browser (needs `npm run dev`) |
| `npm run verify:p0` | The P0 features added around the golden path |
| `npm run verify:hosted` | The same golden path against a real Supabase project — see below |
| `npm run verify:p0:hosted` | The same P0 features against a real project — see below |
| `npm run verify:realtime` | That a broadcast actually **arrives** (hosted only) — see below |
| `npm run icons` | Regenerates the PWA icon set from the design tokens |

## Verifying against a real Supabase project

Every suite above except the three hosted ones runs against the in-browser mock. That is genuinely
useful — the mock is a faithful port of the SQL engine, and `verify:engine` asserts the two
agree — but it cannot prove the hosted path, and three classes of bug found in this codebase
were invisible to it: an invite code the join screen could never match, a cast that raised in
Postgres but not in TypeScript, and two realtime channels sharing one topic. PRD §34 asks for
A1–A10 against the deployed environment for exactly this reason.

`verify:hosted` runs **the same scenario file** as `verify:golden`; only the way a session is
obtained differs, and `scripts/personas.mjs` owns that difference. Against the mock a persona
is a localStorage value; against a real project it is a Supabase session obtained through the
login screen, as `<persona>@aikanji.demo`. One definition of the golden path, two backends.

Order matters, because each step is a precondition for the next:

1. **Apply all migrations and the seed** to the project (through `0028`, then `seed.sql`).
   `postgis` and `vector` must be available.
2. **Authentication → Providers → enable Anonymous sign-ins**, and in Realtime settings
   **disable "Allow public access"** so the `event-{id}` topics stay private (`0004`'s policy
   on `realtime.messages` is what authorizes a join).
3. **Load the ignored root `.env`, register configured provider values in Supabase's encrypted
   secret store, and deploy all three Edge Functions.** The relevant server-only settings include
   `GOOGLE_PLACES_API_KEY`, `GOOGLE_ROUTES_API_KEY`, `HOTPEPPER_API_KEY`, and `LLM_API_KEY`;
   optional model/base URL and Tabelog settings stay server-side too. For each configured value,
   run `supabase secrets set NAME="$NAME"` from `AIKanji/`, then deploy. Never copy these values to
   `web/.env.local`.
4. **Bootstrap the fixture.** `seed.sql` fills `auth_user_id` with `gen_random_uuid()`, so
   until this runs the seeded event belongs to nobody and every RLS check fails:
   ```bash
   set -a
   . ../.env
   set +a
   node ../AIKanji/supabase/scripts/bootstrap-hosted-fixture.mjs --dry-run
   ```
   Drop `--dry-run` once the plan looks right. It is idempotent, so it is also how you reset
   between runs — it clears the negotiations, runs, decision and lifecycle columns the demo
   mutates, and re-stamps the seeded provider cache so it stays inside `restaurant-search`'s
   TTLs (6h for discovery, 24h for travel). A demo seeded in the morning and run in the
   afternoon would otherwise need a provider call it cannot make.
5. **Generate the client configuration** from root `.env` with
   `node ../scripts/sync-local-secrets.mjs`, then run the app (`npm run dev`, or
   `npm run build && npm run preview`). Do not maintain `.env.local` directly.
6. **Run it** after shell-sourcing root `.env` as shown above:
   ```bash
   APP_URL=http://localhost:5173 npm run verify:hosted
   ```

Two things will waste your time if nobody says them:

- **Re-run the bootstrap before every hosted run.** The golden path ends by *choosing* a
  restaurant, which closes the event — and `fn_join_event` refuses a closed one, so the next
  run dies at the join with `400`. The bootstrap resets that (and Bob's MUST, and the cache
  stamps), which is why it is the reset tool as well as the setup tool.
- **Wait for Realtime after `supabase db reset`.** The reset restarts the containers, and a
  run started against a cold `supabase_realtime` logs
  `WebSocket … failed: Unexpected response code: 502` and fails the "no console errors"
  check while every other assertion passes. Poll
  `docker inspect --format '{{.State.Health.Status}}' supabase_realtime_<project>` until it
  reads `healthy` first. (With Colima, export
  `DOCKER_HOST=unix://$HOME/.colima/default/docker.sock` — the Supabase CLI looks for
  `/var/run/docker.sock`, which Colima does not create, and fails with a bare
  `failed to inspect container health`.)
- **A freshly joined client can receive a broadcast that predates its join.** Observed against
  the local stack: with `recommendation_runs` empty for the demo event, the organizer's
  「条件を満たすお店」 tile rendered `0` seconds after subscribing, from a `run_updated` whose
  `realtime.messages` row had been written 21 s earlier by a different suite. Nothing had been
  re-fetched — the number came off the socket. So an assertion about a count must not assume the
  tile shows only what happened *after* the subscription: assert a value that could only exist
  after the action under test (`verify:realtime` does this by taking a deterministic run first),
  and treat a stale count on `verify:hosted` as a possible cause if 「feasible count is zero」
  fails while everything around it passes.

The hosted *mechanism* can be rehearsed without a project at all, which is how it was
developed: the mock's `signIn` accepts the same `<persona>@aikanji.demo` addresses, so
`AIKANJI_MODE=hosted AIKANJI_TEST_PASSWORD=anything npm run verify:hosted` against the mock
drives the real login sheet six times and still asserts all 21 checks. That proves the harness
— sign-in, sign-out between personas, and the event re-entry — leaving only Supabase's own
behaviour (RLS, Realtime authorization, the Edge Functions) as the part a real project
actually tests. Worth running after any change to `scripts/personas.mjs`.

The service-role key appears in step 4 only. It bypasses RLS, which is the only way to rewire
another user's rows, so it is a setup tool and must never reach the app or an assertion.

### The other two hosted suites

Both need the same bootstrapped fixture as `verify:hosted`, plus two more values in the
environment, because they talk to the project from node as well as through the browser:

```bash
set -a
. ../.env                 # hosted project; the ignored root file is the only manual source
set +a
npm run verify:realtime
```

For a local stack, values reported by `supabase status -o env` can be exported for that process;
they are generated stack output, not a second hand-maintained env file.

- **`verify:realtime`** (`scripts/realtime-delivery.mjs`) is the only suite that proves a
  broadcast is **delivered**. Every other suite re-fetches after each action, so Realtime
  could connect, be authorized, and then drop every message with all 21 + 22 checks still
  green. It asserts a row is absent, has a real other participant create it (a persona
  password grant + PostgREST as `authenticated` — no service-role write, so RLS applies as it
  would on that person's phone), and requires it to appear in the open feed within a bounded
  wait. `window.fetch` is instrumented and a sentinel is left on `window`, so a pass is
  rejected if the screen re-read `fn_get_sanitized_feed` / `recommendation_runs` or the
  document reloaded — the value on screen can only have come off the socket. It also asserts
  0004's privacy contract: a `PRIVATE` row is never pushed, an `ANONYMOUS` one arrives with a
  null display name, and no payload carries the author's verbatim `raw_text`.

  Hosted only, on purpose: against the mock the "broadcast" is an in-page emitter and the only
  possible writer is the page itself, so there would be nothing to fail. Run in mock mode it
  says so and exits non-zero rather than passing vacuously.

- **`verify:p0:hosted`** runs the same `scripts/p0-features.mjs` as `verify:p0`. Hosted, a
  fresh identity is a fresh **anonymous** session (that is what the app gives a browser with
  no session), and `personas.mjs` captures each one so the browser can resume it later —
  four participants, one Chrome. Assertions that read `matomeshi.mock.db.v2` become PostgREST
  reads made with **the participant's own token**, never the service role: "my post-close
  write was refused" is only meaningful when asked as the client.

  Two of its checks cannot run without a real `GOOGLE_PLACES_API_KEY` (`place-search` returns
  `502 place provider unavailable`), so no place can be picked and no place id can be
  persisted. They are skipped **loudly** — printed as `SKIP` with the reason, and counted in
  the summary line — and the picker states that *are* reachable are asserted instead: the four
  reference chips, the provider-failure branch with its retry (a dead provider must not read
  as 「見つかりませんでした」), どこでも clearing the place, and the skip notice. Expect
  `27/27 … (2 skipped: …)`.

`psql` is used for exactly one thing, in `verify:realtime`: deleting the requirement rows it
created. `0024` grants `DELETE` on `participant_constraints` to no API role (there is no delete
policy either), and adding one so a test could tidy up would be widening the schema for the
test's convenience. Set `SUPABASE_DB_URL` if the default local connection string is wrong; with
no psql reachable the rows are flipped to `PRIVATE` instead, which removes them from every
sanitized surface, and the run says which it did.

## Layout

```
src/styles/index.css     Design tokens: AppColors (light + dark), AppSpacing, AppRadius, AppTypography
src/design/              copy.ts (AppCopy), components.tsx, icons.tsx, cn.ts
src/models/              types.ts (wire shapes), format.ts (ConstraintFormatter), invite.ts
src/backend/types.ts     The interface the screens consume
src/backend/supabase.ts  Real backend — same RPCs/functions/topics as the Swift services
src/backend/mock.ts      In-browser fixture: seed.sql, deterministic parser, broadcasts
src/backend/engine.ts    TS port of AIKanji/supabase/migrations/0009_*.sql
src/features/            One file per screen, named after its SwiftUI counterpart
scripts/verify-engine.ts Engine assertions mirroring AIKanji/Tests/.../FeasibilityEngineTests.swift
```

### Where each screen came from

| Web | iOS |
| --- | --- |
| `features/Welcome.tsx` | `AIKanji/AIKanji/Features/Onboarding/WelcomeView.swift` |
| `features/CreateEvent.tsx` | `AIKanji/AIKanji/Features/Onboarding/CreateEventView.swift` |
| `features/JoinEvent.tsx` | `AIKanji/AIKanji/Features/Onboarding/JoinEventView.swift` |
| `features/EventHome.tsx` | `AIKanji/AIKanji/Features/Onboarding/EventHomeView.swift` |
| `features/ConstraintEntry.tsx` | `AIKanji/AIKanji/Features/Constraints/ConstraintEntryView.swift` |
| `features/GroupFeed.tsx` | `AIKanji/AIKanji/Features/Activity/GroupActivityFeedView.swift` |
| `features/OrganizerDashboard.tsx` | `AIKanji/AIKanji/Features/Organizer/OrganizerDashboardView.swift` |
| `features/Recommendations.tsx` | `AIKanji/AIKanji/Features/Recommendations/RecommendationListView.swift` |
| `features/RecommendationCard.tsx` | `AIKanji/AIKanji/Features/Recommendations/RecommendationCardView.swift` |
| `features/NegotiationConsent.tsx` | `AIKanji/AIKanji/Features/Negotiation/NegotiationConsentView.swift` |

`data-testid` attributes reproduce the SwiftUI `accessibilityIdentifier`s, so
`AIKanji/Tests/AIKanjiUITests/CriticalScreensUITests.swift` translates across almost verbatim.

## Platform substitutions

The design and behaviour are ported 1:1; these are the places where a native API had to
be swapped for a web equivalent.

| iOS | Web |
| --- | --- |
| `NavigationStack` | History-API stack; pushed screens stay mounted so parent state survives |
| SF Symbols | Inline SVGs in `design/icons.tsx` |
| Asset catalog colorsets | CSS custom properties, dark variant under `.dark` |
| `@Environment(\.colorScheme)` | `prefers-color-scheme` toggling `.dark` on `<html>` |
| `CIFilter.qrCodeGenerator` | `qrcode` |
| `DataScannerViewController` | `getUserMedia` + `jsqr` scan loop |
| `ShareLink` / `UIPasteboard` | `navigator.share` / `navigator.clipboard` |
| Dynamic Type | `text-size-adjust` plus rem-free token sizes |
| Keychain-backed session | `supabase-js` default storage (`localStorage`) |

Realtime is unchanged: private `event-{event_id}` broadcast topics for `constraint_added`
and `run_updated`, authorized by the policy on `realtime.messages`.

## PWA

Installable and offline-capable via `vite-plugin-pwa` (Workbox, `autoUpdate`). The app
shell is precached; Supabase REST/RPC/auth responses deliberately are **not**, because
they are per-session and authorization-dependent. Verify with `npm run build && npm run
preview` — service workers do not run in dev.

## Provider attribution — a licence obligation, not decoration

Venue attributes come from two providers, and both of them require a credit. They are separate
obligations with separate wording, and neither discharges the other; both are rendered together
at the foot of the shortlist by `ProviderAttribution`.

`AIKanji/supabase/functions/restaurant-search/index.ts` discovers candidates through the
**Google Places** API (`displayName`, location, `rating`/`userRatingCount`, `priceLevel`) and
then calls the **Hot Pepper Gourmet Web Service**
(`https://webservice.recruit.co.jp/hotpepper/gourmet/v1/`), merging that shop's
`private_room` into `room_type` and its `budget.average` into `price_yen_estimate` on the
matched candidate. Both of those merged fields are printed on every recommendation card.

Recruit's usage guideline (<https://webservice.recruit.co.jp/doc/hotpepper/guideline.html>)
makes a visible credit **mandatory** for any site or app that uses the data: either their
supplied banner image or the text 「Powered by ホットペッパーグルメ Webサービス」, linked to Hot
Pepper Gourmet. We use the text link — no third-party image asset to host or keep in sync.

| | |
| --- | --- |
| Rendered by | `ProviderAttribution` in `src/features/Recommendations.tsx` (iOS: `RecommendationListView.swift`) |
| Wording | `AttributionCopy` in `src/design/copy.ts` (iOS: `AppCopy.swift`) — same strings on both clients |
| Where | Foot of the recommendation shortlist, below the last card. One credit per list, not per card |
| `data-testid` | `provider-attribution`, `provider-attribution-link` (iOS `accessibilityIdentifier`s match) |
| Link | `https://www.hotpepper.jp/`, `target="_blank"` + `rel="noopener noreferrer"` (iOS: `Link`) |

Rules for anyone touching it:

1. **Do not delete it, and do not make it unreadable.** It looks like a footnote on purpose,
   but a credit nobody can read does not discharge the obligation. It is styled with the
   secondary-note tokens (`text-small`/`text-caption` at `text-ink/72`), which measure 5.4:1
   in light mode and 8.0:1 in dark — both clear WCAG AA. The link is a 44px tap target.
2. **Do not reword 「Powered by ホットペッパーグルメ Webサービス」.** That string is Recruit's,
   quoted verbatim.
3. **Keep the scope sentence above it.** Hot Pepper supplies only 個室 and the yen band; the
   sentence says so, because the bare credit would claim the whole shortlist — including
   Places-sourced names, locations and ratings — as theirs.
4. It is hidden only when the shortlist is empty, since then no sourced attribute is on screen.

### Google Maps attribution — the shortlist is covered, the rest is not (B5)

Google's Maps Platform terms impose their **own, separate** requirements on Places content, none
of which the Hot Pepper credit discharges. Two of them apply to this app:

1. Places content displayed **without a Google map** must carry Google Maps attribution — the
   Google logo, or the text "Google Maps" where space is limited — unmodified and legible. The
   shortlist is exactly that case: a list of venues, and the app draws no map anywhere.
2. The per-place third-party **`attributions`** a Place returns must be displayed with the
   content they belong to.

Requirement 1 is now met **on the recommendation shortlist**:

| | |
| --- | --- |
| Rendered by | `ProviderAttribution` in `src/features/Recommendations.tsx` (iOS: `RecommendationListView.swift`), directly below the Hot Pepper credit in the same block |
| Wording | `AttributionCopy.googleScope` and `AttributionCopy.googleCredit` in `src/design/copy.ts` (iOS: `AppCopy.swift`) — same strings on both clients |
| Says | 「お店探しと、店名・場所・口コミ評価（評価の件数を含む）などのお店の情報は、Google Maps から取得しています。」 and then, on its own line, `Google Maps` |
| `data-testid` | `google-attribution`, `google-attribution-credit` (iOS `accessibilityIdentifier`s match) |
| Form | The **text** form, not a hosted logo asset — see below. Latin script, unmodified, at full `text-ink` contrast rather than the `/72` used for our own footnotes, and not a link |

The scope sentence exists for the same reason Hot Pepper's does: `restaurant-search` discovers
the candidates through Places and stores the `displayName`, location and
`rating`/`userRatingCount`, so this names what Google supplies instead of leaving the existing
「別の提供元」 anonymous. Keep both sentences — each is what stops the other credit over-claiming.

**Still not satisfied.** This is a partial, not a completed obligation:

- **The logo.** We ship the sanctioned text form because Google's brand rules govern the asset,
  its clear space and its colour variants, and none of that can be verified from this repo — a
  wrong or stale logo would be a worse violation than the text they allow where space is
  limited. Someone with the current brand guidance in front of them should decide whether the
  asset is required here.
- **Per-place `attributions` are stored but not yet displayed.** The provider side landed
  separately: `restaurant-search` now requests `places.attributions` and records it verbatim in
  `restaurant_features.provider_attributions` (jsonb, migration 0023). The client half is
  missing — `RestaurantFeature` in `src/models/types.ts` has no such field and
  `backend.features()` does not select it — so nothing can reach the screen yet.
  `ProviderAttribution` takes an optional `placeAttributions: string[]` and renders it inside the
  Google block when non-empty, so wiring it up is (a) adding the field where the type lives and
  (b) deciding how an element that arrives as an **object** (Places (New) documents a provider
  name plus a provider URI; the column also accepts the historical HTML-ish string) becomes one
  displayable line. Neither the field name nor that mapping is invented here, because rewriting
  a credit is a misattribution. Note the rendering: the component prints each line as **text**
  (`dangerouslySetInnerHTML` is not an option for third-party markup, and the iOS side avoids
  `AttributedString(markdown:)` for the same reason), so markup inside a string shows as its
  characters rather than as a link — check that against the policy once real data flows.
- **The travel-reference place picker is not covered.** `place-search` returns Places
  `displayName`/`formattedAddress`, and `TravelReferenceField` (`src/features/CreateEvent.tsx`,
  reused by `JoinEvent`) plus the travel editor in `ConstraintEntry.tsx` print those suggestions
  with no map and no attribution. Same obligation, different screens; those views were out of
  scope for this change.
- **EEA/regional variations and the rest of the terms** (the EEA terms differ, and there are
  separate rules for caching, photos and reviews — we display neither photos nor review text)
  have not been reviewed here.

Tracked as B5 in `AIKanji/README.md`'s follow-up punch list.

## Deliberate deviations

1. **Mock-mode footnote on the welcome screen.** The only UI not in the iOS app: without
   it there is no way to discover the demo invite code. Guarded by `backend.mode === 'mock'`.
2. ~~**`demo01` instead of `DEMO01`.**~~ **Fixed upstream in 0021.** The seed used to carry an
   uppercase invite code that `fn_generate_invite_code` could never emit (its alphabet is
   lowercase and excludes `0`/`1`) and that the join screen's lowercasing could never match,
   making the documented demo event unreachable. `seed.sql` now seeds `demo01`, so the mock
   and the real fixture agree.
3. **Restaurant names in the fixture.** `AIKanji/supabase/seed.sql` leaves `restaurant_features.name` null;
   the real pipeline fills it from the Places `displayName`. The mock seeds Japanese names
   so the recommendation cards are not all titled 「おすすめのお店」.
4. **Mock travel times.** Standing in for `restaurant-search`, the mock fills the travel
   matrix for participants with no cached entry using a stable hash, as the real function
   would. Feasibility is unaffected; fairness scores become meaningful rather than all `1.0`.
5. ~~**Numeric-cast robustness.**~~ **Fixed upstream in 0021.** A non-numeric `max_yen` used to
   abort the entire recompute in Postgres (`invalid input syntax for integer`), while the port
   treated it as absent — so one malformed constraint could break the real backend but never
   the mock. SQL now reads jsonb integers through `fn_jsonb_int`, which matches the port's
   `nullableInt`. The two engines agree again.
