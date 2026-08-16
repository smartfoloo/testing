# AI 幹事 (AIKanji)

Native iOS app that helps a small coworker group agree on a restaurant. This stage covers only
the data foundation (schema + RLS + RPC) and the create/join flow.

## Layout

```
AIKanji.xcodeproj          Xcode project (SPM dependency on supabase-swift)
Config.xcconfig            Compile-safe placeholders; generated Secrets.xcconfig overrides them
AIKanji/                   App sources
supabase/migrations/       0001_init.sql … 0028_provider_display_fields_and_quality_percentiles.sql
supabase/functions/        llm-assist, restaurant-search, and place-search Edge Functions
supabase/seed.sql          Deterministic demo fixture for the feasibility engine
project.yml                XcodeGen spec, kept in sync with the checked-in project
```

## Setup

1. From the repository root, create the single local environment file and generate both client
   configurations:

   ```bash
   cp .env.example .env
   # Fill only the values needed for this environment.
   node scripts/sync-local-secrets.mjs
   node scripts/sync-local-secrets.mjs --check
   ```

   Root `.env` is gitignored and is the only hand-maintained local source. The script writes the
   publishable Supabase URL/anon key and optional invite-link base to the gitignored
   `AIKanji/Secrets.xcconfig`; it writes only the corresponding two `VITE_*` values for Web. If
   both Supabase client values are blank, it can discover a running local stack. The Supabase anon
   key is publishable, but authorization must still be enforced by RLS.
2. Apply all migrations in order to a Supabase project (`supabase db push`, or paste them into the
   SQL editor). `postgis` and `vector` extensions must be available.
3. Enable **Anonymous sign-ins** in Authentication → Providers, and disable *Allow public access*
   in Realtime Settings so the `event-{id}` topics are private.
4. Load the root environment and register each configured provider setting in Supabase's encrypted
   Edge Function secret store before deploying the functions:

   ```bash
   set -a
   . ./.env
   set +a
   cd AIKanji
   supabase secrets set LLM_API_KEY="$LLM_API_KEY"  # repeat for configured provider variables
   supabase functions deploy
   ```

   `SUPABASE_SERVICE_ROLE_KEY`, provider keys, and hosted-test passwords are server/test-only. They
   must never be added to `Secrets.xcconfig` or any `VITE_*` variable. Supabase supplies its service
   role to the hosted Edge Runtime; do not bundle it in either client.
5. Open `AIKanji.xcodeproj` and run on an iOS 17+ simulator. Xcode resolves `supabase-swift` on
   first build.

### Hosted domain-test personas

The hosted domain suite signs in five test personas (`alice`, `bob`, `charlie`, `david`, and
`emma`) using the password supplied through `AIKANJI_TEST_PASSWORD`. Keep that password only in
the ignored root `.env`. Create the five users in Supabase Authentication → Users with addresses
`<persona>@aikanji.demo`, then update the seeded participant rows so each `auth_user_id` points
to the corresponding Auth user UUID. The rows are identified by their stable participant IDs in
`supabase/seed.sql`. Before invoking `xcodebuild`, shell-source root `.env`; its `TEST_RUNNER_*`
references forward the Supabase URL, anon key, service-role key, and test password to the test
process without placing them in the app bundle.

## Security boundary

Only `participant_constraints` has client-writable INSERT/UPDATE policies. Everything else is
written through `security definer` RPCs (`fn_create_event`, `fn_join_event`) or, later, Edge
Functions with the service-role key.

Because RLS hides other participants' constraint rows, the group feed is not a table read: a
trigger builds a sanitized payload (name stripped for ANONYMOUS, PRIVATE rows never sent) and
`realtime.send`s it to the private topic `event-{event_id}`; `fn_get_sanitized_feed` serves the
same shape for history.

## Provider attribution — a licence obligation, not decoration

`supabase/functions/restaurant-search/index.ts` uses two providers. It discovers candidates
through the **Google Places** API (`displayName`, location, `rating`/`userRatingCount`,
`priceLevel`), then calls the **Hot Pepper Gourmet Web Service**
(`https://webservice.recruit.co.jp/hotpepper/gourmet/v1/`) and merges the matched shop's
`private_room` into `room_type` and its `budget.average` into `price_yen_estimate`. Both of
those merged fields are printed on every recommendation card.

Recruit's usage guideline (<https://webservice.recruit.co.jp/doc/hotpepper/guideline.html>)
makes a visible credit **mandatory** for any site or app that uses the data: either their
supplied banner image or the text 「Powered by ホットペッパーグルメ Webサービス」, linked to Hot
Pepper Gourmet. We use the text link, so there is no third-party image asset in the catalog.

- Rendered by `ProviderAttribution` in
  `AIKanji/Features/Recommendations/RecommendationListView.swift`, at the foot of the
  shortlist — one credit for the whole list, not one per card. The chosen card is the same
  `RecommendationCardView` inside that same list, so it is already covered.
- Wording lives in `AttributionCopy` (`AIKanji/DesignSystem/AppCopy.swift`), mirrored 1:1 by
  `AttributionCopy` in `web/src/design/copy.ts`. Both clients say the same thing.
- `accessibilityIdentifier`s `provider-attribution` and `provider-attribution-link` mirror the
  web `data-testid`s.
- It is a real `Link` to `https://www.hotpepper.jp/`, minimum 44pt tall, in the muted
  secondary-note style (`AppTypography.small`/`.caption` at `AppColors.ink.opacity(0.72)`).

