-- Sanitized group activity feed.
--
-- RLS on participant_constraints deliberately hides other participants' rows, so the feed
-- cannot be a postgres_changes subscription or a direct table read: it is a broadcast of an
-- explicitly sanitized payload plus a security definer function for the initial history load.

create or replace function fn_broadcast_constraint_change()
returns trigger security definer language plpgsql as $$
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
      then (select display_name from participants where id = new.participant_id)
      else null end,
    'created_at', new.created_at
  );

  perform realtime.send(payload, 'constraint_added', 'event-' || new.event_id::text, true);
  return new;
end; $$;

create trigger trg_broadcast_constraint
  after insert on participant_constraints
  for each row execute function fn_broadcast_constraint_change();

-- Realtime Authorization: who may subscribe to the private topic `event-{event_id}`.
-- `realtime.topic()` returns the topic the client is joining; RLS is already enabled on
-- realtime.messages by Realtime itself.
create policy "event participants can receive event broadcasts"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1
      from public.participants p
      where p.auth_user_id = (select auth.uid())
        and 'event-' || p.event_id::text = (select realtime.topic())
    )
  );

-- Initial feed load: broadcast only covers inserts that happen after a client subscribes.
create or replace function fn_get_sanitized_feed(p_event_id uuid)
returns table (
  id uuid, kind text, normalized_type text, normalized_value jsonb,
  visibility text, display_name text, created_at timestamptz
)
language plpgsql security definer as $$
begin
  if not exists (
    select 1 from participants where event_id = p_event_id and auth_user_id = auth.uid()
  ) then
    raise exception 'not a participant of this event';
  end if;

  return query
  select pc.id, pc.kind, pc.normalized_type, pc.normalized_value,
         pc.visibility,
         case when pc.visibility = 'PUBLIC' then p.display_name else null end,
         pc.created_at
  from participant_constraints pc
  join participants p on p.id = pc.participant_id
  where pc.event_id = p_event_id
    and pc.visibility in ('PUBLIC','ANONYMOUS')
  order by pc.created_at;
end; $$;
