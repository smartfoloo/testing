-- 0005_feasibility.sql
-- Deterministic feasibility, scoring, and relaxation-negotiation engine.
-- The LLM never decides feasibility or which MUST gets relaxed: all of it is SQL.

-- Shared MUST-check. p_override_constraint_id/p_override_value evaluate one
-- constraint as if its normalized_value were replaced (used by relaxation
-- what-if counting; writes nothing).
create or replace function fn_candidate_is_feasible(
  p_event_id uuid,
  p_place_id text,
  p_override_constraint_id uuid default null,
  p_override_value jsonb default null
)
returns boolean
language plpgsql security definer as $$
declare
  v_candidate record;
  v_must record;
  v_value jsonb;
begin
  select rf.* into v_candidate
  from restaurant_features rf
  where rf.place_id = p_place_id;
  if not found then
    return false;
  end if;

  for v_must in
    select pc.id, pc.participant_id, pc.normalized_type, pc.normalized_value
    from participant_constraints pc
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
      if not (coalesce(v_candidate.dietary_tags, '{}') @> array[v_value->>'diet'])
      then return false; end if;

    elsif v_must.normalized_type = 'allergy' then
      if not (coalesce(v_candidate.allergy_safe_tags, '{}')
              @> array[(v_value->>'allergen') || '_free'])
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

create or replace function fn_score_feasible_candidates(p_run_id uuid, p_event_id uuid)
returns void
language plpgsql security definer as $$
declare
  v_want_count int;
begin
  select count(*) into v_want_count
  from participant_constraints
  where event_id = p_event_id and kind = 'WANT';

  -- One row per feasible candidate (max 5, best satisfaction first).
  -- satisfaction: fraction of WANT rows matched via cuisine/atmosphere overlap.
  -- fairness: 1 / (1 + spread of travel minutes) — lower spread is fairer.
  -- quality: richness of the stored experience signal (atmosphere tags, capped).
  insert into recommendation_scores
    (run_id, restaurant_place_id, fairness_score, satisfaction_score, quality_score, explanation)
  select
    p_run_id,
    c.place_id,
    round(1.0 / (1.0 + coalesce(c.travel_max - c.travel_min, 0)), 4),
    case when v_want_count = 0 then 1
         else round(c.wants_matched::numeric / v_want_count, 4) end,
    round(least(coalesce(array_length(c.atmosphere_tags, 1), 0), 3) / 3.0, 4),
    'pending'
  from (
    select
      rf.place_id,
      rf.atmosphere_tags,
      (select count(*)
       from participant_constraints pc
       where pc.event_id = p_event_id and pc.kind = 'WANT'
         and ((pc.normalized_type = 'cuisine'
               and coalesce(rf.cuisine_tags, '{}') @> array[pc.normalized_value->>'cuisine'])
           or (pc.normalized_type = 'atmosphere'
               and coalesce(rf.atmosphere_tags, '{}') @> array[pc.normalized_value->>'atmosphere']))
      ) as wants_matched,
      (select max(v.value::int) from jsonb_each_text(rf.travel_minutes_by_participant) v) as travel_max,
      (select min(v.value::int) from jsonb_each_text(rf.travel_minutes_by_participant) v) as travel_min
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
    where fn_candidate_is_feasible(p_event_id, r.place_id)
  ) c
  order by c.wants_matched desc, c.place_id
  limit 5;

  -- Assign each label to the best still-unlabeled row under its metric,
  -- so labels spread across candidates instead of stacking on one row.
  update recommendation_scores s set label = 'fairest'
  where s.id = (select id from recommendation_scores
                where run_id = p_run_id and label is null
                order by fairness_score desc, restaurant_place_id limit 1);

  update recommendation_scores s set label = 'best_access'
  where s.id = (
    select rs.id from recommendation_scores rs
    join restaurant_features rf on rf.place_id = rs.restaurant_place_id
    where rs.run_id = p_run_id and rs.label is null
    order by (select avg(v.value::int)
              from jsonb_each_text(rf.travel_minutes_by_participant) v) asc nulls last,
             rs.restaurant_place_id
    limit 1);

  update recommendation_scores s set label = 'best_value'
  where s.id = (
    select rs.id from recommendation_scores rs
    join restaurant_features rf on rf.place_id = rs.restaurant_place_id
    where rs.run_id = p_run_id and rs.label is null
    order by rf.price_yen_estimate asc nulls last, rs.restaurant_place_id
    limit 1);

  update recommendation_scores s set label = 'best_experience'
  where s.id = (select id from recommendation_scores
                where run_id = p_run_id and label is null
                order by quality_score desc, restaurant_place_id limit 1);

  update recommendation_scores s set label = 'crowd_pleaser'
  where s.id = (select id from recommendation_scores
                where run_id = p_run_id and label is null
                order by satisfaction_score desc, restaurant_place_id limit 1);
end; $$;

create or replace function fn_recompute_feasibility(p_event_id uuid)
returns jsonb
language plpgsql security definer as $$
declare
  v_run_id uuid;
  v_feasible_count int := 0;
  v_musts record;
  v_candidate record;
  v_ok boolean;
