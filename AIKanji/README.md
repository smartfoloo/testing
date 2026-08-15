# AI 幹事 (AIKanji)

Native iOS app that helps a small coworker group agree on a restaurant. This stage covers only
the data foundation (schema + RLS + RPC) and the create/join flow.

## Layout

```
AIKanji.xcodeproj          Xcode project (SPM dependency on supabase-swift)
Config.xcconfig            SUPABASE_URL / SUPABASE_ANON_KEY (override in Secrets.xcconfig)
AIKanji/                   App sources
supabase/migrations/       0001_init.sql, 0002_rls.sql, 0003_functions.sql
project.yml                XcodeGen spec, kept in sync with the checked-in project
```

## Setup

1. Apply the migrations in order to a Supabase project (`supabase db push`, or paste them into the
   SQL editor). `postgis` and `vector` extensions must be available.
2. Enable **Anonymous sign-ins** in Authentication → Providers.
3. Create `Config.xcconfig`-adjacent `Secrets.xcconfig` (gitignored):

   ```
   SUPABASE_URL = abcdefgh.supabase.co
   SUPABASE_ANON_KEY = ey...
   ```

   The scheme is omitted because `//` starts a comment in xcconfig; `SupabaseConfig` prepends
   `https://`.
4. Open `AIKanji.xcodeproj` and run on an iOS 17+ simulator. Xcode resolves `supabase-swift` on
   first build.

## Security boundary

Only `participant_constraints` has client-writable INSERT/UPDATE policies. Everything else is
written through `security definer` RPCs (`fn_create_event`, `fn_join_event`) or, later, Edge
Functions with the service-role key.

## Verifying the acceptance criteria

- **Anonymous session persists:** launch, then relaunch — `auth.session` is restored by the SDK's
  keychain storage, no second `signInAnonymously` call.
- **Two participants, one event:** create an event on simulator A, join with the same invite code
  on simulator B; `participants` has two rows for the event and A's row has `role = 'organizer'`.
- **RLS is active:** insert a `participant_constraints` row for participant B (via SQL editor),
  then `select * from participant_constraints` from A's session returns zero rows.
- **QR round trip:** scan the QR shown by `CreateEventView` with `JoinEventView`'s scanner; the
  code field fills with the identical 6-character invite code.
