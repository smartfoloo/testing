alter table public.events
  add column if not exists scheduled_at timestamptz;

create table if not exists public.participant_origins (
  participant_id uuid primary key references public.participants(id) on delete cascade,
  label text not null check (char_length(pg_catalog.btrim(label)) between 2 and 160),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  updated_at timestamptz not null default now()
);

alter table public.participant_origins enable row level security;

revoke all on table public.participant_origins from anon, authenticated, service_role;
grant select on table public.participant_origins to authenticated, service_role;

drop policy if exists "participant reads own origin" on public.participant_origins;
create policy "participant reads own origin"
  on public.participant_origins for select to authenticated
  using (exists (
    select 1
    from public.participants p
    where p.id = participant_origins.participant_id
      and p.auth_user_id = (select auth.uid())
  ));

drop trigger if exists trg_touch_participant_origins on public.participant_origins;
create trigger trg_touch_participant_origins
  before update on public.participant_origins
  for each row execute function public.fn_touch_updated_at();

create or replace function public.fn_invalidate_participant_origin_cache()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_participant_id uuid;
  v_event_id uuid;
begin
  if tg_op = 'UPDATE'
     and new.label is not distinct from old.label
     and new.latitude is not distinct from old.latitude
     and new.longitude is not distinct from old.longitude
  then
    return new;
  end if;

  v_participant_id := case when tg_op = 'DELETE' then old.participant_id else new.participant_id end;
  select p.event_id into v_event_id
  from public.participants p
  where p.id = v_participant_id;

  if v_event_id is not null then
    delete from public.travel_matrix_cache tmc
    where tmc.event_id = v_event_id
      and tmc.participant_id = v_participant_id;
  end if;

  update public.restaurant_features rf
  set travel_minutes_by_participant = rf.travel_minutes_by_participant - v_participant_id::text
  where rf.travel_minutes_by_participant ? v_participant_id::text;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_invalidate_participant_origin_cache on public.participant_origins;
create trigger trg_invalidate_participant_origin_cache
  after insert or update or delete on public.participant_origins
  for each row execute function public.fn_invalidate_participant_origin_cache();

create or replace function public.fn_set_travel_reference(
  p_participant_id uuid,
  p_travel_reference text,
  p_travel_reference_place_id text default null
)
returns table (travel_reference text, travel_reference_place_id text)
language plpgsql security definer set search_path = '' as $$
declare
  v_event_id uuid;
  v_auth_user_id uuid;
  v_old_reference text;
  v_old_place_id text;
  v_new_place_id text;
begin
  if p_travel_reference is null
     or p_travel_reference not in ('office','home','station','doesnt_matter')
  then
    raise exception 'invalid travel reference: %', coalesce(p_travel_reference, 'null');
  end if;

  select p.event_id, p.auth_user_id, p.travel_reference, p.travel_reference_place_id
    into v_event_id, v_auth_user_id, v_old_reference, v_old_place_id
  from public.participants p
  where p.id = p_participant_id;

  if v_event_id is null then
    raise exception 'participant not found';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
     and v_auth_user_id is distinct from auth.uid()
  then
    raise exception 'not permitted to change another participant''s travel reference';
  end if;

  v_new_place_id := case
    when p_travel_reference = 'doesnt_matter' then null
    else nullif(pg_catalog.btrim(p_travel_reference_place_id), '')
  end;

  update public.participants p
  set travel_reference = p_travel_reference,
      travel_reference_place_id = v_new_place_id
  where p.id = p_participant_id;

  if p_travel_reference is distinct from v_old_reference
     or coalesce(v_new_place_id, '') is distinct from coalesce(v_old_place_id, '')
  then
    -- A coordinate supplement describes the old canonical origin. The v2 setter
    -- writes a replacement triple later in the same transaction when one was supplied.
    delete from public.participant_origins po
    where po.participant_id = p_participant_id;

    delete from public.travel_matrix_cache tmc
    where tmc.event_id = v_event_id
      and tmc.participant_id = p_participant_id;

    update public.restaurant_features rf
    set travel_minutes_by_participant = rf.travel_minutes_by_participant - p_participant_id::text
    where rf.travel_minutes_by_participant ? p_participant_id::text;
  end if;

  return query
  select p.travel_reference, p.travel_reference_place_id
  from public.participants p
  where p.id = p_participant_id;
end;
$$;

