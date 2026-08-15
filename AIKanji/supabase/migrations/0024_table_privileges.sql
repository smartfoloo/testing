-- 0024_table_privileges.sql
-- The schema states its own table privileges instead of inheriting whichever ones
-- happen to be configured on the database it is applied to.
--
-- Not one of the tables created by 0001-0016 was ever granted anything. The only
-- privileges `anon` / `authenticated` / `service_role` had on them came from
-- `pg_default_acl`, and a default-ACL entry is keyed by the role that CREATES the
-- object. The entry that hands out CRUD in `public` belongs to `supabase_admin`,
-- while migrations are applied as `postgres` (both locally via `supabase db reset`
-- and on a hosted project via `supabase db push`), so nothing attached and the ACL
-- of every core table came out as:
--
--   postgres=arwdDxtm/postgres  anon=Dxtm/postgres
--   authenticated=Dxtm/postgres service_role=Dxtm/postgres
--
-- TRUNCATE / REFERENCES / TRIGGER / MAINTAIN — and no SELECT, INSERT, UPDATE or
-- DELETE whatsoever. The app therefore could not read its own tables:
--
--   set role authenticated;  select count(*) from public.events;
--     ERROR 42501: permission denied for table events
--   set role service_role;   select count(*) from public.participants;
--     ERROR 42501: permission denied for table participants
--
-- and every screen behind those reads was dead on arrival. The only tables that
-- escaped are the five 0017 added, because 0017 granted them explicitly, plus
-- `restaurant_features`, which 0023 granted SELECT on for exactly this reason. This
-- migration is the rest of the schema catching up, so the answer no longer depends on
-- who ran the migration or on how a particular project was bootstrapped.
--
-- This is not a local quirk to be worked around, it is the direction of travel, and
-- our own supabase/config.toml documents it: `auto_expose_new_tables`, "controls
-- whether new tables, views, sequences and functions created in the `public` schema
-- by `postgres` are reachable through the Data API roles (`anon`, `authenticated`,
-- `service_role`) without explicit GRANTs. When unset, new entities are NOT
-- auto-exposed, matching the new cloud default … this is deprecated and the field is
-- removed on 2026-10-30 once the always-revoked behaviour is permanent." So the
-- escape hatch is a dated one, and a schema that states its own grants is the only
-- version of this that keeps working.
--
-- Nothing caught it because nothing ever ran as a client role against the real ACLs.
-- `backend_tests.sql` connects as the table owner (`postgres`, which locally also
-- carries BYPASSRLS) and its `t_as_user` helper does `set role authenticated`, so RLS
-- was genuinely exercised — but every database the suite has actually been run against
-- had an ambient `alter default privileges` that already handed the client roles every
-- table privilege, so the ACL half of all 173 checks was free. The mock backend has no
-- database at all, and CI's `backend` job runs the same harness. The allow-side and
-- deny-side probes added to `backend_tests.sql` alongside this migration assert the
-- ACLs themselves, under the real roles, and fail if this migration is reverted.
--
-- A grant and a policy are not substitutes: a grant decides whether a role may
-- touch the table at all, RLS decides which rows it then sees. Both are required,
-- and the grants below are deliberately the narrower half of that pair — every one
-- of them lands on a table whose RLS policies already scope the rows.
--
-- Two things this migration does NOT do:
--
--   * It grants `anon` nothing, and takes away what the default ACL left behind. A
--     Supabase anonymous sign-in issues a JWT whose role claim is `authenticated`,
--     not `anon`; `ensureSession()` (web) and `Supa.ensureSession()` (iOS) both
--     guarantee a session before any query, and the `restaurant-search` Edge
--     Function's caller-side client is the anon KEY carrying the caller's
--     Authorization header — which is also `authenticated`. There is no caller in
--     this app that runs as `anon`, so a grant to `anon` would widen the blast
--     radius of a leaked publishable key for nobody's benefit. (It also strips the
--     inherited TRUNCATE: TRUNCATE ignores RLS entirely, so `anon`/`authenticated`
--     holding it on `events` was a privilege no policy could have contained. It is
--     not reachable through PostgREST, which never emits TRUNCATE, but it has no
--     business being there.)
--
--   * It grants nothing for a write that goes through a `security definer` RPC.
--     Those run with the function owner's privileges, so `fn_create_event`,
--     `fn_join_event`, `fn_set_travel_reference`, `fn_respond_negotiation`,
--     `fn_choose_restaurant`, `fn_recompute_feasibility`,
--     `fn_record_provider_candidates`, `fn_record_travel_minutes` and the rest need
--     no caller-side table privilege at all — which is exactly why `participants`
--     gets SELECT and nothing else. Only a direct client write needs a grant.
--
-- Existing, deliberate revokes are preserved rather than undone:
--   * 0017 revoked everything from `anon, authenticated` on the five provider
--     tables and granted back SELECT on four; `restaurant_source_records` stays
--     client-unreadable (provider content, service-role only) and 0023 depends on
--     that. Those five tables are not touched here.
--   * 0020 revoked INSERT/UPDATE/DELETE on `participants` from `anon,
--     authenticated`: a participant changes their travel reference through
--     `fn_set_travel_reference`, never by writing the row. Only SELECT is granted
--     below.
--   * The `for update` policy on `participant_constraints` (0007, re-stated by
--     0018 with the post-close closure check) is the one client write policy that
--     survives, so UPDATE is granted there and nowhere else.
--
-- Idempotent: `grant` / `revoke` are absolute, not additive, so re-running this
-- migration is a no-op, and it applies cleanly on top of 0001-0023 whether or not
-- the privileges already happen to exist.

