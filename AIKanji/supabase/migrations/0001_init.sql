create extension if not exists pgcrypto;
create extension if not exists postgis;
create extension if not exists vector;

create table events (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text unique not null default substr(md5(random()::text), 1, 6),
  organizer_participant_id uuid,
  objective text not null default 'balanced'
    check (objective in ('balanced','access','cost','experience','custom')),
  status text not null default 'collecting'
    check (status in ('collecting','negotiating','ready','closed')),
  created_at timestamptz not null default now()
);

create table participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  auth_user_id uuid not null,
  display_name text not null,
  role text not null default 'participant' check (role in ('organizer','participant')),
  travel_reference text check (travel_reference in ('office','home','station','doesnt_matter')),
  travel_reference_place_id text,
  joined_at timestamptz not null default now(),
  unique (event_id, auth_user_id)
);

alter table events add constraint fk_organizer
  foreign key (organizer_participant_id) references participants(id);

create table participant_constraints (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  participant_id uuid not null references participants(id) on delete cascade,
  kind text not null check (kind in ('MUST','WANT')),
  raw_text text not null,
  normalized_type text not null default 'other'
    check (normalized_type in ('budget','cuisine','dietary','allergy','smoking',
                                'room','travel_time','accessibility','atmosphere','other')),
  normalized_value jsonb not null default '{}',
  visibility text not null default 'PUBLIC' check (visibility in ('PUBLIC','ANONYMOUS','PRIVATE')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table negotiations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  constraint_id uuid not null references participant_constraints(id) on delete cascade,
  participant_id uuid not null references participants(id) on delete cascade,
  proposed_value jsonb not null,
  unlocked_count int not null default 0,
  status text not null default 'PROPOSED' check (status in ('PROPOSED','ACCEPTED','REJECTED')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);

create table restaurants (
  place_id text primary key,
  hotpepper_id text,
  last_fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table restaurant_features (
  place_id text primary key references restaurants(place_id) on delete cascade,
  price_yen_estimate int,
  room_type text check (room_type in ('private','semi_private','open')),
  cuisine_tags text[] default '{}',
  dietary_tags text[] default '{}',
  allergy_safe_tags text[] default '{}',
  atmosphere_tags text[] default '{}',
  travel_minutes_by_participant jsonb not null default '{}',
  fetched_at timestamptz not null default now()
);

create table recommendation_runs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  run_at timestamptz not null default now(),
  feasible_count int not null,
  input_snapshot jsonb not null
);

create table recommendation_scores (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references recommendation_runs(id) on delete cascade,
  restaurant_place_id text not null references restaurants(place_id),
  fairness_score numeric,
  satisfaction_score numeric,
  quality_score numeric,
  label text check (label in ('fairest','best_access','best_value','best_experience','crowd_pleaser')),
  explanation text
);