begin
  for v_candidate in
    select r.place_id, rf.* from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
  loop
    v_ok := true;
    for v_musts in
      select pc.participant_id, pc.normalized_type, pc.normalized_value
      from participant_constraints pc
      where pc.event_id = p_event_id and pc.kind = 'MUST'
    loop
      if v_musts.normalized_type = 'budget' then
        if v_candidate.price_yen_estimate is null
           or v_candidate.price_yen_estimate > (v_musts.normalized_value->>'max_yen')::int
        then v_ok := false; end if;

      elsif v_musts.normalized_type = 'room' then
        if v_candidate.room_type is distinct from (v_musts.normalized_value->>'room')
        then v_ok := false; end if;

      elsif v_musts.normalized_type = 'dietary' then
        if not (coalesce(v_candidate.dietary_tags, '{}') @> array[v_musts.normalized_value->>'diet'])
        then v_ok := false; end if;

      elsif v_musts.normalized_type = 'allergy' then
        if not (coalesce(v_candidate.allergy_safe_tags, '{}')
                @> array[(v_musts.normalized_value->>'allergen') || '_free'])
        then v_ok := false; end if;

      elsif v_musts.normalized_type = 'travel_time' then
        if coalesce((v_candidate.travel_minutes_by_participant
                     ->> v_musts.participant_id::text)::int, 9999)
           > (v_musts.normalized_value->>'max_minutes')::int
        then v_ok := false; end if;
      end if;

      exit when not v_ok;
    end loop;

    if v_ok then v_feasible_count := v_feasible_count + 1; end if;
  end loop;

  insert into recommendation_runs (event_id, feasible_count, input_snapshot)
  values (p_event_id, v_feasible_count,
          jsonb_build_object('must_count',
            (select count(*) from participant_constraints
             where event_id = p_event_id and kind = 'MUST')))
  returning id into v_run_id;

  if v_feasible_count > 0 then
    perform fn_score_feasible_candidates(v_run_id, p_event_id);
  end if;

  return jsonb_build_object('run_id', v_run_id, 'feasible_count', v_feasible_count);
end; $$;

-- What-if: feasible-count delta if one constraint is relaxed one step.
-- Pure computation, writes nothing.
create or replace function fn_count_unlocked_if_relaxed(p_event_id uuid, p_constraint_id uuid)
returns int
language plpgsql security definer as $$
declare
  v_constraint record;
  v_relaxed jsonb;
  v_baseline int;
  v_relaxed_count int;
begin
  select pc.normalized_type, pc.normalized_value into v_constraint
  from participant_constraints pc
  where pc.id = p_constraint_id and pc.event_id = p_event_id;
  if not found then
    raise exception 'constraint % not found for event %', p_constraint_id, p_event_id;
  end if;

  v_relaxed := case v_constraint.normalized_type
    when 'room' then jsonb_build_object('room', 'semi_private')
    when 'travel_time' then jsonb_build_object('max_minutes',
      (v_constraint.normalized_value->>'max_minutes')::int + 10)
    when 'budget' then jsonb_build_object('max_yen',
      (v_constraint.normalized_value->>'max_yen')::int + 500)
    else v_constraint.normalized_value
  end;

  select
    count(*) filter (where fn_candidate_is_feasible(p_event_id, r.place_id)),
    count(*) filter (where fn_candidate_is_feasible(p_event_id, r.place_id,
                                                    p_constraint_id, v_relaxed))
  into v_baseline, v_relaxed_count
  from restaurants r
  join restaurant_features rf on rf.place_id = r.place_id;

  return v_relaxed_count - v_baseline;
end; $$;

create or replace function fn_propose_relaxation(p_event_id uuid)
returns uuid
language plpgsql security definer as $$
declare
  v_negotiation_id uuid;
  v_candidate record;
  v_best_constraint record;
  v_best_unlocked int := -1;
  v_unlocked int;
begin
  -- SAFETY RULE — hardcoded, not a parameter, not read from any client-writable table:
  -- allergy / dietary / accessibility MUSTs are NEVER eligible for relaxation, no exceptions.
  for v_candidate in
    select pc.id as constraint_id, pc.participant_id, pc.normalized_type, pc.normalized_value
    from participant_constraints pc
    where pc.event_id = p_event_id
      and pc.kind = 'MUST'
      and pc.normalized_type not in ('allergy','dietary','accessibility')
  loop
    v_unlocked := fn_count_unlocked_if_relaxed(p_event_id, v_candidate.constraint_id);
    if v_unlocked > v_best_unlocked then
      v_best_unlocked := v_unlocked;
      v_best_constraint := v_candidate;
    end if;
  end loop;

  if v_best_unlocked <= 0 then
    return null; -- nothing eligible unlocks anything; hand off to the human 幹事, do not force a proposal
  end if;

  insert into negotiations (event_id, constraint_id, participant_id, proposed_value, unlocked_count)
  values (
    p_event_id, v_best_constraint.constraint_id, v_best_constraint.participant_id,
    case v_best_constraint.normalized_type
      when 'room' then jsonb_build_object('room','semi_private')
      when 'travel_time' then jsonb_build_object('max_minutes',
        (v_best_constraint.normalized_value->>'max_minutes')::int + 10)
      when 'budget' then jsonb_build_object('max_yen',
        (v_best_constraint.normalized_value->>'max_yen')::int + 500)
      else v_best_constraint.normalized_value
    end,
    v_best_unlocked
  )
  returning id into v_negotiation_id;

  return v_negotiation_id;
end; $$;
