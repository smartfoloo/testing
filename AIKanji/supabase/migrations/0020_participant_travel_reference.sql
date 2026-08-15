-- 0020_participant_travel_reference.sql
-- Let a participant change their OWN travel reference after joining.
--
-- PRD §4 lists the travel reference as context — "not itself a constraint;
-- changeable later" — but it was only ever settable inside fn_create_event /
-- fn_join_event, and fn_join_event's `on conflict do update` touches only
-- display_name. `participants` has a SELECT policy and nothing else (0002,
-- 0007), so a direct client update matches zero rows and fails silently.
--
-- Consequences of that gap, in order of severity:
--   * anyone who skipped the place picker on the create/join screen can never
--     contribute a travel origin. restaurant-search reports them in
--     `unresolved_participants`, travel fairness quietly degrades for the whole
--     group, and if NOBODY has a place id the search answers 422;
--   * there is no way to correct a wrong answer (「会社」 picked at the office,
--     joined again from home), and no way to opt out later by choosing どこでも.
--
-- Deliberately NOT gated on `events.preferences_closed_at`: 0018 closes the collection
-- of REQUIREMENTS, and PRD §4 is explicit that the travel reference is not one of them.
-- Closing preferences freezes what the group is asking for; it does not freeze where a
-- participant leaves from. A changed origin only reaches a shortlist when the 幹事
-- explicitly recomputes, which is the PRD §12 rule already.
--
-- The write path is a security definer RPC rather than an UPDATE policy, for two
-- reasons: RLS cannot restrict WHICH columns a caller writes (a policy allowing
-- the row would also allow `role = 'organizer'`, `display_name`, or moving the
-- row to another event_id), and a policy on `participants` that subqueries
-- `participants` recurses under RLS — the reason fn_my_event_ids() exists. This
-- function writes exactly two columns and nothing else, so privilege escalation
-- through it is not possible by construction.

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
  v_old_place_id text;
  v_new_place_id text;
begin
  -- Same CHECK list as participants.travel_reference (0001). Validated here so a
  -- bad category is a named refusal instead of a raw constraint violation.
  if p_travel_reference is null
     or p_travel_reference not in ('office','home','station','doesnt_matter')
  then
    raise exception 'invalid travel reference: %', coalesce(p_travel_reference, 'null');
  end if;

  select p.event_id, p.auth_user_id, p.travel_reference_place_id
    into v_event_id, v_auth_user_id, v_old_place_id
  from public.participants p
  where p.id = p_participant_id;

  if v_event_id is null then
    raise exception 'participant not found';
  end if;

  -- Same request-context shape as fn_choose_restaurant (0015): service_role and
  -- direct SQL sessions (no JWT claims) are the admin/definer path; every API
  -- caller may only change their own row. The organizer is deliberately NOT
  -- privileged here — a travel reference is personal context, not group state.
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
     and v_auth_user_id is distinct from auth.uid()
  then
    raise exception 'not permitted to change another participant''s travel reference';
  end if;

  -- どこでも means "no travel constraint", so it can carry no place: keeping a
  -- stale place id would make restaurant-search treat an opted-out participant
  -- as an origin again. Empty string is normalized to null for the same reason.
  v_new_place_id := case
    when p_travel_reference = 'doesnt_matter' then null
    else nullif(p_travel_reference_place_id, '')
  end;

  -- Exactly two columns. role / display_name / event_id / auth_user_id are not
  -- writable through this function at all.
  update public.participants p
     set travel_reference = p_travel_reference,
         travel_reference_place_id = v_new_place_id
   where p.id = p_participant_id;

  -- Cached travel legs were measured FROM the old origin. Leaving them would
  -- keep scoring this participant from a place they no longer start at (and,
  -- for どこでも, keep scoring them at all), so the legs are dropped whenever the
  -- origin actually moves. Both stores that fn_travel_minutes (0016) reads have
  -- to go: the event-scoped travel_matrix_cache (0017) and the legacy global
  -- restaurant_features.travel_minutes_by_participant JSONB it falls back to.
  -- The next 「条件に合うお店を探す」 re-fetches them from the new origin;
  -- meeting_zones are left alone because restaurant-search recomputes the zones
  -- from the current origins and detects the shift itself.
  if coalesce(v_new_place_id, '') is distinct from coalesce(v_old_place_id, '') then
    delete from public.travel_matrix_cache tmc
     where tmc.event_id = v_event_id
       and tmc.participant_id = p_participant_id;

    -- The JSONB is keyed by participant id, so removing this key cannot touch
    -- another participant's or another event's legs.
    update public.restaurant_features rf
       set travel_minutes_by_participant =
             rf.travel_minutes_by_participant - p_participant_id::text
     where rf.travel_minutes_by_participant ? p_participant_id::text;
  end if;

  return query
  select p.travel_reference, p.travel_reference_place_id
  from public.participants p
  where p.id = p_participant_id;
end; $$;

revoke execute on function public.fn_set_travel_reference(uuid, text, text)
  from public, anon;
grant execute on function public.fn_set_travel_reference(uuid, text, text)
  to authenticated, service_role;

-- Defence in depth behind the RPC: `participants` intentionally has no client
-- write policy, so RLS already refuses these, and now the privilege is gone as
-- well. SELECT is untouched (0007's membership policy still applies), and both
-- fn_create_event / fn_join_event and this function are security definer, so
-- the legitimate write paths are unaffected.
revoke insert, update, delete on table public.participants from anon, authenticated;
