create or replace function public.fn_allergen_vocabulary()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array[
    'shrimp',
    'cashew_nut',
    'crab',
    'walnut',
    'wheat',
    'buckwheat',
    'egg',
    'milk',
    'peanut',
    'almond',
    'abalone',
    'squid',
    'salmon_roe',
    'orange',
    'kiwi',
    'beef',
    'sesame',
    'salmon',
    'mackerel',
    'soybean',
    'chicken',
    'banana',
    'pistachio',
    'pork',
    'macadamia_nut',
    'peach',
    'yam',
    'apple',
    'gelatin'
  ]::text[];
$$;

create or replace function public.fn_allergen_canonical_members(p_raw text)
returns setof text language sql immutable security definer set search_path = '' as $$
  with token as (
    select pg_catalog.regexp_replace(
      coalesce(public.fn_taxonomy_token(p_raw), ''), '_?free$', '') as value
  )
  select distinct m.canonical
  from token t
  join (values
    ('shrimp', 'shrimp'), ('prawn', 'shrimp'), ('prawns', 'shrimp'),
    ('えび', 'shrimp'), ('エビ', 'shrimp'), ('海老', 'shrimp'),
    ('cashew_nut', 'cashew_nut'), ('cashew', 'cashew_nut'), ('cashews', 'cashew_nut'),
    ('カシューナッツ', 'cashew_nut'),
    ('crab', 'crab'), ('crabs', 'crab'),
    ('かに', 'crab'), ('カニ', 'crab'), ('蟹', 'crab'),
    ('walnut', 'walnut'), ('walnuts', 'walnut'),
    ('くるみ', 'walnut'), ('クルミ', 'walnut'), ('胡桃', 'walnut'),
    ('wheat', 'wheat'), ('小麦', 'wheat'), ('こむぎ', 'wheat'),
    ('コムギ', 'wheat'), ('小麦粉', 'wheat'),
    ('buckwheat', 'buckwheat'), ('soba', 'buckwheat'),
    ('そば', 'buckwheat'), ('蕎麦', 'buckwheat'), ('ソバ', 'buckwheat'), ('そば粉', 'buckwheat'),
    ('egg', 'egg'), ('eggs', 'egg'),
    ('卵', 'egg'), ('たまご', 'egg'), ('タマゴ', 'egg'), ('玉子', 'egg'), ('鶏卵', 'egg'),
    ('milk', 'milk'), ('dairy', 'milk'),
    ('乳', 'milk'), ('牛乳', 'milk'), ('ミルク', 'milk'), ('乳製品', 'milk'),
    ('乳成分', 'milk'), ('チーズ', 'milk'), ('バター', 'milk'),
    ('peanut', 'peanut'), ('peanuts', 'peanut'),
    ('落花生', 'peanut'), ('ピーナッツ', 'peanut'), ('ピーナツ', 'peanut'),
    ('almond', 'almond'), ('almonds', 'almond'), ('アーモンド', 'almond'),
    ('abalone', 'abalone'), ('あわび', 'abalone'), ('アワビ', 'abalone'), ('鮑', 'abalone'),
    ('squid', 'squid'), ('いか', 'squid'), ('イカ', 'squid'), ('烏賊', 'squid'),
    ('salmon_roe', 'salmon_roe'), ('salmonroe', 'salmon_roe'),
    ('いくら', 'salmon_roe'), ('イクラ', 'salmon_roe'),
    ('orange', 'orange'), ('oranges', 'orange'), ('オレンジ', 'orange'),
    ('kiwi', 'kiwi'), ('kiwifruit', 'kiwi'), ('kiwi_fruit', 'kiwi'),
    ('キウイ', 'kiwi'), ('キウイフルーツ', 'kiwi'),
    ('beef', 'beef'), ('牛肉', 'beef'),
    ('sesame', 'sesame'), ('ごま', 'sesame'), ('ゴマ', 'sesame'), ('胡麻', 'sesame'),
    ('salmon', 'salmon'), ('さけ', 'salmon'), ('サケ', 'salmon'), ('鮭', 'salmon'),
    ('mackerel', 'mackerel'), ('さば', 'mackerel'), ('サバ', 'mackerel'), ('鯖', 'mackerel'),
    ('soybean', 'soybean'), ('soybeans', 'soybean'), ('soy', 'soybean'),
    ('大豆', 'soybean'), ('だいず', 'soybean'),
    ('chicken', 'chicken'), ('鶏肉', 'chicken'), ('とり肉', 'chicken'),
    ('banana', 'banana'), ('bananas', 'banana'), ('バナナ', 'banana'),
    ('pistachio', 'pistachio'), ('pistachios', 'pistachio'), ('ピスタチオ', 'pistachio'),
    ('pork', 'pork'), ('豚肉', 'pork'),
    ('macadamia_nut', 'macadamia_nut'), ('macadamia', 'macadamia_nut'),
    ('マカダミアナッツ', 'macadamia_nut'),
    ('peach', 'peach'), ('peaches', 'peach'), ('もも', 'peach'), ('モモ', 'peach'), ('桃', 'peach'),
    ('yam', 'yam'), ('yamaimo', 'yam'), ('やまいも', 'yam'), ('山芋', 'yam'),
    ('apple', 'apple'), ('apples', 'apple'), ('りんご', 'apple'), ('リンゴ', 'apple'), ('林檎', 'apple'),
    ('gelatin', 'gelatin'), ('gelatine', 'gelatin'), ('ゼラチン', 'gelatin'),
    ('shellfish', 'shrimp'), ('shellfish', 'crab'),
    ('crustacean', 'shrimp'), ('crustacean', 'crab'),
    ('crustaceans', 'shrimp'), ('crustaceans', 'crab'),
    ('甲殻類', 'shrimp'), ('甲殻類', 'crab'), ('甲殻', 'shrimp'), ('甲殻', 'crab')
  ) as m(alias, canonical) on m.alias = t.value
  order by m.canonical;
