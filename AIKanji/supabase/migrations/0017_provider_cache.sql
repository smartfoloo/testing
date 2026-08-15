-- 0017_provider_cache.sql
-- Event-scoped provider cache for the restaurant-search Edge Function.
--
-- Four things were wrong with the provider layer:
--   * `restaurant_features.travel_minutes_by_participant` is keyed by place_id
--     only, so event B's wholesale upsert replaced event A's travel times and
--     event A silently went from 3 feasible venues to 0. Travel time is
--     per-event data and now lives in `travel_matrix_cache`.
--   * candidates were a single global pool, so venues discovered for an
--     unrelated event across Tokyo counted as candidates for every event.
--     `event_restaurant_candidates` gives each event its own set.
--   * `last_fetched_at` / `fetched_at` were written but never read, so every
--     press of 「条件に合うお店を探す」 re-hit Places + Routes + Hot Pepper.
--   * raw provider payloads and provider failures were both discarded.
--
-- The legacy `restaurant_features.travel_minutes_by_participant` column stays:
-- `fn_travel_minutes` (0016) reads `travel_matrix_cache` first and falls back to
-- the JSONB, and the demo seed only populates the JSONB. This migration MERGES
-- into that column and never replaces it, so one event's write can no longer
-- delete another event's legs.

-- --- Event-scoped candidate set ---------------------------------------------

-- Candidates the search actually discovered for THIS event. The scoring engine
-- scopes feasibility on this table; events with no rows here (the demo seed,
-- anything created before this migration) must keep falling back to the global
-- pool, otherwise the five-persona fixture stops producing its 0-then-3
-- feasible counts.
create table if not exists public.event_restaurant_candidates (
  event_id uuid not null references public.events(id) on delete cascade,
  place_id text not null references public.restaurants(place_id) on delete cascade,
  discovered_at timestamptz not null default now(),
  primary key (event_id, place_id)
);

-- The primary key covers lookups by event; this one backs "which events wanted
-- this place" and the place_id cascade.
create index if not exists idx_event_restaurant_candidates_place
  on public.event_restaurant_candidates (place_id);

-- --- Per-event travel matrix -------------------------------------------------

