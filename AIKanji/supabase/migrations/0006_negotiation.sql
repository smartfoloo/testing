-- 0006_negotiation.sql
-- Participant-side negotiation response plus aggregate-only RPCs.

create or replace function public.fn_respond_negotiation(
  p_negotiation_id uuid,
  p_accept boolean
)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_neg public.negotiations%rowtype;
  v_caller_participant_id uuid;
  v_result jsonb;
begin
  select * into v_neg
  from public.negotiations
  where id = p_negotiation_id;
  if not found then
    raise exception 'negotiation not found';
  end if;

  select id into v_caller_participant_id
  from public.participants
  where auth_user_id = auth.uid() and event_id = v_neg.event_id;

  if v_neg.participant_id is distinct from v_caller_participant_id then
    raise exception 'not authorized to respond to this negotiation';
  end if;
  if v_neg.status <> 'PROPOSED' then
    raise exception 'negotiation already resolved';
  end if;

  if p_accept then
    update public.participant_constraints
      set normalized_value = v_neg.proposed_value, updated_at = now()
      where id = v_neg.constraint_id;
    update public.negotiations
      set status = 'ACCEPTED', responded_at = now()
      where id = p_negotiation_id;
    v_result := public.fn_recompute_feasibility(v_neg.event_id);
  else
    update public.negotiations
      set status = 'REJECTED', responded_at = now()
      where id = p_negotiation_id;
    select jsonb_build_object('feasible_count', feasible_count) into v_result
      from public.recommendation_runs
      where event_id = v_neg.event_id
      order by run_at desc
      limit 1;
  end if;

  return v_result;
end; $$;

create or replace function public.fn_broadcast_run_change()
returns trigger
security definer
language plpgsql
set search_path = ''
as $$
begin
  perform realtime.send(
    jsonb_build_object('feasible_count', new.feasible_count, 'run_id', new.id),
    'run_updated', 'event-' || new.event_id::text, true
  );
  return new;
end; $$;

drop trigger if exists trg_broadcast_run on public.recommendation_runs;
create trigger trg_broadcast_run
  after insert on public.recommendation_runs
  for each row execute function public.fn_broadcast_run_change();

create or replace function public.fn_get_response_count(p_event_id uuid)
returns int
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.participants
    where event_id = p_event_id and auth_user_id = auth.uid()
  ) then
    raise exception 'not a participant of this event';
  end if;

  return (select count(*) from public.participant_constraints
          where event_id = p_event_id);
end; $$;

create or replace function public.fn_get_pending_negotiation_count(p_event_id uuid)
returns int
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.participants
    where event_id = p_event_id and auth_user_id = auth.uid()
  ) then
    raise exception 'not a participant of this event';
  end if;

  return (select count(*) from public.negotiations
          where event_id = p_event_id and status = 'PROPOSED');
end; $$;

create or replace function public.fn_my_event_ids()
returns setof uuid
language sql security definer stable
set search_path = ''
as $$
  select event_id
  from public.participants
  where auth_user_id = auth.uid();
$$;

drop policy if exists "participant reads own event membership list"
  on public.participants;

create policy "participant reads own event membership list"
  on public.participants for select
  using (event_id in (select public.fn_my_event_ids()));
