# AI 幹事 (AIKanji)

Native iOS app that helps a small coworker group agree on a restaurant. This stage covers only
the data foundation (schema + RLS + RPC) and the create/join flow.

## Layout

```
AIKanji.xcodeproj          Xcode project (SPM dependency on supabase-swift)
Config.xcconfig            SUPABASE_URL / SUPABASE_ANON_KEY (override in Secrets.xcconfig)
AIKanji/                   App sources
supabase/migrations/       0001_init.sql … 0007_security_hardening.sql
supabase/functions/        llm-assist (parse), restaurant-search Edge Functions
supabase/seed.sql          Deterministic demo fixture for the feasibility engine
project.yml                XcodeGen spec, kept in sync with the checked-in project
```

## Setup

1. Apply the migrations in order to a Supabase project (`supabase db push`, or paste them into the
   SQL editor). `postgis` and `vector` extensions must be available.
2. Enable **Anonymous sign-ins** in Authentication → Providers, and disable *Allow public access*
   in Realtime Settings so the `event-{id}` topics are private.
3. Deploy the Edge Function and set its secret (the LLM key never reaches the client):

   ```
   supabase secrets set LLM_API_KEY=sk-...   # optional: LLM_MODEL, LLM_BASE_URL
   supabase functions deploy llm-assist
   ```
4. Create `Config.xcconfig`-adjacent `Secrets.xcconfig` (gitignored):

   ```
   SUPABASE_URL = abcdefgh.supabase.co
   SUPABASE_ANON_KEY = ey...
   ```

   The scheme is omitted because `//` starts a comment in xcconfig; `SupabaseConfig` prepends
   `https://`.
5. Open `AIKanji.xcodeproj` and run on an iOS 17+ simulator. Xcode resolves `supabase-swift` on
   first build.

### Hosted domain-test personas

The hosted domain suite signs in five test personas (`alice`, `bob`, `charlie`, `david`, and
`emma`) using the password supplied through `AIKANJI_TEST_PASSWORD`; never put that password in
this repository. Create the five users in Supabase Authentication → Users with addresses
`<persona>@aikanji.demo`, then update the seeded participant rows so each `auth_user_id` points
to the corresponding Auth user UUID. The rows are identified by their stable participant IDs in
`supabase/seed.sql`. Export `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and
`AIKANJI_TEST_PASSWORD` before running the hosted suite.

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

**Not covered:** Google's Maps Platform terms carry their own, separate attribution
requirements for Places content, which the Hot Pepper credit does not satisfy. See the punch
list below and `web/README.md`.

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
- **B5 — Google Maps/Places attribution.** The Hot Pepper credit above is done; Google's is
  not. Maps Platform terms impose their own requirements on Places content (broadly: show
  "Powered by Google" / the Google logo wherever Places data or Maps imagery is displayed, and
  surface the per-place `attributions` and third-party notices the API returns). Neither
  `X-Goog-FieldMask` in `restaurant-search` nor `place-search` asks for `attributions` today,
  so we do not even hold the data — and adding a field to a mask can move the call to a
  pricier SKU, per the billing note at the top of both functions. Placement, logo assets and
  that billing consequence have to be read off the current policy rather than guessed at, so
  this is deliberately unimplemented, not overlooked.
- Add read-through caching based on `last_fetched_at` before making provider calls.
