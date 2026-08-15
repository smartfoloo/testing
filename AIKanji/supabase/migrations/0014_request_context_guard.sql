-- Keep API callers behind event membership while allowing direct database
-- sessions used by migrations and the backend SQL harness.

create or replace function public.fn_recompute_feasibility(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run_id uuid; v_feasible_count int := 0; v_candidate record;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;
  for v_candidate in
    select r.place_id from public.restaurants r
    join public.restaurant_features rf on rf.place_id = r.place_id
    order by r.place_id
  loop
    if public.fn_candidate_is_feasible(p_event_id, v_candidate.place_id)
    then v_feasible_count := v_feasible_count + 1; end if;
  end loop;
  insert into public.recommendation_runs (event_id, feasible_count, input_snapshot)
  values (p_event_id, v_feasible_count, jsonb_build_object('must_count',
    (select count(*) from public.participant_constraints
     where event_id = p_event_id and kind = 'MUST')))
  returning id into v_run_id;
  if v_feasible_count > 0
  then perform public.fn_score_feasible_candidates(v_run_id, p_event_id); end if;
  return jsonb_build_object('run_id', v_run_id, 'feasible_count', v_feasible_count);
end; $$;

create or replace function public.fn_count_unlocked_if_relaxed(
  p_event_id uuid, p_constraint_id uuid
) returns int language plpgsql security definer set search_path = '' as $$
declare v_constraint record; v_relaxed jsonb; v_baseline int; v_relaxed_count int;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;
  select pc.normalized_type, pc.normalized_value into v_constraint
  from public.participant_constraints pc
  where pc.id = p_constraint_id and pc.event_id = p_event_id;
  if not found then raise exception 'constraint not found'; end if;
  v_relaxed := case v_constraint.normalized_type
    when 'room' then jsonb_build_object('room', 'semi_private')
    when 'travel_time' then jsonb_build_object('max_minutes',
      (v_constraint.normalized_value->>'max_minutes')::int + 10)
    when 'budget' then jsonb_build_object('max_yen',
      (v_constraint.normalized_value->>'max_yen')::int + 500)
    else v_constraint.normalized_value end;
  select count(*) filter (where public.fn_candidate_is_feasible(p_event_id, r.place_id)),
    count(*) filter (where public.fn_candidate_is_feasible(
      p_event_id, r.place_id, p_constraint_id, v_relaxed))
  into v_baseline, v_relaxed_count
  from public.restaurants r
  join public.restaurant_features rf on rf.place_id = r.place_id;
  return v_relaxed_count - v_baseline;
end; $$;

create or replace function public.fn_propose_relaxation(p_event_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_negotiation_id uuid; v_candidate record; v_best_constraint record;
  v_best_unlocked int := -1; v_unlocked int;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;
  for v_candidate in
    select pc.id as constraint_id, pc.participant_id, pc.normalized_type,
      pc.normalized_value
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST'
      and pc.normalized_type not in ('allergy','dietary','accessibility')
    order by pc.id
  loop
    v_unlocked := public.fn_count_unlocked_if_relaxed(
      p_event_id, v_candidate.constraint_id);
    if v_unlocked > v_best_unlocked then
      v_best_unlocked := v_unlocked; v_best_constraint := v_candidate;
    end if;
  end loop;
  if v_best_unlocked <= 0 then return null; end if;
  insert into public.negotiations
    (event_id, constraint_id, participant_id, proposed_value, unlocked_count)
  values (p_event_id, v_best_constraint.constraint_id,
    v_best_constraint.participant_id,
    case v_best_constraint.normalized_type
      when 'room' then jsonb_build_object('room','semi_private')
      when 'travel_time' then jsonb_build_object('max_minutes',
        (v_best_constraint.normalized_value->>'max_minutes')::int + 10)
      when 'budget' then jsonb_build_object('max_yen',
        (v_best_constraint.normalized_value->>'max_yen')::int + 500)
      else v_best_constraint.normalized_value end, v_best_unlocked)
  returning id into v_negotiation_id;
  return v_negotiation_id;
end; $$;

revoke execute on function public.fn_recompute_feasibility(uuid) from public, anon;
revoke execute on function public.fn_propose_relaxation(uuid) from public, anon;
revoke execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.fn_recompute_feasibility(uuid)
  to authenticated, service_role;
grant execute on function public.fn_propose_relaxation(uuid)
  to authenticated, service_role;
grant execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid)
  to service_role;
revoke execute on function public.fn_get_response_count(uuid)
  from public, anon;
revoke execute on function public.fn_get_pending_negotiation_count(uuid)
  from public, anon;
grant execute on function public.fn_get_response_count(uuid)
  to authenticated, service_role;
grant execute on function public.fn_get_pending_negotiation_count(uuid)
  to authenticated, service_role;
