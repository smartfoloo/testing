-- 0029: the organizer's dashboard goes live — mark stale, coalesce, recompute once.
--
-- PRD §12 describes a dashboard that moves as answers arrive. It did not move.
-- `fn_recompute_feasibility` had exactly three callers — the iOS dashboard button, the web
-- dashboard button, and `fn_respond_negotiation` after a consent — so the 0-then-3 beat the whole
-- demo is built on needed a human to press 「条件に合うお店を探す」 between submissions.
-- `participant_constraints` already carried three triggers (`trg_touch_participant_constraints`,
-- `trg_broadcast_constraint`, `trg_derive_constraint_metadata`) and not one of them recomputed.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS NOT A TRIGGER THAT CALLS fn_recompute_feasibility
-- ---------------------------------------------------------------------------
-- The one-line fix is wrong four separate ways, each of them fatal on its own:
--
--  1. EVERY RECOMPUTE INSERTS A `recommendation_runs` ROW, which fires `trg_broadcast_run_change`
--     (0006/0009, payload extended by 0025). Recomputing per constraint would mean one run row and
--     one `run_updated` push per submission, and `latestRun()` — the `order by run_at desc limit 1`
--     both clients open their dashboard with — would stop meaning "the last real computation" and
--     start meaning "the last thing anybody typed". `web/scripts/realtime-delivery.mjs` reads the
--     run count on the demo event immediately before its push, precisely so the number the push
--     brings cannot already be on screen; per-insert runs would break that, correctly.
--  2. RECOMPUTE WALKS THE GLOBAL VENUE POOL. `fn_recompute_feasibility` iterates
--     `from public.restaurants r join public.restaurant_features rf` with no event filter — README
--     punch-list item B3. That is 14 venues on the demo project today and one more for every live
--     search by any event on the project, forever. Making it fire per INSERT turns a cost the
--     organizer asks for into a cost every participant pays on every keystroke's worth of data.
--  3. IT WOULD FIRE DURING SEEDING. `seed.sql` inserts its ten constraints directly, so
--     `supabase db reset` would write recommendation runs for an event that has no candidate
--     shortlist yet — a `0` produced before anybody has searched, indistinguishable from a real one.
--  4. IT WOULD PUT THE RECOMPUTE INSIDE THE PARTICIPANT'S OWN INSERT. The person who typed
--     「予算は4000円まで」 would wait for the whole feasibility walk before their save returned, and
--     a slow pool would look to them like a failure to save their requirement.
--
-- (0014's request-context guard is NOT what stops this: a participant inserting their own
-- constraint is by definition a participant of that event, so the guard passes cleanly. The four
-- reasons above are the ones that decide the design.)
--
-- ---------------------------------------------------------------------------
-- WHAT HAPPENS INSTEAD: three jobs, each done by whoever is placed to do it
-- ---------------------------------------------------------------------------
--   database (here)   marks the event stale and says so — ONCE per statement, no matter how many
--                     rows the statement touched. It never recomputes and never writes a run.
--   client            coalesces a burst of those notifications into ONE recompute after a short
--                     quiet period (web/src/features/OrganizerDashboard.tsx, and the iOS dashboard
--                     against the same contract).
--   recompute         stays exactly what it was: an explicit act, one run row per call.
--
-- Five people answering in the same few seconds therefore produce five notifications, one
-- recompute and one run — which is what "the dashboard is live" has to mean if `latestRun()` is to
-- keep its meaning.
--
-- ---------------------------------------------------------------------------
-- STATEMENT-LEVEL, AND WHY THAT NEEDS TRANSITION TABLES
-- ---------------------------------------------------------------------------
-- `for each statement`, not `for each row`: that is the mechanism that makes one statement cost one
-- stamp and one message regardless of row count. A statement-level trigger has no `NEW`/`OLD` — so
-- the rows it is firing for are read out of the transition tables the `referencing` clause asks for
-- (`new table as new_rows`, `old table as old_rows`) and reduced to their DISTINCT `event_id`s.
-- Without transition tables a statement-level trigger cannot know which events changed at all, and
-- the alternative (a row-level trigger that de-duplicates in a session variable) would be doing
-- the same aggregation by hand, per row, with no way to know which row is the last.
--
-- THREE triggers rather than one, and not by preference: PostgreSQL refuses transition tables on a
-- trigger covering more than one event ("transition tables cannot be specified for triggers with
-- more than one event"), because `INSERT` has no OLD TABLE and `DELETE` has no NEW TABLE. One
-- function serves all three and branches on `tg_op`; plpgsql prepares a statement only when it is
-- first executed, so the branch naming a transition table this firing does not have is never
-- planned, let alone run.
--
-- ---------------------------------------------------------------------------
-- WHAT THE PAYLOAD CONTAINS, AND WHAT IT DELIBERATELY DOES NOT
-- ---------------------------------------------------------------------------
-- `{event_id, stale_at}`. Nothing else, ever. This is a notification that something changed, not a
-- feed item: the feed is `constraint_added` (0004), which is sanitized, per-row, and refuses PRIVATE
-- outright. This message fires for PRIVATE rows too — that is the entire point, because a PRIVATE
-- MUST changes what is feasible exactly as much as a public one does, and an organizer whose count
-- silently ignored the person least willing to say why would be the worst possible failure here.
--
-- So it must not carry a participant, a `raw_text`, a `normalized_type`, a value or a visibility.
-- With only an event id and a timestamp, a PRIVATE row is observable as "something changed" and
-- nothing more — which is what every other participant could already infer from 回答数 going up,
-- and is strictly less than `constraint_added` already reveals about a PUBLIC row. The README's
-- privacy promise ("非公開：本人以外の画面にも、リアルタイム通知にも流しません") is about the
-- 条件 itself, and no part of the 条件 is in here. `backend_tests.sql`'s 0029 block asserts the
-- key set is exactly these two, so a later "just add the type, it's harmless" cannot pass review.
--
-- One key arrives that this file does not write: hosted `realtime.send` stamps a payload that has
-- no `id` of its own with `gen_random_uuid()`, as a message identifier clients can de-duplicate on
-- (0004's payload keeps its own `id`, the constraint's, and is left alone). It names a message, not
-- a person and not a requirement, so the contract above holds on the wire as well.

-- ---------------------------------------------------------------------------
-- A. The durable mark
-- ---------------------------------------------------------------------------

-- Nullable, and never given a default: null means no requirement has ever been written for this
-- event, so there is nothing pending. Non-null is the instant of the most recent change to the
-- event's requirements, which is only meaningful next to a run's `run_at` — `stale_at > run_at` is
-- exactly "the number on screen does not include everything". That comparison is what the dashboard
-- makes, and it is the reason a durable column exists beside the broadcast at all: a broadcast is
-- only heard by whoever is connected, so a client that was closed when the answer arrived needs a
-- row to read on load.
--
-- Deliberately NOT cleared when a run lands, even though "null = nothing pending" is the tidier
-- reading. It cannot be made truthful: `fn_recompute_feasibility` stamps its run with the
-- transaction's `now()` and only then walks the pool, so a constraint committing while that walk is
-- in flight can carry a stamp EARLIER than the run that did not include it — and clearing on
-- `stale_at <= run_at` would silently drop it. Keeping both timestamps is strictly more information
-- than a nulled column, and costs the reader one comparison.
alter table public.events add column if not exists feasibility_stale_at timestamptz;

-- ---------------------------------------------------------------------------
-- B. The marker
-- ---------------------------------------------------------------------------

create or replace function public.fn_mark_feasibility_stale()
returns trigger
security definer
language plpgsql
set search_path = ''
as $$
declare
  -- `now()` is the TRANSACTION timestamp, so every statement in one transaction stamps the same
  -- instant. That is the right unit: a client sees a transaction's effects, not its statements, and
  -- any run whose `run_at` is later than this covers all of them. It is also what
  -- `fn_close_preferences` (0018) and `recommendation_runs.run_at` use, so the three are comparable.
  v_stale_at timestamptz := now();
  v_event_ids uuid[];
  v_event_id uuid;
begin
  -- The transition tables, reduced to DISTINCT events. This is the whole reason the trigger is
  -- statement-level: a ten-row insert (which is exactly what `seed.sql` does) lands here once, with
  -- ten rows naming one event, and leaves one stamp and one message behind.
  if tg_op = 'INSERT' then
    select array_agg(distinct r.event_id) into v_event_ids from new_rows r;
  elsif tg_op = 'UPDATE' then
    -- Both sides. Nothing in this schema moves a constraint between events today, but if anything
    -- ever did then two events changed and both are owed a recompute; reading only `new_rows` would
    -- leave the abandoned event showing a number that still counts a requirement it no longer has.
    select array_agg(distinct r.event_id) into v_event_ids
    from (select event_id from new_rows union select event_id from old_rows) r;
  else
    select array_agg(distinct r.event_id) into v_event_ids from old_rows r;
  end if;

  foreach v_event_id in array coalesce(v_event_ids, array[]::uuid[])
  loop
    update public.events e
       set feasibility_stale_at = v_stale_at
     where e.id = v_event_id;

    -- Nothing to stamp means the event itself is gone: `participant_constraints.event_id` is
    -- `on delete cascade`, so deleting an event fires this trigger for its children after the
    -- parent row has already been removed. There is nobody left to notify either — the Realtime
    -- Authorization policy (0004) admits participants of the event, and those cascaded too.
    if not found then continue; end if;

    perform realtime.send(
      jsonb_build_object('event_id', v_event_id, 'stale_at', v_stale_at),
      'feasibility_stale',
      'event-' || v_event_id::text,
      true);
  end loop;

  -- No recompute, and no `recommendation_runs` insert. See reasons 1-4 in the header: this function
  -- exists so that the recompute stays somewhere a burst can be coalesced first.
  --
  -- The return value of an AFTER STATEMENT trigger is ignored.
  return null;
end; $$;

-- One trigger per operation, because transition tables forbid combining them (header, section
-- "STATEMENT-LEVEL"). All three name the transition tables identically so the one function can be
-- shared.
drop trigger if exists trg_mark_feasibility_stale_insert on public.participant_constraints;
create trigger trg_mark_feasibility_stale_insert
  after insert on public.participant_constraints
  referencing new table as new_rows
  for each statement execute function public.fn_mark_feasibility_stale();

drop trigger if exists trg_mark_feasibility_stale_update on public.participant_constraints;
create trigger trg_mark_feasibility_stale_update
  after update on public.participant_constraints
  referencing new table as new_rows old table as old_rows
  for each statement execute function public.fn_mark_feasibility_stale();

-- DELETE is granted to no API role (0024) and has no policy, so today this fires only for direct
-- SQL and for the cascade from `events`. It is here because the alternative is a schema where
-- removing a requirement leaves the dashboard confidently wrong, and because a delete that
-- loosens the MUSTs is the case where a stale count is most likely to be believed.
drop trigger if exists trg_mark_feasibility_stale_delete on public.participant_constraints;
create trigger trg_mark_feasibility_stale_delete
  after delete on public.participant_constraints
  referencing old table as old_rows
  for each statement execute function public.fn_mark_feasibility_stale();

-- ---------------------------------------------------------------------------
-- C. Grants
-- ---------------------------------------------------------------------------
--
-- 0024's rule is that whatever a client must read needs an explicit grant. The new column needs
-- none of its own: this schema uses no column-level privileges, and `grant select on table
-- public.events to authenticated` (0024) covers every column of that table, present and future,
-- narrowed to the caller's own events by the "event visible to its participants" policy
-- (0002/0007). Stated rather than assumed, because 0024 exists precisely because inherited
-- privileges hid a hole for twenty-three migrations. `service_role` already holds select+update
-- there (0024), which the fixture bootstrap needs and this column does not change.
--
-- The trigger function follows `fn_derive_constraint_metadata` (0018) exactly: `execute` is checked
-- against the role that fires the trigger, so `authenticated` needs it for a participant's own
-- INSERT to succeed, and `anon` — which this app never uses for a table write — does not.
-- Calling it directly is not a way in: a trigger function invoked as a plain function raises
-- immediately, and it takes no arguments through which an event could be named.
revoke execute on function public.fn_mark_feasibility_stale() from public, anon;
grant execute on function public.fn_mark_feasibility_stale() to authenticated, service_role;