create or replace function public.fn_set_travel_reference_v2(
  p_participant_id uuid,
  p_travel_reference text,
  p_travel_reference_place_id text default null,
  p_origin_label text default null,
  p_origin_latitude double precision default null,
  p_origin_longitude double precision default null
)
returns table (
  travel_reference text,
  travel_reference_place_id text,
  origin_label text,
  origin_latitude double precision,
  origin_longitude double precision
)
language plpgsql security definer set search_path = '' as $$
declare
  v_coordinate_count int;
begin
  v_coordinate_count := (p_origin_label is not null)::int
                      + (p_origin_latitude is not null)::int
                      + (p_origin_longitude is not null)::int;
  if v_coordinate_count not in (0, 3) then
    raise exception 'origin label, latitude, and longitude must be provided together';
  end if;
  if v_coordinate_count = 3 then
    if char_length(pg_catalog.btrim(p_origin_label)) not between 2 and 160 then
      raise exception 'origin label must be between 2 and 160 characters';
    end if;
    if not (p_origin_latitude between -90 and 90) then
      raise exception 'origin latitude must be between -90 and 90';
    end if;
    if not (p_origin_longitude between -180 and 180) then
      raise exception 'origin longitude must be between -180 and 180';
    end if;
  end if;

  perform public.fn_set_travel_reference(
    p_participant_id, p_travel_reference, p_travel_reference_place_id);

  if v_coordinate_count = 3 then
    insert into public.participant_origins as po (
      participant_id, label, latitude, longitude, updated_at
    ) values (
      p_participant_id, pg_catalog.btrim(p_origin_label),
      p_origin_latitude, p_origin_longitude, now()
    )
    on conflict (participant_id) do update
      set label = excluded.label,
          latitude = excluded.latitude,
          longitude = excluded.longitude,
          updated_at = now();
  end if;

  return query
  select p.travel_reference, p.travel_reference_place_id,
         po.label, po.latitude, po.longitude
  from public.participants p
  left join public.participant_origins po on po.participant_id = p.id
  where p.id = p_participant_id;
end;
$$;

create or replace function public.fn_create_event_v2(
  p_name text,
  p_display_name text,
  p_scheduled_at timestamptz default null,
  p_origin_label text default null,
  p_origin_latitude double precision default null,
  p_origin_longitude double precision default null,
  p_objective text default 'balanced',
  p_travel_reference text default 'station',
  p_travel_reference_place_id text default null
)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_created jsonb;
  v_coordinate_count int;
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'authentication required';
  end if;
  if nullif(pg_catalog.btrim(p_name), '') is null then
    raise exception 'event name is required';
  end if;
  if nullif(pg_catalog.btrim(p_display_name), '') is null then
    raise exception 'display name is required';
  end if;
  if p_scheduled_at is not null
     and (not isfinite(p_scheduled_at)
          or p_scheduled_at <= now()
          or p_scheduled_at > now() + interval '5 years')
  then
    raise exception 'scheduled date must be in the future and within 5 years';
  end if;

  v_coordinate_count := (p_origin_label is not null)::int
                      + (p_origin_latitude is not null)::int
                      + (p_origin_longitude is not null)::int;
  if v_coordinate_count not in (0, 3) then
    raise exception 'origin label, latitude, and longitude must be provided together';
  end if;

  v_created := public.fn_create_event(
    pg_catalog.btrim(p_name), pg_catalog.btrim(p_display_name),
    p_travel_reference, p_travel_reference_place_id, p_objective);

  update public.events e
  set scheduled_at = p_scheduled_at
  where e.id = (v_created->>'event_id')::uuid;

  if v_coordinate_count = 3 then
    perform * from public.fn_set_travel_reference_v2(
      (v_created->>'participant_id')::uuid,
      p_travel_reference,
      p_travel_reference_place_id,
      p_origin_label,
      p_origin_latitude,
      p_origin_longitude);
  end if;

  return v_created;
end;
$$;

create or replace function public.fn_join_event_v2(
  p_invite_code text,
  p_display_name text,
  p_origin_label text default null,
  p_origin_latitude double precision default null,
  p_origin_longitude double precision default null,
  p_travel_reference text default 'station',
  p_travel_reference_place_id text default null
)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_participant_id uuid;
  v_coordinate_count int;
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'authentication required';
  end if;
  if nullif(pg_catalog.btrim(p_invite_code), '') is null then
    raise exception 'invite code is required';
  end if;
  if nullif(pg_catalog.btrim(p_display_name), '') is null then
    raise exception 'display name is required';
  end if;

  v_coordinate_count := (p_origin_label is not null)::int
                      + (p_origin_latitude is not null)::int
                      + (p_origin_longitude is not null)::int;
  if v_coordinate_count not in (0, 3) then
    raise exception 'origin label, latitude, and longitude must be provided together';
  end if;

  v_participant_id := public.fn_join_event(
    pg_catalog.btrim(p_invite_code), pg_catalog.btrim(p_display_name),
    p_travel_reference, p_travel_reference_place_id);

  if v_coordinate_count = 3 then
    perform * from public.fn_set_travel_reference_v2(
      v_participant_id,
      p_travel_reference,
      p_travel_reference_place_id,
      p_origin_label,
      p_origin_latitude,
      p_origin_longitude);
  else
    perform public.fn_set_travel_reference(
      v_participant_id, p_travel_reference, p_travel_reference_place_id);
  end if;

  return v_participant_id;
