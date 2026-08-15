-- Security and correctness hardening:
-- * constraint policies verify the participant belongs to the row's event
-- * RLS subqueries use (select auth.uid()) and are backed by indexes
-- * all security definer functions pin search_path and schema-qualify
-- * fn_create_event creates the organizer participant in the same transaction
-- * fn_join_event is idempotent, rejects closed events
-- * invite codes use a larger alphabet with collision retry
-- * updated_at is maintained by trigger

-- Constraint write policies: participant must own the row AND belong to its event.
drop policy "participant writes own raw constraints" on participant_constraints;
drop policy "participant updates own raw constraints" on participant_constraints;

create policy "participant writes own raw constraints"
  on participant_constraints for insert
  with check (exists (
    select 1 from participants p
    where p.id = participant_id
      and p.event_id = participant_constraints.event_id
      and p.auth_user_id = (select auth.uid())
  ));

create policy "participant updates own raw constraints"
  on participant_constraints for update
  using (exists (
    select 1 from participants p
    where p.id = participant_id
      and p.event_id = participant_constraints.event_id
      and p.auth_user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from participants p
    where p.id = participant_id
      and p.event_id = participant_constraints.event_id
      and p.auth_user_id = (select auth.uid())
  ));

-- Read policies: wrap auth.uid() so it is evaluated once per statement.
drop policy "event visible to its participants" on events;
create policy "event visible to its participants"
  on events for select
  using (id in (select event_id from participants where auth_user_id = (select auth.uid())));

-- The participants select policy cannot subquery participants itself (infinite
-- recursion under RLS), so membership comes from a security definer helper.
create or replace function fn_my_event_ids()
returns setof uuid
language sql security definer stable
set search_path = ''
as $$
  select event_id from public.participants where auth_user_id = auth.uid()
$$;

drop policy "participant reads own event membership list" on participants;
create policy "participant reads own event membership list"
  on participants for select
  using (event_id in (select fn_my_event_ids()));

drop policy "participant reads own raw constraints" on participant_constraints;
create policy "participant reads own raw constraints"
  on participant_constraints for select
  using (participant_id in (select id from participants where auth_user_id = (select auth.uid())));

drop policy "participant reads own negotiations" on negotiations;
create policy "participant reads own negotiations"
  on negotiations for select
  using (participant_id in (select id from participants where auth_user_id = (select auth.uid())));

drop policy "recommendation_runs readable by event participants" on recommendation_runs;
create policy "recommendation_runs readable by event participants"
  on recommendation_runs for select
  using (event_id in (select event_id from participants where auth_user_id = (select auth.uid())));

drop policy "recommendation_scores readable by event participants" on recommendation_scores;
create policy "recommendation_scores readable by event participants"
  on recommendation_scores for select
  using (run_id in (select id from recommendation_runs where event_id in
          (select event_id from participants where auth_user_id = (select auth.uid()))));

-- Indexes backing the RLS subqueries above.
create index idx_participants_auth_user_id on participants (auth_user_id);
create index idx_participant_constraints_event_id on participant_constraints (event_id);
create index idx_participant_constraints_participant_id on participant_constraints (participant_id);

-- Invite codes: 31-character unambiguous alphabet (~887M combinations at 6 chars).
create or replace function fn_generate_invite_code(p_length int default 6)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_alphabet constant text := '23456789abcdefghjkmnpqrstuvwxyz';
  v_code text := '';
  v_bytes bytea := uuid_send(gen_random_uuid());
  i int;
begin
  if p_length > 16 then
    raise exception 'invite code length must be <= 16';
  end if;
  for i in 0 .. p_length - 1 loop
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % 31) + 1, 1);
  end loop;
  return v_code;
end; $$;

alter table events alter column invite_code set default public.fn_generate_invite_code();

