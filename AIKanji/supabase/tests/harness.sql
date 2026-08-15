-- Local-only stand-ins for objects the hosted Supabase Realtime service owns.
-- Applied before the migrations when running against a plain supabase/postgres
-- container; never applied to a real project.

create schema if not exists realtime;
grant all on schema realtime to postgres;

create table if not exists realtime.messages (
  id bigserial primary key,
  topic text not null,
  extension text not null,
  event text,
  payload jsonb,
  private boolean not null default false,
  inserted_at timestamptz not null default now()
);

alter table realtime.messages owner to postgres;
alter table realtime.messages enable row level security;
grant select, insert on realtime.messages to postgres, authenticated, service_role;
grant usage, select on sequence realtime.messages_id_seq to postgres, authenticated, service_role;

create or replace function realtime.topic()
returns text language sql stable as $$
  select nullif(current_setting('realtime.topic', true), '');
$$;

create or replace function realtime.send(
  payload jsonb, event text, topic text, private boolean default true
) returns void language plpgsql as $$
begin
  insert into realtime.messages (topic, extension, event, payload, private)
  values (topic, 'broadcast', event, payload, private);
end; $$;