$$;

create or replace function public.fn_allergen_canonical(p_raw text)
returns text language sql immutable security definer set search_path = '' as $$
  select case when count(*) = 1 then min(member) end
  from public.fn_allergen_canonical_members(p_raw) as member;
$$;

create or replace function public.fn_allergen_canonical_allergens(p_allergens text[])
returns text[] language sql immutable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.member order by m.member), '{}'::text[])
  from pg_catalog.unnest(coalesce(p_allergens, '{}'::text[])) as a(raw)
  cross join lateral public.fn_allergen_canonical_members(a.raw) as m(member);
$$;

create or replace function public.fn_allergen_canonical_value(p_value jsonb)
returns text[] language sql immutable security definer set search_path = '' as $$
  select public.fn_allergen_canonical_allergens(
    case when jsonb_typeof(p_value->'allergens') = 'array'
      then array(select jsonb_array_elements_text(p_value->'allergens'))
      else '{}'::text[] end);
$$;

create or replace function public.fn_allergen_value_has_unsupported(p_value jsonb)
returns boolean language sql immutable security definer set search_path = '' as $$
  select jsonb_typeof(p_value->'allergens') is distinct from 'array'
    or exists (
      select 1
      from jsonb_array_elements_text(
        case when jsonb_typeof(p_value->'allergens') = 'array'
          then p_value->'allergens' else '[]'::jsonb end) as raw(value)
      where not exists (
        select 1 from public.fn_allergen_canonical_members(raw.value)));
$$;

create or replace function public.fn_allergen_safe_tag_vocabulary()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array(
    select a || '_free'
    from pg_catalog.unnest(public.fn_allergen_vocabulary()) as a
    order by 1);
$$;

create or replace function public.fn_allergen_canonical_safe_tags(p_tags text[])
returns text[] language sql immutable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.member || '_free' order by m.member || '_free'),
                  '{}'::text[])
  from pg_catalog.unnest(coalesce(p_tags, '{}'::text[])) as t(tag)
  cross join lateral public.fn_allergen_canonical_members(t.tag) as m(member);
$$;

alter table public.restaurant_features
  drop constraint if exists restaurant_features_allergen_safe_tag_vocabulary;

alter table public.participant_constraints disable trigger user;
with canonical as (
  select pc.id,
         jsonb_build_object(
           'allergens', to_jsonb(public.fn_allergen_canonical_value(pc.normalized_value)))
           as after_value,
         public.fn_allergen_value_has_unsupported(pc.normalized_value) as dropped
  from public.participant_constraints pc
  where pc.normalized_type = 'allergy'
)
update public.participant_constraints pc
set normalized_value = c.after_value,
    semantic_remainder = case when c.dropped
      then coalesce(pc.semantic_remainder, nullif(pg_catalog.btrim(pc.raw_text), ''))
      else pc.semantic_remainder end
