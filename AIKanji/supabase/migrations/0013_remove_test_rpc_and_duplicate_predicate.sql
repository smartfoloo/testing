drop function if exists public.fn_create_event(text);

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