Do not delete it and do not make it unreadable — a credit nobody can read does not discharge
the obligation. Do not reword 「Powered by ホットペッパーグルメ Webサービス」; that string is
Recruit's, quoted verbatim. Keep the `scope` sentence above it, because Hot Pepper supplies
only 個室 and the yen band and the bare credit would claim the Places-sourced name, location
and rating as theirs too.

### Google Maps attribution (partially covered — B5)

Google's Maps Platform terms carry their own, separate requirements for Places content, which
the Hot Pepper credit does not satisfy. Places content displayed **without a Google map** — this
app draws no map at all — must carry Google Maps attribution: the Google logo, or the text
"Google Maps" where space is limited, unmodified and legible.

That much is now rendered on the shortlist, in the same `ProviderAttribution` block, directly
below the Hot Pepper credit:

- Wording in `AttributionCopy.googleScope` / `AttributionCopy.googleCredit`
  (`AIKanji/DesignSystem/AppCopy.swift`), mirrored 1:1 in `web/src/design/copy.ts`. The scope
  sentence names what Places supplies — the discovery itself plus the `displayName`, location
  and `rating`/`userRatingCount` — so neither credit claims the other's fields.
- The **text** form, not a logo asset in the catalog: Google's brand rules govern the image and
  cannot be verified from this repo, and a wrong or stale logo is a worse violation than the
  text form they sanction. Latin script, unmodified, `AppColors.ink` at full opacity (not the
  0.72 our own footnotes use), and not a `Link`.
- `accessibilityIdentifier`s `google-attribution` and `google-attribution-credit` mirror the web
  `data-testid`s.

What is still outstanding is listed under B5 below. `web/README.md` has the same table plus the
per-screen detail.

## Automated backend tests

```
supabase/tests/run.sh
```

Boots a throwaway `supabase/postgres` container, applies every migration plus `seed.sql`, and
runs `supabase/tests/backend_tests.sql`, which impersonates end users through
`request.jwt.claim.sub` and asserts the create/join flow, the RLS boundary, the sanitized feed
and broadcast payloads, and the feasibility/negotiation engine. `harness.sql` supplies local
stand-ins for `realtime.messages` / `realtime.send`, which the hosted Realtime service owns.
Requires Docker; no Xcode or macOS needed.

## Verifying the acceptance criteria

- **Anonymous session persists:** launch, then relaunch — `auth.session` is restored by the SDK's
  keychain storage, no second `signInAnonymously` call.
- **Two participants, one event:** create an event on simulator A, join with the same invite code
  on simulator B; `participants` has two rows for the event and A's row has `role = 'organizer'`.
- **RLS is active:** insert a `participant_constraints` row for participant B (via SQL editor),
  then `select * from participant_constraints` from A's session returns zero rows.
- **QR round trip:** scan the QR shown by `CreateEventView` with `JoinEventView`'s scanner; the
  code field fills with the identical 6-character invite code.
- **Parse round trip:** submit a MUST in Japanese or English — the confirm sheet shows the parsed
  category/value before anything is written.
- **Fail-closed parse:** unset `LLM_API_KEY` (or point `LLM_BASE_URL` at a bad host) — the function
  answers 200 with `normalized_type: "other"`, `needs_clarification: true`.
- **Live feed:** a PUBLIC save appears in the other participant's feed within ~1s with the name;
  an ANONYMOUS save appears with `display_name: null` — the feed screen prints the raw payload it
  received so this can be checked on the wire.
- **PRIVATE never broadcasts:** insert a `visibility = 'PRIVATE'` row via the SQL editor; no
  broadcast arrives and the row is absent from `fn_get_sanitized_feed`.

## Deliberate follow-up punch list

- **B3:** scope restaurant candidates and cached features to the event rather than sharing a
  global `restaurant_features` pool.
- **B4:** add a needs-confirmation evidence tier for live provider data whose dietary/allergy
  attributes are not verified.
- **B5 — Google Maps/Places attribution.** Partially done, deliberately not claimed as
  finished. **Done:** the Google Maps attribution required when Places content is shown without
  a Google map is now displayed at the foot of the recommendation shortlist on both clients, in
  the sanctioned text form, with a scope sentence saying what Places supplies (see the section
  above). **Outstanding:**
  - the logo asset — we use the text form on purpose, because the brand rules governing the
    image cannot be verified from here; whether the logo is required on this surface needs
    reading off the current guidance;
  - the per-place `attributions` are stored but **not** displayed: `restaurant-search` now asks
    for `places.attributions` and records it verbatim in
    `restaurant_features.provider_attributions` (jsonb, migration 0023), but no client type
    carries it — `RestaurantFeature` in `AIKanji/Models/Recommendation.swift` has no such field
    and the service does not select it. `ProviderAttribution` on both clients accepts an optional
    `placeAttributions: [String]` and renders it verbatim as text when non-empty, so what is left
    is adding the field where the type lives and deciding how an element that arrives as an
    object (a provider name plus a provider URI) becomes one line; neither the field name nor
    that mapping is invented client-side, because an edited credit is a misattribution.
    `place-search` still does not request `attributions` at all;
  - the travel-reference place picker (`place-search`'s `displayName`/`formattedAddress`, shown
    on the create/join and requirement screens) carries no attribution yet — same obligation,
    different screens;
  - the EEA terms differ from the general ones, and neither those nor the caching/photo/review
    rules have been reviewed here.
- Add read-through caching based on `last_fetched_at` before making provider calls.