from canonical c
where pc.id = c.id
  and (pc.normalized_value is distinct from c.after_value
       or (c.dropped and pc.semantic_remainder is null));
alter table public.participant_constraints enable trigger user;

update public.restaurant_features rf
set allergy_safe_tags = public.fn_allergen_canonical_safe_tags(rf.allergy_safe_tags)
where rf.allergy_safe_tags is distinct from
      public.fn_allergen_canonical_safe_tags(rf.allergy_safe_tags);

alter table public.restaurant_features
  add constraint restaurant_features_allergen_safe_tag_vocabulary
  check (allergy_safe_tags is null or allergy_safe_tags <@ array[
    'shrimp_free',
    'cashew_nut_free',
    'crab_free',
    'walnut_free',
    'wheat_free',
    'buckwheat_free',
    'egg_free',
    'milk_free',
    'peanut_free',
    'almond_free',
    'abalone_free',
    'squid_free',
    'salmon_roe_free',
    'orange_free',
    'kiwi_free',
    'beef_free',
    'sesame_free',
    'salmon_free',
    'mackerel_free',
    'soybean_free',
    'chicken_free',
    'banana_free',
    'pistachio_free',
    'pork_free',
    'macadamia_nut_free',
    'peach_free',
    'yam_free',
    'apple_free',
    'gelatin_free'
  ]::text[]);

create or replace function public.fn_allergy_allergens_met(
  p_venue_tags text[], p_value jsonb
) returns boolean language sql immutable security definer set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_value->'allergens') = 'array'
    and coalesce(jsonb_array_length(p_value->'allergens'), 0) > 0
    and coalesce(array_length(p_venue_tags, 1), 0) > 0
    and p_venue_tags @> array(
      select allergen || '_free'
      from jsonb_array_elements_text(p_value->'allergens') as allergen),
    false);
$$;

create or replace function public.fn_budget_value_is_valid(p_value jsonb)
returns boolean language plpgsql immutable security definer set search_path = '' as $$
declare
  v_max int := public.fn_jsonb_int(p_value, 'max_yen');
  v_min int;
begin
  if v_max is null or v_max <= 0 then return false; end if;
  if p_value ? 'min_yen' then
    v_min := public.fn_jsonb_int(p_value, 'min_yen');
    if v_min is null or v_min < 0 or v_min >= v_max then return false; end if;
  end if;
  return true;
end;
$$;

create or replace function public.fn_validate_constraint_value_v2()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.normalized_type = 'budget'
     and not public.fn_budget_value_is_valid(new.normalized_value)
  then
    raise exception using
      errcode = '23514',
      message = 'budget requires max_yen > 0 and optional 0 <= min_yen < max_yen';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_constraint_value_v2 on public.participant_constraints;
create trigger trg_validate_constraint_value_v2
  before insert or update on public.participant_constraints
  for each row execute function public.fn_validate_constraint_value_v2();

create or replace function public.fn_relaxed_value(
  p_normalized_type text, p_normalized_value jsonb
) returns jsonb language plpgsql immutable security definer set search_path = '' as $$
declare
  v_max int;
begin
  if p_normalized_type = 'room' then
    return jsonb_build_object(
      'room', case when p_normalized_value->>'room' = 'private'
        then 'semi_private' else p_normalized_value->>'room' end,
      'accept_unknown', true);
  elsif p_normalized_type = 'travel_time' then
    return jsonb_build_object('max_minutes',
      coalesce(public.fn_jsonb_int(p_normalized_value, 'max_minutes'), 0) + 10);
  elsif p_normalized_type = 'budget' then
    if not public.fn_budget_value_is_valid(p_normalized_value) then
      return p_normalized_value;
    end if;
    v_max := public.fn_jsonb_int(p_normalized_value, 'max_yen');
    if v_max > 2147483147 then return p_normalized_value; end if;
    return p_normalized_value || jsonb_build_object('max_yen', v_max + 500);
  elsif p_normalized_type = 'smoking' then
    return jsonb_build_object(
      'preference', p_normalized_value->>'preference', 'accept_unknown', true);
  end if;
  return p_normalized_value;
end;
$$;

