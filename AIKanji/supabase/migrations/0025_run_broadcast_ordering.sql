-- 0025: a `run_updated` broadcast says WHEN it happened, so a client can ignore an older one.
--
-- Observed against a real stack, not theorised: with `recommendation_runs` empty for the demo
-- event, an organizer who had just opened her dashboard saw the 「条件を満たすお店」 tile render
-- a stale count seconds after subscribing — from a `realtime.messages` row written 21 seconds
-- earlier by a different run. Nothing was re-fetched; the number came off the socket.
--
-- Why a client cannot currently defend itself. Realtime replays what is in the topic, and the
-- payload was `{feasible_count, run_id}` — two values with no order between them. A client
-- holding run B and handed run A has no way to tell which is newer: `run_id` is a random uuid,
-- and the count itself is not monotonic (accepting a relaxation raises it, a new MUST lowers
-- it). So every arriving message had to be treated as current, and the most recent thing on
-- the wire won regardless of when it happened.
--
-- The fix is the smallest one that makes ordering possible: send the run's own `run_at`. It is
-- already the column every other read orders by (`order by run_at desc limit 1`), so the wire
-- and the table now agree on what "latest" means, and a client can drop anything not newer
-- than what it is already showing.
--
-- ADDITIVE, deliberately. `feasible_count` and `run_id` keep their names and meanings, because
-- both clients decode this payload and an older build must keep working — it simply cannot
-- order, which is exactly where it is today. A client that does not know `run_at` is no worse
-- off than before this migration.
--
-- Not solved here, and worth stating: this orders the pushes a client receives, it does not
-- stop Realtime replaying history. A client that subscribes and immediately receives a
-- 40-minute-old run still learns of it — but it now learns of it in order, and if it has
-- already fetched something newer (which `latestRun()` does on mount) the stale push is
-- discarded instead of overwriting the screen.

create or replace function public.fn_broadcast_run_change()
returns trigger security definer language plpgsql set search_path = '' as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'feasible_count', new.feasible_count,
      'run_id', new.id,
      -- The run's own timestamp, not now(): a client compares it against the `run_at` of the
      -- run it is displaying, so both sides must be the same clock reading for the same run.
      'run_at', new.run_at),
    'run_updated', 'event-' || new.event_id::text, true);
  return new;
end; $$;

-- The trigger itself is unchanged (0006 created it, 0009 redefined only the function), so it
-- keeps pointing at this definition. Restated here as documentation of what fires it, not as a
-- change: `after insert on recommendation_runs`.