-- Event creation now also creates the organizer participant atomically.
drop function fn_create_event(text, text);
create function fn_create_event(
  p_name text,
  p_display_name text,
  p_travel_reference text,
  p_travel_reference_place_id text default null,
  p_objective text default 'balanced'
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_code text;
  v_participant_id uuid;
  v_attempts int := 0;
begin
  loop
    begin
      insert into public.events (name, objective, invite_code)
      values (p_name, p_objective, public.fn_generate_invite_code())
      returning id, invite_code into v_id, v_code;
      exit;
    exception when unique_violation then
      v_attempts := v_attempts + 1;
      if v_attempts >= 5 then
        raise exception 'could not generate a unique invite code';
      end if;
    end;
  end loop;

  insert into public.participants
    (event_id, auth_user_id, display_name, role, travel_reference, travel_reference_place_id)
  values
    (v_id, auth.uid(), p_display_name, 'organizer', p_travel_reference, p_travel_reference_place_id)
  returning id into v_participant_id;

  update public.events set organizer_participant_id = v_participant_id where id = v_id;

  return jsonb_build_object(
    'event_id', v_id,
    'invite_code', v_code,
    'participant_id', v_participant_id
  );
end; $$;

-- Compatibility for the existing domain safety test's scratch event. New app
-- callers use the full organizer-aware signature above.
create function public.fn_create_event(p_name text)
returns jsonb
language sql security definer
set search_path = ''
as $$
  select public.fn_create_event(p_name, 'Organizer', 'office', null, 'balanced');
$$;

-- Joining is idempotent and rejects closed events. The organizer is created by
-- fn_create_event, so the first-joiner promotion is gone.
create or replace function fn_join_event(
  p_invite_code text,
  p_display_name text,
  p_travel_reference text,
  p_travel_reference_place_id text default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  v_status text;
  v_participant_id uuid;
begin
  select id, status into v_event_id, v_status
  from public.events where invite_code = p_invite_code;
  if v_event_id is null then
    raise exception 'invalid invite code';
  end if;
  if v_status = 'closed' then
    raise exception 'this event is closed';
  end if;

  insert into public.participants
    (event_id, auth_user_id, display_name, travel_reference, travel_reference_place_id)
  values
    (v_event_id, auth.uid(), p_display_name, p_travel_reference, p_travel_reference_place_id)
  on conflict (event_id, auth_user_id) do update
    set display_name = excluded.display_name
  returning id into v_participant_id;

  return v_participant_id;
end; $$;

-- Re-pin search_path on the remaining security definer functions.
create or replace function fn_broadcast_constraint_change()
returns trigger security definer
language plpgsql
set search_path = ''
as $$
declare payload jsonb;
begin
  if new.visibility not in ('PUBLIC','ANONYMOUS') then
    return new; -- PRIVATE rows are never broadcast to the group, full stop
  end if;

  payload := jsonb_build_object(
    'id', new.id,
    'kind', new.kind,
    'normalized_type', new.normalized_type,
    'normalized_value', new.normalized_value,
    'visibility', new.visibility,
    'display_name', case when new.visibility = 'PUBLIC'
      then (select display_name from public.participants where id = new.participant_id)
      else null end,
    'created_at', new.created_at
  );

  perform realtime.send(payload, 'constraint_added', 'event-' || new.event_id::text, true);
  return new;
end; $$;

create or replace function fn_get_sanitized_feed(p_event_id uuid)
returns table (
  id uuid, kind text, normalized_type text, normalized_value jsonb,
  visibility text, display_name text, created_at timestamptz
)
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

  return query
  select pc.id, pc.kind, pc.normalized_type, pc.normalized_value,
         pc.visibility,
         case when pc.visibility = 'PUBLIC' then p.display_name else null end,
         pc.created_at
  from public.participant_constraints pc
  join public.participants p on p.id = pc.participant_id
  where pc.event_id = p_event_id
    and pc.visibility in ('PUBLIC','ANONYMOUS')
  order by pc.created_at;
end; $$;

-- Keep updated_at current on constraint edits.
create or replace function fn_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end; $$;

create trigger trg_touch_participant_constraints
  before update on participant_constraints
  for each row execute function fn_touch_updated_at();

-- Feasibility and negotiation were introduced after the original hardening
-- migration. Re-pin their search paths and apply the same caller protections.
-- These definitions intentionally run after 0006 so they cannot be clobbered by
-- an older create-or-replace statement.
alter table public.restaurant_features
  add column if not exists name text;

-- The feed must reflect a participant constraint rewritten by negotiation.
create or replace function public.fn_broadcast_constraint_change()
returns trigger
security definer
language plpgsql
set search_path = ''
as $$
declare
  payload jsonb;
begin
  if new.visibility not in ('PUBLIC','ANONYMOUS') then
    return new;
  end if;

  payload := jsonb_build_object(
    'id', new.id,
    'kind', new.kind,
    'normalized_type', new.normalized_type,
    'normalized_value', new.normalized_value,
    'visibility', new.visibility,
    'display_name', case when new.visibility = 'PUBLIC'
      then (select display_name from public.participants
            where id = new.participant_id)
      else null end,
    'created_at', new.created_at
  );

  perform realtime.send(
    payload,
    case when tg_op = 'UPDATE' then 'constraint_updated' else 'constraint_added' end,
    'event-' || new.event_id::text,
    true
  );
  return new;
end; $$;

drop trigger if exists trg_broadcast_constraint
  on public.participant_constraints;
create trigger trg_broadcast_constraint
  after insert or update on public.participant_constraints
  for each row execute function public.fn_broadcast_constraint_change();

-- These functions are implementation details called by the guarded public
-- RPCs. Client roles must not be able to use them as cross-event oracles.
revoke execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid)
  from public, anon, authenticated;