end;
$$;

create or replace function public.fn_preview_event_v2(p_invite_code text)
returns table (
  event_id uuid,
  name text,
  status text,
  scheduled_at timestamptz,
  participant_count bigint,
  organizer_display_name text
)
language plpgsql security definer stable set search_path = '' as $$
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'authentication required';
  end if;
  if nullif(pg_catalog.btrim(p_invite_code), '') is null then
    return;
  end if;

  return query
  select e.id, e.name, e.status, e.scheduled_at,
         (select count(*) from public.participants p where p.event_id = e.id),
         organizer.display_name
  from public.events e
  left join public.participants organizer on organizer.id = e.organizer_participant_id
  where e.invite_code = pg_catalog.btrim(p_invite_code);
end;
$$;

drop function if exists public.fn_get_my_events_v2();
create function public.fn_get_my_events_v2()
returns table (
  event_id uuid,
  name text,
  invite_code text,
  status text,
  scheduled_at timestamptz,
  participant_id uuid,
  role text,
  participant_count bigint,
  completed_count bigint,
  input_completed boolean,
  latest_run_id uuid,
  latest_run_at timestamptz,
  feasible_count int,
  chosen_place_id text,
  chosen_at timestamptz
)
language sql security definer stable set search_path = '' as $$
  select e.id, e.name, e.invite_code, e.status, e.scheduled_at,
         mine.id, mine.role,
         (select count(*) from public.participants p where p.event_id = e.id),
         (select count(*)
          from public.participants p
          where p.event_id = e.id
            and exists (
              select 1 from public.participant_constraints pc
              where pc.participant_id = p.id)),
         exists (
           select 1 from public.participant_constraints pc
           where pc.participant_id = mine.id),
         latest.id, latest.run_at, latest.feasible_count,
         e.chosen_place_id, e.chosen_at
  from public.participants mine
  join public.events e on e.id = mine.event_id
  left join lateral (
    select rr.id, rr.run_at, rr.feasible_count
    from public.recommendation_runs rr
    where rr.event_id = e.id
    order by rr.run_at desc, rr.id desc
    limit 1
  ) latest on true
  where mine.auth_user_id = auth.uid()
  order by e.scheduled_at desc nulls last, e.created_at desc, e.id;
$$;

create or replace function public.fn_get_event_progress_v2(p_event_id uuid)
returns table (
  participant_count bigint,
  completed_count bigint,
  input_completed boolean
)
language plpgsql security definer stable set search_path = '' as $$
declare
  v_participant_id uuid;
begin
  select p.id into v_participant_id
  from public.participants p
  where p.event_id = p_event_id
    and p.auth_user_id = auth.uid();

  if v_participant_id is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'not a participant of this event';
  end if;

  return query
  select
    (select count(*) from public.participants p where p.event_id = p_event_id),
    (select count(*)
     from public.participants p
     where p.event_id = p_event_id
       and exists (
         select 1 from public.participant_constraints pc
         where pc.participant_id = p.id)),
    coalesce(exists (
      select 1 from public.participant_constraints pc
      where pc.participant_id = v_participant_id), false);
end;
$$;

create or replace function public.fn_broadcast_event_progress_v2()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_event_id uuid;
  v_other_event_id uuid;
  v_participant_count bigint;
  v_completed_count bigint;