create or replace function public.fn_candidate_blocking_types(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns text[] language plpgsql security definer set search_path = '' as $$
declare
  v_candidate record;
  v_must record;
  v_value jsonb;
  v_preference text;
  v_room text;
  v_blocked text[] := '{}'::text[];
begin
  select rf.* into v_candidate
  from public.restaurant_features rf
  where rf.place_id = p_place_id;
  if not found then return array['unknown_venue']::text[]; end if;

  for v_must in
    select pc.id, pc.participant_id, pc.normalized_type, pc.normalized_value
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST'
  loop
    v_value := case when v_must.id = p_override_constraint_id
      then p_override_value else v_must.normalized_value end;

    if v_must.normalized_type = 'budget' then
      if not public.fn_budget_value_is_valid(v_value)
        or v_candidate.price_yen_estimate is null
        or v_candidate.price_yen_estimate > public.fn_jsonb_int(v_value, 'max_yen')
        or (v_value ? 'min_yen'
            and v_candidate.price_yen_estimate < public.fn_jsonb_int(v_value, 'min_yen'))
      then v_blocked := v_blocked || 'budget'::text; end if;
    elsif v_must.normalized_type = 'room' then
      v_room := v_value->>'room';
      if v_room is null
        or v_room not in ('private','semi_private','open')
        or (v_candidate.room_type is null
            and not public.fn_jsonb_flag(v_value, 'accept_unknown'))
        or (v_candidate.room_type is not null and v_candidate.room_type <> v_room)
      then v_blocked := v_blocked || 'room'::text; end if;
    elsif v_must.normalized_type = 'dietary' then
      if jsonb_typeof(v_value->'tags') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'tags'), 0) = 0
        or coalesce(array_length(v_candidate.dietary_tags, 1), 0) = 0
        or not (v_candidate.dietary_tags @> array(
          select jsonb_array_elements_text(v_value->'tags')))
      then v_blocked := v_blocked || 'dietary'::text; end if;
    elsif v_must.normalized_type = 'allergy' then
      if not public.fn_allergy_allergens_met(v_candidate.allergy_safe_tags, v_value)
      then v_blocked := v_blocked || 'allergy'::text; end if;
    elsif v_must.normalized_type = 'accessibility' then
      if not public.fn_accessibility_needs_met(v_candidate.accessibility_tags, v_value)
      then v_blocked := v_blocked || 'accessibility'::text; end if;
    elsif v_must.normalized_type = 'smoking' then
      v_preference := v_value->>'preference';
      if v_preference is null
        or v_preference not in ('non_smoking','smoking_ok')
        or (v_candidate.smoking_policy is null
            and not public.fn_jsonb_flag(v_value, 'accept_unknown'))
        or (v_candidate.smoking_policy is not null
            and v_candidate.smoking_policy <> v_preference)
      then v_blocked := v_blocked || 'smoking'::text; end if;
    elsif v_must.normalized_type = 'travel_time' then
      if coalesce(public.fn_travel_minutes(p_event_id, p_place_id, v_must.participant_id), 9999)
        > public.fn_jsonb_int(v_value, 'max_minutes')
      then v_blocked := v_blocked || 'travel_time'::text; end if;
    end if;
  end loop;

  return coalesce(
    (select array_agg(distinct t order by t) from pg_catalog.unnest(v_blocked) as t),
    '{}'::text[]);
end;
$$;

