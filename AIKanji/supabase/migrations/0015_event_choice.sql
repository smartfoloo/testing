-- The group's final decision: the one restaurant the organizer confirms for the event.
-- Readable by every participant through the existing `events` select policy, writable only
-- by the organizer through this RPC.

alter table events add column if not exists chosen_place_id text references restaurants(place_id);
alter table events add column if not exists chosen_at timestamptz;

create or replace function public.fn_choose_restaurant(p_event_id uuid, p_place_id text)
returns table (chosen_place_id text, chosen_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_is_organizer boolean;
begin
  select exists (
    select 1
    from public.events e
    join public.participants p on p.id = e.organizer_participant_id
    where e.id = p_event_id
      and p.auth_user_id = auth.uid()
  ) into v_is_organizer;

  -- Same request-context shape as the feasibility guards: service_role and direct SQL
  -- sessions (no JWT claims) are the admin/definer path; every API caller must be the organizer.
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
   where e.id = p_event_id;

  if not found then
    raise exception 'event not found';
  end if;

  perform realtime.send(
    jsonb_build_object('chosen_place_id', p_place_id),
    'event_decided',
    'event-' || p_event_id::text,
    true
  );

  return query
  select e.chosen_place_id, e.chosen_at
  from public.events e
  where e.id = p_event_id;
end; $$;

revoke execute on function public.fn_choose_restaurant(uuid, text) from public, anon;
grant execute on function public.fn_choose_restaurant(uuid, text) to authenticated, service_role;