begin
  if tg_table_name = 'participants' then
    v_event_id := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
  else
    v_event_id := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
    if tg_op = 'UPDATE' and old.event_id is distinct from new.event_id then
      v_other_event_id := old.event_id;
    end if;
  end if;

  if v_event_id is not null then
    select count(*) into v_participant_count
    from public.participants p where p.event_id = v_event_id;
    select count(*) into v_completed_count
    from public.participants p
    where p.event_id = v_event_id
      and exists (
        select 1 from public.participant_constraints pc
        where pc.participant_id = p.id);
    perform realtime.send(
      jsonb_build_object(
        'participant_count', v_participant_count,
        'completed_count', v_completed_count),
      'event_progress_updated', 'event-' || v_event_id::text, true);
  end if;

  if v_other_event_id is not null then
    select count(*) into v_participant_count
    from public.participants p where p.event_id = v_other_event_id;
    select count(*) into v_completed_count
    from public.participants p
    where p.event_id = v_other_event_id
      and exists (
        select 1 from public.participant_constraints pc
        where pc.participant_id = p.id);
    perform realtime.send(
      jsonb_build_object(
        'participant_count', v_participant_count,
        'completed_count', v_completed_count),
      'event_progress_updated', 'event-' || v_other_event_id::text, true);
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists trg_broadcast_participant_progress_v2 on public.participants;
create trigger trg_broadcast_participant_progress_v2
  after insert or delete on public.participants
  for each row execute function public.fn_broadcast_event_progress_v2();

drop trigger if exists trg_broadcast_constraint_progress_v2 on public.participant_constraints;
create trigger trg_broadcast_constraint_progress_v2
  after insert or update or delete on public.participant_constraints
  for each row execute function public.fn_broadcast_event_progress_v2();