-- --- Client roles: strip the inherited leftovers, then state the real set --------
--
-- `revoke all` first (0017's pattern) so the outcome is the same on a database
-- whose default ACL granted the client roles everything, on one that granted them
-- TRUNCATE-and-friends, and on one that granted them nothing at all.

revoke all on table public.events                  from anon, authenticated;
revoke all on table public.participants            from anon, authenticated;
revoke all on table public.participant_constraints from anon, authenticated;
revoke all on table public.negotiations            from anon, authenticated;
revoke all on table public.recommendation_runs     from anon, authenticated;
revoke all on table public.recommendation_scores   from anon, authenticated;
revoke all on table public.restaurants             from anon, authenticated;
revoke all on table public.restaurant_features     from anon, authenticated;

-- events — SELECT.
-- `event(inviteCode)` and `decision(eventId)` in web/src/backend/supabase.ts and
-- `EventService.event(...)` / `decision(...)` on iOS read this table directly. RLS
-- ("event visible to its participants", 0002/0007) narrows it to the caller's own
-- events. No client write: creation, the organizer's choice and the collection
-- lifecycle are all definer RPCs.
grant select on table public.events to authenticated;

-- participants — SELECT only.
-- `role(participantId)` and `participantTravel(participantId)` read it, and the
-- membership policy (0007) scopes it to co-participants of the caller's events. The
-- 0002/0007 policy on `events` also subqueries this table, and a policy predicate
-- is evaluated with the caller's privileges — so without SELECT here, a select on
-- `events` fails with "permission denied for table participants" before RLS is even
-- reached. Writes stay revoked, per 0020.
grant select on table public.participants to authenticated;

-- participant_constraints — SELECT, INSERT, UPDATE.
-- The only table the clients write directly (`insertConstraint`, and
-- ConstraintService.swift's `.insert(ConstraintInsert(...))`), which is precisely
-- why it is the only table with client write policies. SELECT backs
-- `ownConstraints(participantId)` and the `participant_constraints(...)` embed the
-- pending-negotiation query resolves. UPDATE matches the "participant updates own
-- raw constraints" policy that 0007 wrote and 0018 re-stated with the
-- `not fn_preferences_closed(...)` closure; the policy is the schema's statement
-- that a participant may edit their own row, and without the privilege it could
-- never fire. No DELETE: 0018 notes there is deliberately no delete policy either.
grant select, insert, update on table public.participant_constraints to authenticated;

-- negotiations — SELECT.
-- `pendingNegotiation(participantId)` reads the caller's open proposal; RLS
-- restricts the table to rows targeting the caller. Answering one is
-- `fn_respond_negotiation` (definer), and proposals are written by
-- `fn_propose_relaxation` (definer), so no client write privilege.
grant select on table public.negotiations to authenticated;

-- recommendation_runs — SELECT. `latestRun(eventId)`, scoped by RLS to the
-- caller's events. Runs are inserted by `fn_recompute_feasibility` (definer).
grant select on table public.recommendation_runs to authenticated;

-- recommendation_scores — SELECT. `scores(runId)`, scoped by RLS through the run to
-- the caller's events. That policy subqueries `recommendation_runs`, which the
-- grant above makes readable — again, both halves are needed.
grant select on table public.recommendation_scores to authenticated;

-- restaurants — SELECT.
-- 0002's "restaurants readable by any authenticated user" policy has always
-- declared this table client-readable, and it stayed that way through every later
-- migration (0017 tightened the new provider tables, not this one). Without the
-- matching privilege that policy is dead text. The row holds an opaque place id,
-- an optional Hot Pepper id and two cache timestamps — no provider content, which
-- is why it may be readable while `restaurant_source_records` may not — and it is
-- the FK parent that `recommendation_scores.restaurant_place_id` and
-- `restaurant_features.place_id` point at, so it is what any embed from the two
-- tables the clients do read resolves through. Write paths are the definer provider
-- RPCs, so no client write.
grant select on table public.restaurants to authenticated;

-- restaurant_features — SELECT. Re-stated from 0023 (which granted exactly this)
-- because the `revoke all` above would otherwise drop it. `restaurantName(placeId)`
-- and `features(placeIds)` read it, and 0023 relies on `provider_attributions`
-- being client-readable here while the raw payload table is not.
grant select on table public.restaurant_features to authenticated;

-- --- service_role ---------------------------------------------------------------
--
-- The trusted server-side identity: the two Edge Functions' service-role clients
-- and `scripts/bootstrap-hosted-fixture.mjs`. It bypasses RLS by design, so its
-- privileges are the only boundary it has and they are enumerated per table rather
-- than granted wholesale. Not revoked first: unlike the client roles, nothing has
-- ever revoked anything from `service_role`, so there is nothing to undo, and the
-- provider tables it already owns (0017) keep the CRUD 0017 gave them.
--
-- No INSERT anywhere below: everything this role creates it creates through a
-- definer RPC (`fn_record_provider_candidates`, `fn_record_travel_minutes`,
-- `fn_recompute_feasibility`, `fn_record_provider_*`), which runs as the owner.
-- The DELETEs are the fixture reset; the UPDATEs are the fixture rewiring seeded
-- rows to real Auth uids. SELECT is required on every table it PATCHes or DELETEs
-- as well, because that script sends `Prefer: return=representation`.

-- events: read by the fixture's "is the demo event actually here?" guard, updated
-- by its reset of status / chosen_place_id / chosen_at / preferences_closed_at.
grant select, update on table public.events to service_role;

-- participants: read by restaurant-search (origins for the meeting zones),
-- updated by the fixture to point seeded rows at the real Auth uids — the one
-- rewrite that only a role bypassing RLS can perform.
grant select, update on table public.participants to service_role;

-- participant_constraints: read by restaurant-search (WANT cuisine tags) and by
-- llm-assist (grounding for an explanation); updated by the fixture, which puts
-- Bob's room MUST back to `private` so the 0-then-3 demo premise holds again.
grant select, update on table public.participant_constraints to service_role;

-- negotiations: cleared by the fixture reset (with the representation read).
grant select, delete on table public.negotiations to service_role;

-- recommendation_runs: read by llm-assist for the run being explained, cleared by
-- the fixture reset — scores cascade from the FK, which needs no privilege.
grant select, delete on table public.recommendation_runs to service_role;

-- recommendation_scores: read by llm-assist (the scored candidate it must explain) and
-- WRITTEN BACK by it — `explain` mode ends in `.from("recommendation_scores")
-- .update({ explanation })` (llm-assist/index.ts:606). Without UPDATE that PATCH is a
-- silent 403 inside the Edge Function: every card falls back to its generic explanation
-- and A7's "grounded in stored data" quietly stops being true, with nothing in the UI to
-- say why. Caught only by running the function against a real PostgREST.
-- No DELETE: scores go with their run, through the cascade.
grant select, update on table public.recommendation_scores to service_role;

-- restaurants / restaurant_features: read side of the provider pipeline —
-- llm-assist reads the venue's features for grounding. Writes go through the
-- definer recorder functions, so neither table needs INSERT or UPDATE here.
grant select on table public.restaurants to service_role;
grant select on table public.restaurant_features to service_role;

-- --- Sequences ------------------------------------------------------------------
--
-- An INSERT into a table with a serial/identity column also needs `usage` on the
-- sequence behind it, and that is a separate ACL the same default-privilege gap
-- would have swallowed. There is nothing to grant: `public` contains no sequence at
-- all (pg_class where relkind = 'S' and relnamespace = 'public'::regnamespace is
-- empty after 0023), because every primary key in this schema is either a
-- `gen_random_uuid()` uuid or a provider-supplied text id. Rather than grant into
-- the void, the invariant is asserted in backend_tests.sql ("every sequence behind
-- a table the client may INSERT into is usable by that client"), which stays green
-- today and fails the moment somebody adds a serial column without its grant.
