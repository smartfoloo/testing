-- Apply the post-0006 feasibility/negotiation definitions to projects that
-- already recorded 0005 and 0006 before this review branch existed.

create or replace function public.fn_candidate_is_feasible(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_candidate record; v_must record; v_value jsonb;
begin
  select rf.* into v_candidate from public.restaurant_features rf
  where rf.place_id = p_place_id;
  if not found then return false; end if;
  for v_must in
    select pc.id, pc.participant_id, pc.normalized_type, pc.normalized_value
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST'
  loop
    v_value := case when v_must.id = p_override_constraint_id
      then p_override_value else v_must.normalized_value end;
    if v_must.normalized_type = 'budget' then
      if v_candidate.price_yen_estimate is null
        or v_candidate.price_yen_estimate > (v_value->>'max_yen')::int
      then return false; end if;
    elsif v_must.normalized_type = 'room' then
      if v_candidate.room_type is distinct from (v_value->>'room')
      then return false; end if;
    elsif v_must.normalized_type = 'dietary' then
      if jsonb_typeof(v_value->'tags') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'tags'), 0) = 0
        or coalesce(array_length(v_candidate.dietary_tags, 1), 0) = 0
        or not (v_candidate.dietary_tags @> array(
          select jsonb_array_elements_text(v_value->'tags')))
      then return false; end if;
    elsif v_must.normalized_type = 'allergy' then
      if jsonb_typeof(v_value->'allergens') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'allergens'), 0) = 0
        or coalesce(array_length(v_candidate.allergy_safe_tags, 1), 0) = 0
        or not (v_candidate.allergy_safe_tags @> array(
          select allergen || '_free' from jsonb_array_elements_text(
            v_value->'allergens') as allergen))
      then return false; end if;
    elsif v_must.normalized_type = 'travel_time' then
      if coalesce((v_candidate.travel_minutes_by_participant
        ->> v_must.participant_id::text)::int, 9999)
        > (v_value->>'max_minutes')::int
      then return false; end if;
    end if;
  end loop;
  return true;
end; $$;

create or replace function public.fn_score_feasible_candidates(
  p_run_id uuid, p_event_id uuid
) returns void language plpgsql security definer set search_path = '' as $$
declare v_want_count int;
begin
  select count(*) into v_want_count from public.participant_constraints
  where event_id = p_event_id and kind = 'WANT';
  insert into public.recommendation_scores
    (run_id, restaurant_place_id, fairness_score, satisfaction_score,
     quality_score, explanation)
  select p_run_id, c.place_id,
    round(1.0 / (1.0 + coalesce(c.travel_max - c.travel_min, 0)), 4),
    case when v_want_count = 0 then 1
      else round(c.wants_matched::numeric / v_want_count, 4) end,
    round(least(coalesce(array_length(c.atmosphere_tags, 1), 0), 3) / 3.0, 4),
    null
  from (
    select rf.place_id, rf.atmosphere_tags,
      (select count(*) from public.participant_constraints pc
       where pc.event_id = p_event_id and pc.kind = 'WANT'
       and (
         (pc.normalized_type = 'cuisine'
          and ((
            coalesce(jsonb_array_length(pc.normalized_value->'include'), 0) = 0
            or coalesce(rf.cuisine_tags, '{}'::text[]) && array(
              select jsonb_array_elements_text(pc.normalized_value->'include'))
          ) and not (
            coalesce(rf.cuisine_tags, '{}'::text[]) && array(
              select jsonb_array_elements_text(pc.normalized_value->'exclude'))
          )))
         or
         (pc.normalized_type = 'atmosphere'
          and coalesce(rf.atmosphere_tags, '{}'::text[]) && array(
            select jsonb_array_elements_text(pc.normalized_value->'tags')))
       )) as wants_matched,
      (select max(v.value::int) from jsonb_each_text(
        rf.travel_minutes_by_participant) v) as travel_max,
      (select min(v.value::int) from jsonb_each_text(
        rf.travel_minutes_by_participant) v) as travel_min
    from public.restaurants r
    join public.restaurant_features rf on rf.place_id = r.place_id
    where public.fn_candidate_is_feasible(p_event_id, r.place_id)
  ) c
  order by c.wants_matched desc, c.place_id limit 5;

  update public.recommendation_scores s set label = 'fairest'
  where s.id = (select id from public.recommendation_scores
    where run_id = p_run_id and label is null
    order by fairness_score desc, restaurant_place_id limit 1);
  update public.recommendation_scores s set label = 'best_access'
  where s.id = (select rs.id from public.recommendation_scores rs
    join public.restaurant_features rf on rf.place_id = rs.restaurant_place_id
    where rs.run_id = p_run_id and rs.label is null
    order by (select avg(v.value::int) from jsonb_each_text(
      rf.travel_minutes_by_participant) v) asc nulls last, rs.restaurant_place_id limit 1);
  update public.recommendation_scores s set label = 'best_value'
  where s.id = (select rs.id from public.recommendation_scores rs
    join public.restaurant_features rf on rf.place_id = rs.restaurant_place_id
    where rs.run_id = p_run_id and rs.label is null
    order by rf.price_yen_estimate asc nulls last, rs.restaurant_place_id limit 1);
  update public.recommendation_scores s set label = 'best_experience'
  where s.id = (select id from public.recommendation_scores
    where run_id = p_run_id and label is null
    order by quality_score desc, restaurant_place_id limit 1);
  update public.recommendation_scores s set label = 'crowd_pleaser'
  where s.id = (select id from public.recommendation_scores
    where run_id = p_run_id and label is null
    order by satisfaction_score desc, restaurant_place_id limit 1);