create table if not exists public.travel_matrix_cache (
  event_id uuid not null references public.events(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  place_id text not null references public.restaurants(place_id) on delete cascade,
  minutes int not null,
  fetched_at timestamptz not null default now(),
  primary key (event_id, participant_id, place_id)
);

-- (event_id, participant_id, place_id) is served by the primary key; these back
-- the per-place lookups and the cascade deletes.
create index if not exists idx_travel_matrix_cache_event_place
  on public.travel_matrix_cache (event_id, place_id);
create index if not exists idx_travel_matrix_cache_participant
  on public.travel_matrix_cache (participant_id);

-- --- Meeting zones the search actually used ---------------------------------

-- PRD §15 requires the table and §10 requires that we do not use only the
-- geographic midpoint: `meetingAreas()` in the Edge Function takes the centroid
-- and pulls candidates toward the farthest participant to cap the worst
-- individual commute. These rows are what it computed, rank 1 = first choice,
-- and they double as the "has the search space materially shifted?" signal that
-- decides whether discovery may be served from cache.
create table if not exists public.meeting_zones (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  rank int not null,
  created_at timestamptz not null default now(),
  unique (event_id, rank)
);

-- --- Raw provider payloads --------------------------------------------------

-- Kept separate from the normalized restaurant records so a refetch that finds
-- no Hot Pepper match can no longer destroy enrichment: the normalized row is
-- merged, the evidence is here.
-- Places content other than place_id is short-lived by policy, so this is a
-- refreshable cache (one row per place/provider/source, overwritten in place,
-- never a history table) and it holds only the fields the FieldMask asked for.
-- `fn_purge_stale_provider_cache` below is the retention hammer.
-- The writer always sets source_id (Places: place id, Hot Pepper: shop id,
-- Routes: the event whose origins produced the matrix), so the unique key is
-- never partially null.
create table if not exists public.restaurant_source_records (
  id uuid primary key default gen_random_uuid(),
  place_id text not null references public.restaurants(place_id) on delete cascade,
  provider text not null
    check (provider in ('google_places','google_routes','hotpepper')),
  source_id text,
  payload jsonb not null default '{}',
  fetched_at timestamptz not null default now(),
  unique (place_id, provider, source_id)
);

-- --- Provider incidents -----------------------------------------------------

-- A dead provider must never break the event (acceptance test A10), but it must
-- stop being invisible. `provider` is deliberately unconstrained text so other
-- server-side callers can record their own failures here.
create table if not exists public.provider_incidents (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references public.events(id) on delete cascade,
  provider text not null,
  operation text not null,
  status_code int,
  message text,
  occurred_at timestamptz not null default now()
);

create index if not exists idx_provider_incidents_event_time
  on public.provider_incidents (event_id, occurred_at desc);

-- --- RLS ---------------------------------------------------------------------

alter table public.event_restaurant_candidates enable row level security;
alter table public.travel_matrix_cache enable row level security;
alter table public.meeting_zones enable row level security;
alter table public.restaurant_source_records enable row level security;
alter table public.provider_incidents enable row level security;

-- Reads follow the established shape: a participant sees their own events' data
-- and nothing else. `fn_my_event_ids()` is the security definer helper that
-- exists because a policy subquerying `participants` recurses infinitely.
-- Writes have no client policy at all: everything is written by the Edge
-- Function's service-role client through the definer functions below.

drop policy if exists "event participants read their candidate set"
  on public.event_restaurant_candidates;
create policy "event participants read their candidate set"
  on public.event_restaurant_candidates for select to authenticated
  using (event_id in (select public.fn_my_event_ids()));

drop policy if exists "service role writes the candidate set"
  on public.event_restaurant_candidates;
create policy "service role writes the candidate set"
  on public.event_restaurant_candidates for all to service_role
  using (true) with check (true);

-- Travel minutes are already world-readable through
-- `restaurant_features.travel_minutes_by_participant` ("readable by any
-- authenticated user"); scoping them to the event is strictly tighter.
drop policy if exists "event participants read their travel matrix"
  on public.travel_matrix_cache;
create policy "event participants read their travel matrix"
  on public.travel_matrix_cache for select to authenticated
  using (event_id in (select public.fn_my_event_ids()));

drop policy if exists "service role writes the travel matrix"
  on public.travel_matrix_cache;
create policy "service role writes the travel matrix"
  on public.travel_matrix_cache for all to service_role
  using (true) with check (true);

drop policy if exists "event participants read their meeting zones"
  on public.meeting_zones;
create policy "event participants read their meeting zones"
  on public.meeting_zones for select to authenticated
  using (event_id in (select public.fn_my_event_ids()));

drop policy if exists "service role writes meeting zones" on public.meeting_zones;
create policy "service role writes meeting zones"
  on public.meeting_zones for all to service_role
  using (true) with check (true);

-- Raw payloads are provider content under provider terms: server-side only, no
-- client policy, so RLS denies anon and authenticated outright.
drop policy if exists "service role owns raw provider payloads"
  on public.restaurant_source_records;
create policy "service role owns raw provider payloads"
  on public.restaurant_source_records for all to service_role
  using (true) with check (true);

-- Incidents are shown to the group ("Hot Pepper is not answering right now"),
-- so event participants may read their own event's rows. Rows with a null
-- event_id are server-side only.
drop policy if exists "event participants read their provider incidents"
  on public.provider_incidents;
create policy "event participants read their provider incidents"
  on public.provider_incidents for select to authenticated
  using (event_id in (select public.fn_my_event_ids()));

drop policy if exists "service role writes provider incidents"
  on public.provider_incidents;
create policy "service role writes provider incidents"
  on public.provider_incidents for all to service_role
  using (true) with check (true);

-- Defence in depth behind RLS: client roles get SELECT where a policy allows it
-- and never any write privilege, and no access at all to raw payloads.
revoke all on table public.event_restaurant_candidates from anon, authenticated;
revoke all on table public.travel_matrix_cache from anon, authenticated;
revoke all on table public.meeting_zones from anon, authenticated;
revoke all on table public.restaurant_source_records from anon, authenticated;
revoke all on table public.provider_incidents from anon, authenticated;

grant select on table public.event_restaurant_candidates to authenticated;
grant select on table public.travel_matrix_cache to authenticated;
grant select on table public.meeting_zones to authenticated;
grant select on table public.provider_incidents to authenticated;

grant select, insert, update, delete
  on table public.event_restaurant_candidates to service_role;
grant select, insert, update, delete
  on table public.travel_matrix_cache to service_role;
grant select, insert, update, delete
  on table public.meeting_zones to service_role;
grant select, insert, update, delete
  on table public.restaurant_source_records to service_role;
grant select, insert, update, delete
  on table public.provider_incidents to service_role;

-- --- Non-destructive normalized upsert --------------------------------------

-- The old Edge Function upserted `restaurant_features` wholesale, so a refetch
-- that found no Hot Pepper match wiped dietary/allergy/room enrichment and a
-- second event wiped the first event's travel minutes. This function is the only
-- write path now and it is additive:
--   * a null/empty incoming value never overwrites a populated one
--   * the legacy travel JSONB is merged with `||`, never replaced
--   * `rating` / `user_rating_count` (added by 0016 for the scoring engine) are
--     filled when present, guarded so this migration still applies if 0016 has
--     not landed yet
--   * columns no provider of ours can speak to (0016's `accessibility_tags`) are
--     never written, so a search cannot downgrade them either
create or replace function public.fn_record_provider_candidates(
  p_event_id uuid,
  p_candidates jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_candidate jsonb;
  v_place_id text;
  v_count int := 0;
  v_has_rating boolean;
begin
  -- Same request-context shape as the feasibility guards: the service_role
  -- Edge Function client and direct SQL sessions (no JWT claims) are the
  -- admin/definer path; an API caller must never write provider data.
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record candidates';
  end if;

  if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' then
    return 0;
  end if;

  if not exists (select 1 from public.events e where e.id = p_event_id) then
    raise exception 'event % not found', p_event_id;
  end if;

  select exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'restaurant_features'
      and c.column_name = 'rating'
  ) into v_has_rating;

  for v_candidate in select value from jsonb_array_elements(p_candidates)
  loop
    v_place_id := nullif(v_candidate->>'place_id', '');
    if v_place_id is null then
      continue;
    end if;

    insert into public.restaurants as r (place_id, hotpepper_id, last_fetched_at)
    values (v_place_id, nullif(v_candidate->>'hotpepper_id', ''), now())
    on conflict (place_id) do update
      set hotpepper_id = coalesce(excluded.hotpepper_id, r.hotpepper_id),
          last_fetched_at = now();

    insert into public.restaurant_features as rf (
      place_id, name, price_yen_estimate, room_type,
      cuisine_tags, dietary_tags, allergy_safe_tags, atmosphere_tags,
      fetched_at
    )
    values (
      v_place_id,
      nullif(v_candidate->>'name', ''),
      (v_candidate->>'price_yen_estimate')::int,
      nullif(v_candidate->>'room_type', ''),
      case when jsonb_typeof(v_candidate->'cuisine_tags') = 'array'
        then array(select jsonb_array_elements_text(v_candidate->'cuisine_tags'))
        else '{}'::text[] end,
      case when jsonb_typeof(v_candidate->'dietary_tags') = 'array'
        then array(select jsonb_array_elements_text(v_candidate->'dietary_tags'))
        else '{}'::text[] end,
      case when jsonb_typeof(v_candidate->'allergy_safe_tags') = 'array'
        then array(select jsonb_array_elements_text(v_candidate->'allergy_safe_tags'))
        else '{}'::text[] end,
      case when jsonb_typeof(v_candidate->'atmosphere_tags') = 'array'
        then array(select jsonb_array_elements_text(v_candidate->'atmosphere_tags'))
        else '{}'::text[] end,
      now()
    )
    on conflict (place_id) do update set
      name = coalesce(excluded.name, rf.name),
      price_yen_estimate = coalesce(
        excluded.price_yen_estimate, rf.price_yen_estimate),
      room_type = coalesce(excluded.room_type, rf.room_type),
      cuisine_tags = case
        when coalesce(array_length(excluded.cuisine_tags, 1), 0) = 0
        then rf.cuisine_tags else excluded.cuisine_tags end,
      dietary_tags = case
        when coalesce(array_length(excluded.dietary_tags, 1), 0) = 0
        then rf.dietary_tags else excluded.dietary_tags end,
      allergy_safe_tags = case
        when coalesce(array_length(excluded.allergy_safe_tags, 1), 0) = 0
        then rf.allergy_safe_tags else excluded.allergy_safe_tags end,
      atmosphere_tags = case
        when coalesce(array_length(excluded.atmosphere_tags, 1), 0) = 0
        then rf.atmosphere_tags else excluded.atmosphere_tags end,
      fetched_at = now();

    -- 0016 owns these columns; fill them only if they are already there.
    if v_has_rating then
      execute 'update public.restaurant_features rf
                  set rating = coalesce($2::numeric, rf.rating),
                      user_rating_count = coalesce($3::int, rf.user_rating_count)
                where rf.place_id = $1'
        using v_place_id,
              (v_candidate->>'rating')::numeric,
              (v_candidate->>'user_rating_count')::int;
    end if;

    insert into public.event_restaurant_candidates (
      event_id, place_id, discovered_at
    )
    values (p_event_id, v_place_id, now())
    on conflict (event_id, place_id) do update set discovered_at = now();

    v_count := v_count + 1;
  end loop;

  return v_count;
end; $$;

-- --- Travel matrix writes ----------------------------------------------------

-- Authoritative per-event store plus the legacy JSONB, in one transaction.
-- p_legs: [{"participant_id": uuid, "place_id": text, "minutes": int}, …]
create or replace function public.fn_record_travel_minutes(
  p_event_id uuid,
  p_legs jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_count int := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record travel minutes';
  end if;

  if p_legs is null or jsonb_typeof(p_legs) <> 'array' then
    return 0;
  end if;

  with raw as (
    select leg->>'participant_id' as participant_id,
           leg->>'place_id' as place_id,
           leg->>'minutes' as minutes
    from jsonb_array_elements(p_legs) as leg
  ), valid as (
    -- Output columns are renamed so the DISTINCT ON / ORDER BY expressions can
    -- only resolve to `raw`'s text columns, and so the ::int cast is applied
    -- after the regex filter has thrown out anything that is not a number.
    select distinct on (participant_id, place_id)
           participant_id::uuid as pid,
           place_id as pl,
           minutes::int as mins
    from raw
    where participant_id ~*
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and place_id is not null
      and place_id <> ''
      and minutes ~ '^[0-9]{1,6}$'
    order by participant_id, place_id
  )
  insert into public.travel_matrix_cache as tmc (
    event_id, participant_id, place_id, minutes, fetched_at
  )
  select p_event_id, v.pid, v.pl, v.mins, now()
  from valid v
  join public.participants p
    on p.id = v.pid and p.event_id = p_event_id
  join public.restaurants r on r.place_id = v.pl
  on conflict (event_id, participant_id, place_id) do update
    set minutes = excluded.minutes,
        fetched_at = now();

  get diagnostics v_count = row_count;

  -- Backward compatibility. `fn_travel_minutes` prefers travel_matrix_cache and
  -- the seed fixture only has the JSONB, so the column stays populated — but it
  -- is MERGED, never replaced: participant keys belonging to other events share
  -- the same object and used to be deleted here.
  update public.restaurant_features rf
     set travel_minutes_by_participant =
           coalesce(rf.travel_minutes_by_participant, '{}'::jsonb) || agg.legs
    from (
      select tmc.place_id,
             jsonb_object_agg(tmc.participant_id::text, tmc.minutes) as legs
      from public.travel_matrix_cache tmc
      where tmc.event_id = p_event_id
      group by tmc.place_id
    ) agg
   where rf.place_id = agg.place_id;

  return v_count;
end; $$;

-- --- Retention ---------------------------------------------------------------

-- Provider content is licensed, not owned: these tables are a cache with a
-- ceiling, not a warehouse. Call this from a scheduled job; it only ever touches
-- rows this migration created, so the demo seed is untouched.
create or replace function public.fn_purge_stale_provider_cache(
  p_max_age interval default interval '30 days'
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_payloads int := 0;
  v_legs int := 0;
  v_candidates int := 0;
  v_incidents int := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may purge the provider cache';
  end if;

  delete from public.restaurant_source_records
   where fetched_at < now() - p_max_age;
  get diagnostics v_payloads = row_count;

  delete from public.travel_matrix_cache where fetched_at < now() - p_max_age;
  get diagnostics v_legs = row_count;

  delete from public.event_restaurant_candidates
   where discovered_at < now() - p_max_age;
  get diagnostics v_candidates = row_count;

  delete from public.provider_incidents where occurred_at < now() - p_max_age;
  get diagnostics v_incidents = row_count;

  return jsonb_build_object(
    'source_records_deleted', v_payloads,
    'travel_legs_deleted', v_legs,
    'event_candidates_deleted', v_candidates,
    'incidents_deleted', v_incidents
  );
end; $$;

revoke execute on function public.fn_record_provider_candidates(uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_record_travel_minutes(uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_purge_stale_provider_cache(interval)
  from public, anon, authenticated;
grant execute on function public.fn_record_provider_candidates(uuid, jsonb)
  to service_role;
grant execute on function public.fn_record_travel_minutes(uuid, jsonb)
  to service_role;
grant execute on function public.fn_purge_stale_provider_cache(interval)
  to service_role;
