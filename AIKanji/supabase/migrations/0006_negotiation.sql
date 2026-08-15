-- 0006_negotiation.sql
-- Participant-side negotiation response plus the aggregate-only RPCs the organizer
-- dashboard is allowed to read. Nothing here ever returns a negotiation's
-- participant_id or constraint_id to anyone but the targeted participant.

create or replace function fn_respond_negotiation(p_negotiation_id uuid, p_accept boolean)
returns jsonb
language plpgsql security definer as $$
declare
  v_neg negotiations%rowtype;
  v_caller_participant_id uuid;
  v_result jsonb;
begin
  select * into v_neg from negotiations where id = p_negotiation_id;
  if not found then
    raise exception 'negotiation not found';
  end if;

  select id into v_caller_participant_id from participants
    where auth_user_id = auth.uid() and event_id = v_neg.event_id;

  if v_neg.participant_id is distinct from v_caller_participant_id then
    raise exception 'not authorized to respond to this negotiation';
  end if;
  if v_neg.status <> 'PROPOSED' then
    raise exception 'negotiation already resolved';
  end if;

  if p_accept then
    update participant_constraints
      set normalized_value = v_neg.proposed_value, updated_at = now()
      where id = v_neg.constraint_id;
    update negotiations set status = 'ACCEPTED', responded_at = now() where id = p_negotiation_id;
    v_result := fn_recompute_feasibility(v_neg.event_id);
  else
    update negotiations set status = 'REJECTED', responded_at = now() where id = p_negotiation_id;
    select jsonb_build_object('feasible_count', feasible_count) into v_result
      from recommendation_runs where event_id = v_neg.event_id order by run_at desc limit 1;
  end if;

  return v_result;
end; $$;

-- Live dashboard updates on the same private topic as prompt 2's constraint feed,
-- so no additional realtime authorization policy is needed.
create or replace function fn_broadcast_run_change()
returns trigger security definer language plpgsql as $$
begin
  perform realtime.send(
    jsonb_build_object('feasible_count', new.feasible_count, 'run_id', new.id),
    'run_updated', 'event-' || new.event_id::text, true
  );
  return new;
end; $$;

create trigger trg_broadcast_run
  after insert on recommendation_runs
  for each row execute function fn_broadcast_run_change();

-- Aggregates for the organizer. RLS hides other participants' constraint and
-- negotiation rows, and these deliberately return a bare count rather than
-- anything that identifies who submitted or who is negotiating.
create or replace function fn_get_response_count(p_event_id uuid)
returns int
language plpgsql security definer as $$
begin
  if not exists (
    select 1 from participants where event_id = p_event_id and auth_user_id = auth.uid()
  ) then
    raise exception 'not a participant of this event';
  end if;

  return (select count(*) from participant_constraints where event_id = p_event_id);
end; $$;

create or replace function fn_get_pending_negotiation_count(p_event_id uuid)
returns int
language plpgsql security definer as $$
begin
  if not exists (
    select 1 from participants where event_id = p_event_id and auth_user_id = auth.uid()
  ) then
    raise exception 'not a participant of this event';
  end if;

  return (select count(*) from negotiations
          where event_id = p_event_id and status = 'PROPOSED');
end; $$;

-- The membership policy from 0002 queried `participants` from inside a policy on
-- `participants`, which Postgres rejects as infinite recursion — that made every
-- participant-scoped read (including a participant's own negotiations) fail. The
-- lookup has to happen in a definer function so the inner read skips RLS.
create or replace function fn_my_event_ids()
returns setof uuid
language sql security definer stable as $$
  select event_id from participants where auth_user_id = auth.uid();
$$;

drop policy if exists "participant reads own event membership list" on participants;

create policy "participant reads own event membership list"
  on participants for select
  using (event_id in (select fn_my_event_ids()));
