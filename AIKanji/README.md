# AI 幹事 (AIKanji)

Native iOS app that helps a small coworker group agree on a restaurant. This stage covers only
the data foundation (schema + RLS + RPC) and the create/join flow.

## Layout

```
AIKanji.xcodeproj          Xcode project (SPM dependency on supabase-swift)
Config.xcconfig            SUPABASE_URL / SUPABASE_ANON_KEY (override in Secrets.xcconfig)
AIKanji/                   App sources
supabase/migrations/       0001_init.sql … 0005_feasibility.sql
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

## Security boundary

Only `participant_constraints` has client-writable INSERT/UPDATE policies. Everything else is
written through `security definer` RPCs (`fn_create_event`, `fn_join_event`) or, later, Edge
Functions with the service-role key.

Because RLS hides other participants' constraint rows, the group feed is not a table read: a
trigger builds a sanitized payload (name stripped for ANONYMOUS, PRIVATE rows never sent) and
`realtime.send`s it to the private topic `event-{event_id}`; `fn_get_sanitized_feed` serves the
same shape for history.

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