end; $$;

create or replace function public.fn_recompute_feasibility(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run_id uuid; v_feasible_count int := 0; v_candidate record;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and auth.uid() is not null and not exists (
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
    and auth.uid() is not null and not exists (
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
    and auth.uid() is not null and not exists (
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

create or replace function public.fn_respond_negotiation(
  p_negotiation_id uuid, p_accept boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_neg public.negotiations%rowtype; v_caller_participant_id uuid;
  v_result jsonb;
begin
  select * into v_neg from public.negotiations where id = p_negotiation_id;
  if not found then raise exception 'negotiation not found'; end if;
  select id into v_caller_participant_id from public.participants
  where auth_user_id = auth.uid() and event_id = v_neg.event_id;
  if v_neg.participant_id is distinct from v_caller_participant_id
  then raise exception 'not authorized to respond to this negotiation'; end if;
  if v_neg.status <> 'PROPOSED'
  then raise exception 'negotiation already resolved'; end if;
  if p_accept then
    update public.participant_constraints set normalized_value = v_neg.proposed_value,
      updated_at = now() where id = v_neg.constraint_id;
    update public.negotiations set status = 'ACCEPTED', responded_at = now()
      where id = p_negotiation_id;
    v_result := public.fn_recompute_feasibility(v_neg.event_id);
  else
    update public.negotiations set status = 'REJECTED', responded_at = now()
      where id = p_negotiation_id;
    select jsonb_build_object('feasible_count', feasible_count) into v_result
    from public.recommendation_runs where event_id = v_neg.event_id
    order by run_at desc limit 1;
  end if;
  return v_result;
end; $$;

create or replace function public.fn_broadcast_run_change()
returns trigger security definer language plpgsql set search_path = '' as $$
begin
  perform realtime.send(
    jsonb_build_object('feasible_count', new.feasible_count, 'run_id', new.id),
    'run_updated', 'event-' || new.event_id::text, true);
  return new;
end; $$;

create or replace function public.fn_get_response_count(p_event_id uuid)
returns int language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.participants
    where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;
  return (select count(*) from public.participant_constraints
    where event_id = p_event_id);
end; $$;

create or replace function public.fn_get_pending_negotiation_count(p_event_id uuid)
returns int language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.participants
    where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;
  return (select count(*) from public.negotiations
    where event_id = p_event_id and status = 'PROPOSED');
end; $$;

create or replace function public.fn_my_event_ids()
returns setof uuid language sql security definer stable set search_path = '' as $$
  select event_id from public.participants where auth_user_id = auth.uid();
$$;

revoke execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid)
  from public, anon, authenticated;
