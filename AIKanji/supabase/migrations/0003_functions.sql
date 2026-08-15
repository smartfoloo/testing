create or replace function fn_create_event(p_name text, p_objective text default 'balanced')
returns jsonb
language plpgsql security definer as $$
declare
  v_id uuid;
  v_code text;
begin
  insert into events (name, objective) values (p_name, p_objective)
  returning id, invite_code into v_id, v_code;
  return jsonb_build_object('event_id', v_id, 'invite_code', v_code);
end; $$;

create or replace function fn_join_event(
  p_invite_code text,
  p_display_name text,
  p_travel_reference text,
  p_travel_reference_place_id text default null
) returns uuid
language plpgsql security definer as $$
declare
  v_event_id uuid;
  v_participant_id uuid;
  v_is_first boolean;
begin
  select id into v_event_id from events where invite_code = p_invite_code;
  if v_event_id is null then
    raise exception 'invalid invite code';
  end if;

  select not exists(select 1 from participants where event_id = v_event_id) into v_is_first;

  insert into participants (event_id, auth_user_id, display_name, role, travel_reference, travel_reference_place_id)
  values (v_event_id, auth.uid(), p_display_name,
          case when v_is_first then 'organizer' else 'participant' end,
          p_travel_reference, p_travel_reference_place_id)
  returning id into v_participant_id;

  if v_is_first then
    update events set organizer_participant_id = v_participant_id where id = v_event_id;
  end if;

  return v_participant_id;
end; $$;