create or replace function public.fn_candidate_is_feasible(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  return coalesce(array_length(public.fn_candidate_blocking_types(
    p_event_id, p_place_id, p_override_constraint_id, p_override_value), 1), 0) = 0;
end;
$$;

alter table public.event_restaurant_candidates
  add column if not exists scope_generation uuid;

create table if not exists public.event_candidate_scopes (
  event_id uuid primary key references public.events(id) on delete cascade,
  generation uuid not null,
  initialized_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.event_candidate_scopes enable row level security;
revoke all on table public.event_candidate_scopes from anon, authenticated, service_role;
grant select on table public.event_candidate_scopes to service_role;

insert into public.event_candidate_scopes (event_id, generation)
select distinct erc.event_id, gen_random_uuid()
from public.event_restaurant_candidates erc
on conflict (event_id) do nothing;

update public.event_restaurant_candidates erc
set scope_generation = scope.generation
from public.event_candidate_scopes scope
where scope.event_id = erc.event_id
  and erc.scope_generation is distinct from scope.generation;

create or replace function public.fn_prepare_event_candidate_scope()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_generation uuid;
begin
  insert into public.event_candidate_scopes as scope (event_id, generation)
  values (new.event_id, gen_random_uuid())
  on conflict (event_id) do update set event_id = excluded.event_id
  returning scope.generation into v_generation;
  if new.scope_generation is null then new.scope_generation := v_generation; end if;
  return new;
end;
$$;

drop trigger if exists trg_prepare_event_candidate_scope
  on public.event_restaurant_candidates;
create trigger trg_prepare_event_candidate_scope
  before insert on public.event_restaurant_candidates
  for each row execute function public.fn_prepare_event_candidate_scope();

create or replace function public.fn_record_provider_candidates_v2(
  p_event_id uuid, p_candidates jsonb
) returns int language plpgsql security definer set search_path = '' as $$
declare
  v_active text[];
  v_count int;
begin
  select coalesce(array_agg(erc.place_id), '{}'::text[]) into v_active
  from public.event_candidate_scopes scope
  join public.event_restaurant_candidates erc
    on erc.event_id = scope.event_id
   and erc.scope_generation = scope.generation
  where scope.event_id = p_event_id;

  v_count := public.fn_record_provider_candidates(p_event_id, p_candidates);

  if p_candidates is not null and jsonb_typeof(p_candidates) = 'array' then
    update public.event_restaurant_candidates erc
    set scope_generation = null
    where erc.event_id = p_event_id
      and erc.place_id in (
        select distinct candidate->>'place_id'
        from jsonb_array_elements(p_candidates) candidate
        where nullif(candidate->>'place_id', '') is not null)
      and not (erc.place_id = any(v_active));
  end if;

  return v_count;
end;
$$;

create or replace function public.fn_replace_event_candidate_scope(
  p_event_id uuid, p_place_ids text[]
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_generation uuid := gen_random_uuid();
  v_count int;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may replace an event candidate scope';
  end if;
  if not exists (select 1 from public.events e where e.id = p_event_id) then
    raise exception 'event % not found', p_event_id;
  end if;
  if exists (
    select 1 from pg_catalog.unnest(coalesce(p_place_ids, '{}'::text[])) as requested(place_id)
    where nullif(pg_catalog.btrim(requested.place_id), '') is null
  ) then
    raise exception 'candidate place ids must be non-empty';
  end if;
  if exists (
    select 1
    from (select distinct place_id
          from pg_catalog.unnest(coalesce(p_place_ids, '{}'::text[])) as ids(place_id)) requested
    left join public.restaurants r on r.place_id = requested.place_id
    where r.place_id is null
  ) then
    raise exception 'candidate scope contains an unknown restaurant';
  end if;

  insert into public.event_candidate_scopes as scope (
    event_id, generation, initialized_at, updated_at
  ) values (p_event_id, v_generation, now(), now())
  on conflict (event_id) do update
    set generation = excluded.generation,
        updated_at = now();

  delete from public.event_restaurant_candidates erc
  where erc.event_id = p_event_id
    and not (erc.place_id = any(coalesce(p_place_ids, '{}'::text[])));

  insert into public.event_restaurant_candidates as erc (
    event_id, place_id, discovered_at, scope_generation
  )
  select p_event_id, requested.place_id, now(), v_generation
  from (select distinct place_id
        from pg_catalog.unnest(coalesce(p_place_ids, '{}'::text[])) as ids(place_id)) requested
  on conflict (event_id, place_id) do update
    set scope_generation = excluded.scope_generation;

  select count(*) into v_count
  from public.event_restaurant_candidates erc
  where erc.event_id = p_event_id
    and erc.scope_generation = v_generation;

  return jsonb_build_object(
    'generation', v_generation,
    'candidate_count', v_count);
end;
$$;

create or replace function public.fn_event_candidate_place_ids(p_event_id uuid)
returns table (place_id text)
language sql stable security definer set search_path = '' as $$
  select r.place_id
  from public.restaurants r
  join public.restaurant_features rf on rf.place_id = r.place_id
  where not exists (
    select 1 from public.event_candidate_scopes scope where scope.event_id = p_event_id)
  union all
  select r.place_id
  from public.event_candidate_scopes scope
  join public.event_restaurant_candidates erc
    on erc.event_id = scope.event_id
   and erc.scope_generation = scope.generation
  join public.restaurants r on r.place_id = erc.place_id
  join public.restaurant_features rf on rf.place_id = r.place_id
  where scope.event_id = p_event_id;
$$;

create or replace function public.fn_count_unlocked_if_relaxed(
  p_event_id uuid, p_constraint_id uuid
) returns int language plpgsql security definer set search_path = '' as $$
declare
  v_constraint record;
  v_relaxed jsonb;
  v_baseline int;
  v_relaxed_count int;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;

  select pc.normalized_type, pc.normalized_value into v_constraint
  from public.participant_constraints pc
  where pc.id = p_constraint_id and pc.event_id = p_event_id;
  if not found then raise exception 'constraint not found'; end if;

  v_relaxed := public.fn_relaxed_value(
    v_constraint.normalized_type, v_constraint.normalized_value);
  select count(*) filter (where public.fn_candidate_is_feasible(p_event_id, c.place_id)),
         count(*) filter (where public.fn_candidate_is_feasible(
           p_event_id, c.place_id, p_constraint_id, v_relaxed))
  into v_baseline, v_relaxed_count
  from public.fn_event_candidate_place_ids(p_event_id) c;
  return v_relaxed_count - v_baseline;
end;
$$;

create or replace function public.fn_recompute_feasibility(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_run_id uuid;
  v_feasible_count int := 0;
  v_unverified_count int := 0;
  v_allergy_unverified_count int := 0;
  v_candidate record;
  v_blocked text[];
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;

  for v_candidate in
    select c.place_id
    from public.fn_event_candidate_place_ids(p_event_id) c
    order by c.place_id
  loop
    v_blocked := public.fn_candidate_blocking_types(p_event_id, v_candidate.place_id);
    if coalesce(array_length(v_blocked, 1), 0) = 0 then
      v_feasible_count := v_feasible_count + 1;
    elsif v_blocked = array['accessibility']::text[] then
      v_unverified_count := v_unverified_count + 1;
    elsif v_blocked = array['allergy']::text[] then
      v_allergy_unverified_count := v_allergy_unverified_count + 1;
    end if;
  end loop;

  insert into public.recommendation_runs (event_id, feasible_count, input_snapshot)
  values (p_event_id, v_feasible_count, jsonb_build_object('must_count',
    (select count(*) from public.participant_constraints
     where event_id = p_event_id and kind = 'MUST')))
  returning id into v_run_id;

  if v_feasible_count > 0 then
    perform public.fn_score_feasible_candidates(v_run_id, p_event_id);
  end if;
  perform public.fn_refresh_event_status(p_event_id, v_feasible_count);

  return jsonb_build_object(
    'run_id', v_run_id,
    'feasible_count', v_feasible_count,
    'accessibility_unverified_count', v_unverified_count,
    'allergy_unverified_count', v_allergy_unverified_count);
end;
$$;

create or replace function public.fn_score_feasible_candidates(
  p_run_id uuid, p_event_id uuid
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_want_count int;
  v_objective text;
  v_weights jsonb;
  v_label text;
begin
  select count(*) into v_want_count
  from public.participant_constraints
  where event_id = p_event_id and kind = 'WANT';
  select coalesce(e.objective, 'balanced') into v_objective
  from public.events e where e.id = p_event_id;
  v_weights := public.fn_objective_weights(coalesce(v_objective, 'balanced'));

  with cand as (
    select rf.place_id,
      (select count(*) from public.participant_constraints pc
       where pc.event_id = p_event_id and pc.kind = 'WANT'
       and (
         (pc.normalized_type = 'cuisine'
          and ((
            coalesce(jsonb_array_length(pc.normalized_value->'include'), 0) = 0
            or coalesce(rf.cuisine_tags, '{}'::text[]) && array(
              select jsonb_array_elements_text(pc.normalized_value->'include'))
          ) and not (
            coalesce(rf.cuisine_tags, '{}'::text[]) && array(
              select jsonb_array_elements_text(pc.normalized_value->'exclude'))
          )))
         or
         (pc.normalized_type = 'atmosphere'
          and coalesce(rf.atmosphere_tags, '{}'::text[]) && array(
            select jsonb_array_elements_text(pc.normalized_value->'tags')))
       )) as wants_matched,
      public.fn_travel_profile(p_event_id, rf.place_id) as travel,
      rf.rating, rf.user_rating_count, rf.atmosphere_tags,
      rf.tabelog_rating, rf.tabelog_review_count,
      public.fn_provider_quality_shrunk(rf.rating, rf.user_rating_count,
        public.fn_quality_prior_rating('google')) as google_value,
      public.fn_provider_quality_shrunk(rf.tabelog_rating, rf.tabelog_review_count,
        public.fn_quality_prior_rating('tabelog')) as tabelog_value,
      public.fn_cost_burden(p_event_id, rf.price_yen_estimate) as cost,
      public.fn_accessibility_burden(p_event_id, rf.accessibility_tags) as accessibility
    from public.fn_event_candidate_place_ids(p_event_id) c
    join public.restaurant_features rf on rf.place_id = c.place_id
    where public.fn_candidate_is_feasible(p_event_id, c.place_id)
  ), google_rank as (
    select c.place_id,
      round((2 * (rank() over (order by c.google_value) - 1)
             + count(*) over (partition by c.google_value))::numeric
            / (2 * count(*) over ()), 4) as percentile,
      (count(*) over ())::int as ranked
    from cand c where c.google_value is not null
  ), tabelog_rank as (
    select c.place_id,
      round((2 * (rank() over (order by c.tabelog_value) - 1)
             + count(*) over (partition by c.tabelog_value))::numeric
            / (2 * count(*) over ()), 4) as percentile,
      (count(*) over ())::int as ranked
    from cand c where c.tabelog_value is not null
  ), comp as (
    select c.place_id, c.travel, c.cost, c.accessibility,
      public.fn_quality_signal_blended(
        c.rating, c.user_rating_count, g.percentile, coalesce(g.ranked, 0),
        c.tabelog_rating, c.tabelog_review_count, t.percentile, coalesce(t.ranked, 0),
        c.atmosphere_tags) as quality,
      (c.travel->>'fairness')::numeric as travel_fairness,
      (c.travel->>'access')::numeric as travel_access,
      case when v_want_count = 0 then 1.0
        else round(c.wants_matched::numeric / v_want_count, 4) end as satisfaction,
      round(1 - (c.cost->>'burden')::numeric, 4) as cost_fit,
      round(1 - (c.accessibility->>'burden')::numeric, 4) as accessibility_fit
    from cand c
    left join google_rank g on g.place_id = c.place_id
    left join tabelog_rank t on t.place_id = c.place_id
  ), graded as (
    select comp.*, (comp.quality->>'score')::numeric as quality_score from comp
  ), scored as (
    select graded.*,
      round((v_weights->>'travel_fairness')::numeric * graded.travel_fairness, 4) as c_fairness,
      round((v_weights->>'travel_access')::numeric * graded.travel_access, 4) as c_access,
      round((v_weights->>'satisfaction')::numeric * graded.satisfaction, 4) as c_satisfaction,
      round((v_weights->>'quality')::numeric * graded.quality_score, 4) as c_quality,
      round((v_weights->>'cost_fit')::numeric * graded.cost_fit, 4) as c_cost,
      round((v_weights->>'accessibility_fit')::numeric * graded.accessibility_fit, 4)
        as c_access_fit,
      round((v_weights->>'travel_fairness')::numeric * graded.travel_fairness
          + (v_weights->>'travel_access')::numeric * graded.travel_access
          + (v_weights->>'satisfaction')::numeric * graded.satisfaction
          + (v_weights->>'quality')::numeric * graded.quality_score
          + (v_weights->>'cost_fit')::numeric * graded.cost_fit
          + (v_weights->>'accessibility_fit')::numeric * graded.accessibility_fit, 4)
        as objective_score
    from graded
  )
  insert into public.recommendation_scores
    (run_id, restaurant_place_id, fairness_score, satisfaction_score, quality_score,
     cost_burden_score, accessibility_burden_score, objective_score, score_breakdown,
     explanation)
  select p_run_id, s.place_id, s.travel_fairness, s.satisfaction, s.quality_score,
    (s.cost->>'burden')::numeric, (s.accessibility->>'burden')::numeric, s.objective_score,
    jsonb_build_object(
      'version', 1,
      'objective', coalesce(v_objective, 'balanced'),
      'scale', jsonb_build_object(
        'components', '0..1, higher is better', 'burdens', '0..1, higher is worse'),
      'weights', v_weights,
      'components', jsonb_build_object(
        'travel_fairness', s.travel_fairness, 'travel_access', s.travel_access,
        'satisfaction', s.satisfaction, 'quality', s.quality_score,
        'cost_fit', s.cost_fit, 'accessibility_fit', s.accessibility_fit),
      'contributions', jsonb_build_object(
        'travel_fairness', s.c_fairness, 'travel_access', s.c_access,
        'satisfaction', s.c_satisfaction, 'quality', s.c_quality,
        'cost_fit', s.c_cost, 'accessibility_fit', s.c_access_fit),
      'objective_score', s.objective_score,
      'travel', s.travel, 'quality', s.quality, 'cost', s.cost,
      'accessibility', s.accessibility),
    null
  from scored s
  order by s.objective_score desc nulls last, s.place_id
  limit 5;

  for v_label in select unnest(array[
    'fairest', 'best_access', 'best_value', 'best_experience', 'crowd_pleaser'])
  loop
    update public.recommendation_scores s set label = v_label
    where s.id = (
      with m as (
        select s2.id, s2.label, s2.restaurant_place_id,
          case v_label
            when 'fairest' then s2.fairness_score
            when 'best_access' then (s2.score_breakdown->'components'->>'travel_access')::numeric
            when 'best_value' then (s2.score_breakdown->'components'->>'cost_fit')::numeric
            when 'best_experience' then s2.quality_score
            else s2.satisfaction_score
          end as metric
        from public.recommendation_scores s2 where s2.run_id = p_run_id
      ), agg as (select max(m.metric) as best, count(*) as total from m),
      lead_count as (select count(*) as leaders from m, agg where m.metric = agg.best)
      select m.id from m, agg, lead_count
      where m.metric = agg.best and lead_count.leaders < agg.total and m.label is null
      order by m.restaurant_place_id limit 1);
  end loop;
end;
$$;

revoke execute on function public.fn_allergen_vocabulary() from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_members(text)
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical(text) from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_allergens(text[])
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_value(jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_value_has_unsupported(jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_safe_tag_vocabulary()
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_safe_tags(text[])
  from public, anon, authenticated;
revoke execute on function public.fn_allergy_allergens_met(text[], jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_budget_value_is_valid(jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_validate_constraint_value_v2()
  from public, anon, authenticated;
revoke execute on function public.fn_relaxed_value(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_blocking_types(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_prepare_event_candidate_scope()
  from public, anon, authenticated;
revoke execute on function public.fn_record_provider_candidates_v2(uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_replace_event_candidate_scope(uuid, text[])
  from public, anon, authenticated;
revoke execute on function public.fn_event_candidate_place_ids(uuid)
  from public, anon, authenticated;
revoke execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.fn_score_feasible_candidates(uuid, uuid)
  from public, anon, authenticated;


grant execute on function public.fn_allergen_vocabulary() to service_role;
grant execute on function public.fn_allergen_canonical_members(text) to service_role;
grant execute on function public.fn_allergen_canonical(text) to service_role;
grant execute on function public.fn_allergen_canonical_allergens(text[]) to service_role;
grant execute on function public.fn_allergen_canonical_value(jsonb) to service_role;
grant execute on function public.fn_allergen_value_has_unsupported(jsonb) to service_role;
grant execute on function public.fn_allergen_safe_tag_vocabulary() to service_role;
grant execute on function public.fn_allergen_canonical_safe_tags(text[]) to service_role;
grant execute on function public.fn_allergy_allergens_met(text[], jsonb) to service_role;
grant execute on function public.fn_budget_value_is_valid(jsonb) to service_role;
grant execute on function public.fn_validate_constraint_value_v2() to service_role;
grant execute on function public.fn_relaxed_value(text, jsonb) to service_role;
grant execute on function public.fn_candidate_blocking_types(uuid, text, uuid, jsonb)
  to service_role;
grant execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  to service_role;
grant execute on function public.fn_prepare_event_candidate_scope() to service_role;
grant execute on function public.fn_record_provider_candidates_v2(uuid, jsonb) to service_role;
grant execute on function public.fn_replace_event_candidate_scope(uuid, text[]) to service_role;
grant execute on function public.fn_event_candidate_place_ids(uuid) to service_role;
grant execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid) to service_role;
grant execute on function public.fn_score_feasible_candidates(uuid, uuid) to service_role;