create or replace function public.fn_choose_restaurant(p_event_id uuid, p_place_id text)
returns table (chosen_place_id text, chosen_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_is_organizer boolean;
  v_chosen_at timestamptz;
begin
  select exists (
    select 1
    from public.events e
    join public.participants p on p.id = e.organizer_participant_id
    where e.id = p_event_id
      and p.auth_user_id = auth.uid()
  ) into v_is_organizer;

  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
     and not v_is_organizer
  then
    raise exception 'only the organizer can choose the restaurant';
  end if;

  if not exists (
    select 1 from public.restaurant_features rf where rf.place_id = p_place_id
  ) then
    raise exception 'unknown restaurant';
  end if;

  update public.events e
  set chosen_place_id = p_place_id,
      chosen_at = now(),
      status = 'closed'
  where e.id = p_event_id
  returning e.chosen_at into v_chosen_at;

  if not found then
    raise exception 'event not found';
  end if;

  perform realtime.send(
    jsonb_build_object(
      'chosen_place_id', p_place_id,
      'chosen_at', v_chosen_at),
    'event_decided',
    'event-' || p_event_id::text,
    true
  );

  return query
  select e.chosen_place_id, e.chosen_at
  from public.events e
  where e.id = p_event_id;
end;
$$;

grant delete on table public.participant_constraints to authenticated;

drop policy if exists "participant updates own raw constraints" on public.participant_constraints;
create policy "participant updates own raw constraints"
  on public.participant_constraints for update to authenticated
  using (
    exists (
      select 1 from public.participants p
      where p.id = participant_id
        and p.event_id = participant_constraints.event_id
        and p.auth_user_id = (select auth.uid())
    )
    and not public.fn_preferences_closed(participant_constraints.event_id)
  )
  with check (
    exists (
      select 1 from public.participants p
      where p.id = participant_id
        and p.event_id = participant_constraints.event_id
        and p.auth_user_id = (select auth.uid())
    )
    and not public.fn_preferences_closed(participant_constraints.event_id)
  );

drop policy if exists "participant deletes own raw constraints" on public.participant_constraints;
create policy "participant deletes own raw constraints"
  on public.participant_constraints for delete to authenticated
  using (
    exists (
      select 1 from public.participants p
      where p.id = participant_id
        and p.event_id = participant_constraints.event_id
        and p.auth_user_id = (select auth.uid())
    )
    and not public.fn_preferences_closed(participant_constraints.event_id)
  );

drop function if exists public.fn_get_sanitized_feed(uuid);
create function public.fn_get_sanitized_feed(p_event_id uuid)
returns table (
  id uuid,
  kind text,
  normalized_type text,
  normalized_value jsonb,
  visibility text,
  display_name text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql security definer stable set search_path = '' as $$
begin
  if not exists (
    select 1 from public.participants
    where event_id = p_event_id and auth_user_id = auth.uid()
  ) then
    raise exception 'not a participant of this event';
  end if;

  return query
  select pc.id, pc.kind, pc.normalized_type, pc.normalized_value,
         pc.visibility,
         case when pc.visibility = 'PUBLIC' then p.display_name else null end,
         pc.created_at, pc.updated_at
  from public.participant_constraints pc
  join public.participants p on p.id = pc.participant_id
  where pc.event_id = p_event_id
    and pc.visibility in ('PUBLIC','ANONYMOUS')
  order by pc.created_at, pc.id;
end;
$$;

create or replace function public.fn_broadcast_constraint_change()
returns trigger security definer language plpgsql set search_path = '' as $$
declare
  payload jsonb;
  v_event_id uuid;
begin
  if tg_op = 'DELETE' then
    if old.visibility in ('PUBLIC','ANONYMOUS') then
      perform realtime.send(
        jsonb_build_object('id', old.id, 'changed_at', clock_timestamp()),
        'constraint_deleted', 'event-' || old.event_id::text, true);
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.event_id is distinct from new.event_id then
    if old.visibility in ('PUBLIC','ANONYMOUS') then
      perform realtime.send(
        jsonb_build_object('id', old.id, 'changed_at', clock_timestamp()),
        'constraint_deleted', 'event-' || old.event_id::text, true);
    end if;
    if new.visibility not in ('PUBLIC','ANONYMOUS') then
      return new;
    end if;
    v_event_id := new.event_id;
  elsif tg_op = 'UPDATE'
        and old.visibility in ('PUBLIC','ANONYMOUS')
        and new.visibility = 'PRIVATE'
  then
    perform realtime.send(
      jsonb_build_object('id', old.id, 'changed_at', clock_timestamp()),
      'constraint_deleted', 'event-' || old.event_id::text, true);
    return new;
  elsif new.visibility not in ('PUBLIC','ANONYMOUS') then
    return new;
  else
    v_event_id := new.event_id;
  end if;

  payload := jsonb_build_object(
    'id', new.id,
    'kind', new.kind,
    'normalized_type', new.normalized_type,
    'normalized_value', new.normalized_value,
    'visibility', new.visibility,
    'display_name', case when new.visibility = 'PUBLIC'
      then (select p.display_name from public.participants p where p.id = new.participant_id)
      else null end,
    'created_at', new.created_at,
    'updated_at', new.updated_at
  );

  perform realtime.send(
    payload,
    case
      when tg_op = 'INSERT' then 'constraint_added'
      when old.visibility = 'PRIVATE' or old.event_id is distinct from new.event_id
        then 'constraint_added'
      else 'constraint_updated'
    end,
    'event-' || v_event_id::text,
    true
  );
  return new;
end;
$$;

drop trigger if exists trg_broadcast_constraint on public.participant_constraints;
create trigger trg_broadcast_constraint
  after insert or update or delete on public.participant_constraints
  for each row execute function public.fn_broadcast_constraint_change();

revoke execute on function public.fn_broadcast_event_progress_v2()
  from public, anon, authenticated;
grant execute on function public.fn_broadcast_event_progress_v2() to service_role;

revoke execute on function public.fn_choose_restaurant(uuid, text) from public, anon;
grant execute on function public.fn_choose_restaurant(uuid, text) to authenticated, service_role;

revoke execute on function public.fn_get_sanitized_feed(uuid) from public, anon;
grant execute on function public.fn_get_sanitized_feed(uuid) to authenticated, service_role;

revoke execute on function public.fn_invalidate_participant_origin_cache()
  from public, anon, authenticated;
grant execute on function public.fn_invalidate_participant_origin_cache() to service_role;

revoke execute on function public.fn_set_travel_reference_v2(
  uuid, text, text, text, double precision, double precision) from public, anon;
grant execute on function public.fn_set_travel_reference_v2(
  uuid, text, text, text, double precision, double precision) to authenticated, service_role;

revoke execute on function public.fn_create_event_v2(
  text, text, timestamptz, text, double precision, double precision, text, text, text)
  from public, anon;
grant execute on function public.fn_create_event_v2(
  text, text, timestamptz, text, double precision, double precision, text, text, text)
  to authenticated, service_role;

revoke execute on function public.fn_join_event_v2(
  text, text, text, double precision, double precision, text, text) from public, anon;
grant execute on function public.fn_join_event_v2(
  text, text, text, double precision, double precision, text, text)
  to authenticated, service_role;

revoke execute on function public.fn_preview_event_v2(text) from public, anon;
revoke execute on function public.fn_get_my_events_v2() from public, anon;
revoke execute on function public.fn_get_event_progress_v2(uuid) from public, anon;
grant execute on function public.fn_preview_event_v2(text) to authenticated, service_role;
grant execute on function public.fn_get_my_events_v2() to authenticated, service_role;
grant execute on function public.fn_get_event_progress_v2(uuid) to authenticated, service_role;
