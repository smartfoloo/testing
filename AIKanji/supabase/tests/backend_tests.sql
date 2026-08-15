-- Backend acceptance tests for the schema, RLS, sanitized feed, feasibility
-- engine and negotiation RPCs. Run with supabase/tests/run.sh.
--
-- Each check appends a row to test_results; the final select prints them and
-- the script exits non-zero if anything failed.

\set ON_ERROR_STOP on
\set QUIET on

create table if not exists test_results (
  seq serial primary key,
  name text not null,
  passed boolean not null,
  detail text
);
truncate test_results restart identity;

-- `test_results` is the harness's own bookkeeping, not part of the schema — but most
-- blocks below call t_check while impersonating (`t_as_user`), so the impersonated role
-- has to be able to append to it. On a database that behaves the way Supabase now does
-- by default (new entities in `public` are NOT auto-exposed to the Data API roles — see
-- 0024_table_privileges.sql) a table created by `postgres` grants those roles nothing,
-- and this suite could not record its very first result: `permission denied for table
-- test_results` on check 1, whatever the schema itself does.
--
-- Stated explicitly rather than inherited from whatever default privileges the host
-- database happens to carry, because that inheritance is precisely what hid the missing
-- table grants for twenty-three migrations. It cannot mask anything: the privilege
-- assertions in the 0024 blocks below scope themselves to RLS-protected app tables, and
-- this is neither.
grant insert, select on table test_results to authenticated, service_role;
grant usage, select on sequence test_results_seq_seq to authenticated, service_role;

create or replace function t_check(p_name text, p_passed boolean, p_detail text default null)
returns void language plpgsql as $$
begin
  insert into test_results (name, passed, detail) values (p_name, p_passed, p_detail);
end; $$;

-- Impersonate an end user the way PostgREST does.
create or replace function t_as_user(p_uid uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  execute 'set role authenticated';
end; $$;

create or replace function t_as_admin()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', false);
end; $$;

-- ---------------------------------------------------------------------------
-- Create / join flow
-- ---------------------------------------------------------------------------
do $$
declare
  v_created jsonb;
  v_event_id uuid;
  v_code text;
  v_alice uuid := '11111111-1111-1111-1111-111111111111';
  v_bob uuid := '22222222-2222-2222-2222-222222222222';
  v_alice_pid uuid;
  v_bob_pid uuid;
  v_role text;
  v_organizer uuid;
  v_raised boolean := false;
begin
  perform t_as_user(v_alice);
  v_created := fn_create_event('QA 飲み会', 'Alice', 'office', null, 'balanced');
  v_event_id := (v_created->>'event_id')::uuid;
  v_code := v_created->>'invite_code';
  perform t_check('fn_create_event returns an event id',
                  v_event_id is not null, v_created::text);
  perform t_check('invite code is 6 alphanumeric characters',
                  v_code ~ '^[0-9a-z]{6}$', v_code);

  v_alice_pid := fn_join_event(v_code, 'Alice', 'office');
  perform t_check('re-joining is idempotent for the creator',
                  v_alice_pid = (v_created->>'participant_id')::uuid,
                  v_alice_pid::text);
  perform t_as_user(v_bob);
  v_bob_pid := fn_join_event(v_code, 'Bob', 'station');

  perform t_as_admin();
  select role into v_role from participants where id = v_alice_pid;
  perform t_check('creator is the organizer', v_role = 'organizer', v_role);
  select role into v_role from participants where id = v_bob_pid;
  perform t_check('joiner becomes participant', v_role = 'participant', v_role);
  select organizer_participant_id into v_organizer from events where id = v_event_id;
  perform t_check('event points at the organizer participant',
                  v_organizer = v_alice_pid, v_organizer::text);
  perform t_check('two participants on one event',
                  (select count(*) from participants where event_id = v_event_id) = 2);

  begin
    perform t_as_user(v_bob);
    perform fn_join_event('ZZZZZZ', 'Mallory', 'home');
  exception when others then
    v_raised := true;
  end;
  perform t_as_admin();
  perform t_check('unknown invite code is rejected', v_raised);

  -- Constraints used by the RLS and feed checks below.
  perform t_as_user(v_alice);
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event_id, v_alice_pid, 'MUST', 'budget under 4000 yen',
          'budget', '{"max_yen":4000}', 'PUBLIC');

  perform t_as_user(v_bob);
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event_id, v_bob_pid, 'MUST', 'vegetarian options',
          'dietary', '{"tags":["vegetarian"]}', 'ANONYMOUS');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event_id, v_bob_pid, 'MUST', 'not sharing this one',
          'other', '{}', 'PRIVATE');

  -- RLS: a participant only ever sees their own raw constraint rows...
  perform t_as_user(v_alice);
  perform t_check('RLS hides other participants raw constraints',
                  (select count(*) from participant_constraints
                   where event_id = v_event_id) = 1);

  -- ...and cannot write a row attributed to somebody else.
  v_raised := false;
  begin
    insert into participant_constraints (event_id, participant_id, kind, raw_text)
    values (v_event_id, v_bob_pid, 'MUST', 'forged on Bob''s behalf');
  exception when others then
    v_raised := true;
  end;
  perform t_check('RLS blocks writing a constraint for another participant', v_raised);

  -- Sanitized feed.
  perform t_check('feed excludes PRIVATE rows',
                  (select count(*) from fn_get_sanitized_feed(v_event_id)) = 2);
  perform t_check('ANONYMOUS row carries no display name',
                  (select display_name is null from fn_get_sanitized_feed(v_event_id)
                   where visibility = 'ANONYMOUS'));
  perform t_check('PUBLIC row carries the display name',
                  (select display_name from fn_get_sanitized_feed(v_event_id)
                   where visibility = 'PUBLIC') = 'Alice');

  v_raised := false;
  begin
    perform set_config('request.jwt.claim.sub',
                       '33333333-3333-3333-3333-333333333333', false);
    perform fn_get_sanitized_feed(v_event_id);
  exception when others then
    v_raised := true;
  end;
  perform t_check('feed rejects a non-participant', v_raised);

  -- Broadcast: PUBLIC/ANONYMOUS are sent to the private topic, PRIVATE never is.
  perform t_as_admin();
  perform t_check('two constraint broadcasts on the event topic',
                  (select count(*) from realtime.messages
                   where topic = 'event-' || v_event_id::text
                     and event = 'constraint_added') = 2);
  perform t_check('PRIVATE constraint is never broadcast',
                  not exists (select 1 from realtime.messages
                              where payload->>'visibility' = 'PRIVATE'));
  perform t_check('ANONYMOUS broadcast payload has a null display_name',
                  (select payload->>'display_name' is null from realtime.messages
                   where topic = 'event-' || v_event_id::text
                     and payload->>'visibility' = 'ANONYMOUS'));

  perform t_as_user(v_alice);
  perform t_check('aggregate response count covers every participant',
                  fn_get_response_count(v_event_id) = 3);
  perform t_as_admin();
end $$;

-- ---------------------------------------------------------------------------
-- Feasibility + negotiation, against the deterministic seed fixture
-- ---------------------------------------------------------------------------
do $$
declare
  v_event_id uuid := '00000000-0000-0000-0000-000000000001';
  v_bob_pid uuid := '00000000-0000-0000-0000-0000000000b1';
  v_bob_uid uuid := '44444444-4444-4444-4444-444444444444';
  v_result jsonb;
  v_neg_id uuid;
  v_neg negotiations%rowtype;
  v_type text;
  v_raised boolean := false;
begin
  perform t_as_admin();
  update participants set auth_user_id = v_bob_uid where id = v_bob_pid;

  v_result := fn_recompute_feasibility(v_event_id);
  perform t_check('seed fixture starts with zero feasible restaurants',
                  (v_result->>'feasible_count')::int = 0, v_result::text);

  v_neg_id := fn_propose_relaxation(v_event_id);
  perform t_check('a relaxation is proposed', v_neg_id is not null);
  select * into v_neg from negotiations where id = v_neg_id;
  select normalized_type into v_type from participant_constraints
    where id = v_neg.constraint_id;
  perform t_check('relaxation targets the room MUST', v_type = 'room', v_type);
  perform t_check('proposal relaxes private room to semi_private',
                  v_neg.proposed_value->>'room' = 'semi_private',
                  v_neg.proposed_value::text);
  perform t_check('proposal unlocks three restaurants',
                  v_neg.unlocked_count = 3, v_neg.unlocked_count::text);
  perform t_check('allergy and dietary MUSTs are never proposed for relaxation',
                  v_type not in ('allergy', 'dietary', 'accessibility'), v_type);

  -- Only the targeted participant may respond.
  perform t_as_user('55555555-5555-5555-5555-555555555555');
  begin
    perform fn_respond_negotiation(v_neg_id, true);
  exception when others then
    v_raised := true;
  end;
  perform t_check('a non-participant cannot answer a negotiation', v_raised);

  perform t_as_user(v_bob_uid);
  v_result := fn_respond_negotiation(v_neg_id, true);
  perform t_check('accepting the relaxation unlocks three feasible restaurants',
                  (v_result->>'feasible_count')::int = 3, v_result::text);

  perform t_as_admin();
  perform t_check('accepted negotiation rewrites the underlying MUST',
                  (select normalized_value->>'room' from participant_constraints
                   where id = v_neg.constraint_id) = 'semi_private');
  perform t_check('negotiation is marked accepted',
                  (select status from negotiations where id = v_neg_id) = 'ACCEPTED');
  -- Both runs share run_at inside this transaction, so use the id the RPC returned.
  perform t_check('every feasible candidate is scored',
                  (select count(*) from recommendation_scores
                   where run_id = (v_result->>'run_id')::uuid) = 3);
  -- Labels are earned, not distributed. Only David has seeded travel legs, so every
  -- venue ties on travel fairness and no venue is demonstrably 'fairest' — that badge
  -- goes unused rather than being handed to an arbitrary row (which is what the earlier
  -- greedy assignment did: it once labelled a 75-minute commute 'best_access'). Assert
  -- the invariant instead of a fixed count, since the count legitimately depends on how
  -- much provider data has been gathered.
  perform t_check('no label is applied twice',
                  (select count(distinct label) = count(label)
                   from recommendation_scores
                   where run_id = (v_result->>'run_id')::uuid and label is not null));
  perform t_check('at least one candidate carries a differentiating label',
                  (select count(*) from recommendation_scores
                   where run_id = (v_result->>'run_id')::uuid
                     and label is not null) >= 1);
  perform t_check('recommendation run is broadcast to the event topic',
                  (select count(*) from realtime.messages
                   where topic = 'event-' || v_event_id::text
                     and event = 'run_updated') >= 1);
end $$;

-- ---------------------------------------------------------------------------
-- Seeded provider cache (0017): the demo event is a guaranteed cache hit, so
-- 「条件に合うお店を探す」 needs no provider call and therefore no travel origin.
-- restaurant-search only requires an origin when discovery has to run, so these
-- rows are what makes the five-persona demo work on a hosted project.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event_id uuid := '00000000-0000-0000-0000-000000000001';
  v_bob_pid uuid := '00000000-0000-0000-0000-0000000000b1';
  v_david_pid uuid := '00000000-0000-0000-0000-0000000000d1';
  v_bob_room_id uuid;
  v_result jsonb;
  v_places text[];
  v_baseline int;
begin
  perform t_as_admin();

  perform t_check('demo event has a cached candidate row per seeded venue',
                  (select array_agg(place_id order by place_id)
                   from event_restaurant_candidates where event_id = v_event_id)
                  = array['demo_place_001','demo_place_002','demo_place_003',
                          'demo_place_004'],
                  (select string_agg(place_id, ',' order by place_id)
                   from event_restaurant_candidates where event_id = v_event_id));

  -- Freshness is the whole point: the Edge Function skips Places and Hot Pepper
  -- only for candidates inside its DISCOVERY_TTL_MINUTES (6h) window.
  perform t_check('seeded candidates are fresh inside the 6h discovery TTL',
                  (select min(discovered_at) > now() - interval '6 hours'
                   from event_restaurant_candidates where event_id = v_event_id));

  -- Only David has a measured commute in the fixture; a leg for anybody else
  -- would be an invented travel time.
  perform t_check('demo travel cache holds exactly David''s four legs',
                  (select count(*) = 4
                          and count(*) filter (where participant_id = v_david_pid) = 4
                   from travel_matrix_cache where event_id = v_event_id),
                  (select count(*)::text from travel_matrix_cache
                   where event_id = v_event_id));

  -- Inside TRAVEL_TTL_MINUTES (24h), so every leg the function could want is
  -- already there and Routes is never called.
  perform t_check('seeded travel legs are fresh inside the 24h travel TTL',
                  (select min(fetched_at) > now() - interval '24 hours'
                   from travel_matrix_cache where event_id = v_event_id));

  -- 0017 keeps `restaurant_features.travel_minutes_by_participant` as
  -- fn_travel_minutes' fallback, so the two paths must agree: a mismatch would
  -- mean the fixture changed meaning depending on which one was read.
  perform t_check('cached legs agree with the legacy JSONB for David',
                  not exists (
                    select 1 from travel_matrix_cache c
                    join restaurant_features rf on rf.place_id = c.place_id
                    where c.event_id = v_event_id
                      and c.participant_id = v_david_pid
                      and (rf.travel_minutes_by_participant
                             ->> c.participant_id::text)::int
                          is distinct from c.minutes));
  perform t_check('fn_travel_minutes serves David from the event-scoped cache',
                  fn_travel_minutes(v_event_id, 'demo_place_001', v_david_pid) = 20,
                  fn_travel_minutes(v_event_id, 'demo_place_001', v_david_pid)::text);

  -- The state the reordered function has to tolerate: this fixture resolves ZERO
  -- travel origins (no persona has a travel_reference_place_id, and a fake one
  -- would only buy a failing Places lookup), and the search must still succeed
  -- from cache instead of returning 422.
  perform t_check('no demo persona has a travel reference place id',
                  (select count(*) from participants
                   where event_id = v_event_id
                     and travel_reference_place_id is not null) = 0);

  select id into v_bob_room_id from participant_constraints
   where event_id = v_event_id and participant_id = v_bob_pid
     and normalized_type = 'room';

  -- The 0-then-3 invariant, re-asserted with the cache in place. Baseline uses
  -- the same override path fn_propose_relaxation uses, so Bob's MUST is read back
  -- as 'private' without mutating the row the block above already relaxed.
  select count(*) into v_baseline
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event_id, r.place_id, v_bob_room_id,
                                  '{"room":"private"}'::jsonb);
  perform t_check('seeded cache keeps zero feasible venues at baseline',
                  v_baseline = 0, v_baseline::text);

  v_result := fn_recompute_feasibility(v_event_id);
  perform t_check('seeded cache keeps exactly three feasible venues after the relaxation',
                  (v_result->>'feasible_count')::int = 3, v_result::text);
  -- 0022's new key is 0 here: the five personas state no accessibility MUST, so no venue is
  -- excluded for unverified accessibility and the demo payload is unchanged in meaning.
  perform t_check('and the demo reports no accessibility-only exclusions',
                  (v_result->>'accessibility_unverified_count')::int = 0, v_result::text);

  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event_id, r.place_id);
  perform t_check('the feasible three are 001, 002 and 004 — never 003',
                  v_places = array['demo_place_001','demo_place_002',
                                   'demo_place_004'],
                  v_places::text);
end $$;

-- ---------------------------------------------------------------------------
-- 0021: MUST coverage for accessibility and smoking.
--
-- Both types used to fall through the if/elsif chain in fn_candidate_is_feasible and were
-- therefore SILENTLY MET. Every scratch venue below carries a unique dietary tag and its
-- event requires that tag, so the global `restaurants` pool (the demo fixture, and the other
-- scratch venues) can never be feasible for these events and these venues can never be
-- feasible for the demo event — the 0-then-3 invariant is re-asserted at the end regardless.
-- ---------------------------------------------------------------------------
do $$
declare
  v_access_event uuid := '00210000-0000-0000-0000-00000000a000';
  v_access_pid uuid := '00210000-0000-0000-0000-00000000a001';
  v_smoke_event uuid := '00210000-0000-0000-0000-00000000b000';
  v_smoke_pid uuid := '00210000-0000-0000-0000-00000000b001';
  v_smoke_uid uuid := '66666666-6666-6666-6666-666666666666';
  v_access_need_id uuid;
  v_smoke_id uuid;
  v_neg_id uuid;
  v_neg negotiations%rowtype;
  v_result jsonb;
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_access_event, 'QA accessibility', 'balanced', 'collecting'),
         (v_smoke_event, 'QA smoking', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_access_pid, v_access_event, gen_random_uuid(), 'Wheelchair user', 'organizer', 'station'),
         (v_smoke_pid, v_smoke_event, v_smoke_uid, 'Non-smoker', 'organizer', 'office');
  update events set organizer_participant_id = v_access_pid where id = v_access_event;
  update events set organizer_participant_id = v_smoke_pid where id = v_smoke_event;

  insert into restaurants (place_id) values
    ('qa0021_access_full'), ('qa0021_access_partial'), ('qa0021_access_none'),
    ('qa0021_smoke_non'), ('qa0021_smoke_ok'), ('qa0021_smoke_unknown');

  -- Tags are vocabulary members since 0022 (fn_accessibility_vocabulary); the venue-side CHECK
  -- refuses anything else, which is what makes 'needs' and 'tags' the same language.
  insert into restaurant_features
    (place_id, price_yen_estimate, room_type, dietary_tags, accessibility_tags, smoking_policy)
  values
    ('qa0021_access_full', 3000, 'open', array['qa0021_access'],
     array['wheelchair_accessible_entrance','wheelchair_accessible_restroom'], null),
    ('qa0021_access_partial', 3000, 'open', array['qa0021_access'],
     array['wheelchair_accessible_entrance'], null),
    -- No accessibility data at all: the state every venue is in until somebody records it.
    ('qa0021_access_none', 3000, 'open', array['qa0021_access'], '{}', null),
    ('qa0021_smoke_non', 3000, 'open', array['qa0021_smoke'], '{}', 'non_smoking'),
    ('qa0021_smoke_ok', 3000, 'open', array['qa0021_smoke'], '{}', 'smoking_ok'),
    ('qa0021_smoke_unknown', 3000, 'open', array['qa0021_smoke'], '{}', null);

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_access_event, v_access_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0021_access"]}', 'ANONYMOUS');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_access_event, v_access_pid, 'MUST', '車椅子で入れて、トイレも使える店',
          'accessibility',
          '{"needs":["wheelchair_accessible_entrance","wheelchair_accessible_restroom"]}',
          'ANONYMOUS')
  returning id into v_access_need_id;

  perform t_check('an accessibility MUST is met only when every need is met',
                  fn_candidate_is_feasible(v_access_event, 'qa0021_access_full'));
  perform t_check('a partially accessible venue fails an accessibility MUST',
                  not fn_candidate_is_feasible(v_access_event, 'qa0021_access_partial'));
  perform t_check('absent accessibility data is infeasible, never silently satisfied',
                  not fn_candidate_is_feasible(v_access_event, 'qa0021_access_none'));
  v_result := fn_recompute_feasibility(v_access_event);
  perform t_check('only the venue meeting every need is feasible',
                  (v_result->>'feasible_count')::int = 1, v_result::text);
  perform t_check('an accessibility MUST is still never proposed for relaxation',
                  fn_propose_relaxation(v_access_event) is null);

  -- An accessibility MUST we cannot read is not one we may certify as met either.
  update participant_constraints set normalized_value = '{"needs":[]}'
   where id = v_access_need_id;
  perform t_check('an unreadable accessibility MUST fails closed',
                  not fn_candidate_is_feasible(v_access_event, 'qa0021_access_full'));

  -- Smoking: same fail-closed rule, but with a relaxation step, because nothing populates
  -- smoking_policy yet and a MUST nobody can satisfy or negotiate is a dead end.
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_smoke_event, v_smoke_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0021_smoke"]}', 'ANONYMOUS');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_smoke_event, v_smoke_pid, 'MUST', '禁煙の店がいい',
          'smoking', '{"preference":"non_smoking"}', 'PUBLIC')
  returning id into v_smoke_id;

  perform t_check('a confirmed non-smoking venue meets a non_smoking MUST',
                  fn_candidate_is_feasible(v_smoke_event, 'qa0021_smoke_non'));
  perform t_check('a venue known to allow smoking fails a non_smoking MUST',
                  not fn_candidate_is_feasible(v_smoke_event, 'qa0021_smoke_ok'));
  perform t_check('an unconfirmed smoking policy is infeasible, never silently satisfied',
                  not fn_candidate_is_feasible(v_smoke_event, 'qa0021_smoke_unknown'));
  v_result := fn_recompute_feasibility(v_smoke_event);
  perform t_check('only the confirmed non-smoking venue is feasible',
                  (v_result->>'feasible_count')::int = 1, v_result::text);

  perform t_check('smoking_policy accepts only the two documented values',
                  (select count(*) from information_schema.check_constraints
                    where constraint_name = 'restaurant_features_smoking_policy_check') = 1);

  perform t_check('relaxing the smoking MUST unlocks the unconfirmed venue',
                  fn_count_unlocked_if_relaxed(v_smoke_event, v_smoke_id) = 1,
                  fn_count_unlocked_if_relaxed(v_smoke_event, v_smoke_id)::text);
  v_neg_id := fn_propose_relaxation(v_smoke_event);
  perform t_check('a smoking MUST is escapable through a proposal', v_neg_id is not null);
  select * into v_neg from negotiations where id = v_neg_id;
  perform t_check('the proposal targets the smoking MUST', v_neg.constraint_id = v_smoke_id);
  perform t_check('the proposal keeps the preference and only accepts unconfirmed venues',
                  v_neg.proposed_value
                    = '{"preference":"non_smoking","accept_unknown":true}'::jsonb,
                  v_neg.proposed_value::text);

  perform t_as_user(v_smoke_uid);
  v_result := fn_respond_negotiation(v_neg_id, true);
  perform t_check('accepting the smoking relaxation admits the unconfirmed venue',
                  (v_result->>'feasible_count')::int = 2, v_result::text);
  perform t_as_admin();
  perform t_check('an accepted smoking relaxation still refuses a known smoking venue',
                  not fn_candidate_is_feasible(v_smoke_event, 'qa0021_smoke_ok'));

  v_raised := false;
  begin
    update restaurant_features set smoking_policy = 'maybe' where place_id = 'qa0021_smoke_non';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('smoking_policy rejects an undocumented value', v_raised);
end $$;

-- ---------------------------------------------------------------------------
-- 0021: one malformed constraint no longer aborts the whole recompute.
--
-- RLS lets any participant write an arbitrary normalized_value, and
-- (normalized_value->>'max_yen')::int raised invalid_text_representation on {"max_yen":
-- "cheap"} — killing the engine for the entire event. The SQL NULL semantics are unchanged:
-- an unreadable key behaves exactly like a MISSING one (`price > null` is falsey, so the MUST
-- passes), which is what the TypeScript port has always done.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00210000-0000-0000-0000-00000000c000';
  v_pid uuid := '00210000-0000-0000-0000-00000000c001';
  v_result jsonb;
  v_raised boolean := false;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA malformed casts', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, gen_random_uuid(), 'Typo', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into restaurants (place_id) values ('qa0021_cast_priced'), ('qa0021_cast_unpriced');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags)
  values ('qa0021_cast_priced', 3000, 'open', array['qa0021_cast']),
         ('qa0021_cast_unpriced', null, 'open', array['qa0021_cast']);

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0021_cast"]}', 'ANONYMOUS'),
         (v_event, v_pid, 'MUST', 'cheap please',
          'budget', '{"max_yen":"cheap"}', 'PUBLIC'),
         (v_event, v_pid, 'MUST', 'すぐ着きたい',
          'travel_time', '{"max_minutes":"すぐ"}', 'PUBLIC');

  begin
    v_result := fn_recompute_feasibility(v_event);
  exception when others then
    v_raised := true;
  end;
  perform t_check('a malformed max_yen no longer aborts the recompute', not v_raised);
  -- The unpriced venue is still excluded: that branch is an explicit null check on the venue,
  -- not a comparison against the ceiling, so a junk ceiling cannot smuggle it through.
  perform t_check('a malformed ceiling still refuses a venue with no price',
                  not fn_candidate_is_feasible(v_event, 'qa0021_cast_unpriced'));
  perform t_check('a priced venue is judged as if the ceiling were absent',
                  fn_candidate_is_feasible(v_event, 'qa0021_cast_priced'));
  perform t_check('so exactly one venue survives a malformed budget and travel MUST',
                  (v_result->>'feasible_count')::int = 1, v_result::text);
  perform t_check('a malformed max_yen is not proposable either (its step unlocks nothing)',
                  fn_propose_relaxation(v_event) is null);

  -- The exact rule the TypeScript port reproduces: a fully numeric string IS the number, a
  -- partly numeric one is absent (never 40), a fractional one truncates, and a value outside
  -- int range is absent rather than a different number.
  perform t_check('fn_jsonb_int reads a numeric string as its number',
                  fn_jsonb_int('{"max_yen":"4000"}', 'max_yen') = 4000);
  perform t_check('fn_jsonb_int truncates a fractional value',
                  fn_jsonb_int('{"max_yen":4000.7}', 'max_yen') = 4000);
  perform t_check('fn_jsonb_int reports every unreadable shape as absent',
                  fn_jsonb_int('{"max_yen":"40abc"}', 'max_yen') is null
                  and fn_jsonb_int('{"max_yen":"cheap"}', 'max_yen') is null
                  and fn_jsonb_int('{"max_yen":true}', 'max_yen') is null
                  and fn_jsonb_int('{"max_yen":[1]}', 'max_yen') is null
                  and fn_jsonb_int('{"max_yen":null}', 'max_yen') is null
                  and fn_jsonb_int('{"max_yen":99999999999}', 'max_yen') is null
                  and fn_jsonb_int('{}', 'max_yen') is null);
  -- Only a real JSON true widens a MUST: the flag is written by fn_relaxed_value, so anything
  -- else in that key is hand-edited and must not count.
  perform t_check('fn_jsonb_flag only accepts a real JSON true',
                  fn_jsonb_flag('{"accept_unknown":true}', 'accept_unknown')
                  and not fn_jsonb_flag('{"accept_unknown":"true"}', 'accept_unknown')
                  and not fn_jsonb_flag('{"accept_unknown":"yes"}', 'accept_unknown')
                  and not fn_jsonb_flag('{}', 'accept_unknown'));
end $$;

-- ---------------------------------------------------------------------------
-- 0021: fn_propose_relaxation is idempotent.
--
-- Four presses of 「条件に合うお店を探す」 while feasible = 0 used to insert four PROPOSED
-- rows and ask the same participant the same question four times.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00210000-0000-0000-0000-00000000d000';
  v_pid uuid := '00210000-0000-0000-0000-00000000d001';
  v_budget_id uuid;
  v_travel_id uuid;
  v_first uuid;
  v_second uuid;
  v_third uuid;
  v_fourth uuid;
  v_again uuid;
  v_result jsonb;
  v_raised boolean := false;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA idempotent proposals', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, gen_random_uuid(), 'Presser', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  -- `over` breaks the budget only, `far` breaks the travel MUST only, so the two relaxable
  -- MUSTs below genuinely disagree about which one unlocks more.
  insert into restaurants (place_id) values ('qa0021_neg_over'), ('qa0021_neg_far');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags,
                                   travel_minutes_by_participant)
  values ('qa0021_neg_over', 1200, 'open', array['qa0021_neg'],
          jsonb_build_object(v_pid::text, 20)),
         ('qa0021_neg_far', 900, 'open', array['qa0021_neg'],
          jsonb_build_object(v_pid::text, 12));

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0021_neg"]}', 'ANONYMOUS');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', '1000円まで', 'budget', '{"max_yen":1000}', 'PUBLIC')
  returning id into v_budget_id;
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', '5分以内', 'travel_time', '{"max_minutes":5}', 'PUBLIC')
  returning id into v_travel_id;

  v_result := fn_recompute_feasibility(v_event);
  perform t_check('nothing fits the stated budget and travel time',
                  (v_result->>'feasible_count')::int = 0, v_result::text);
  -- +10 minutes brings `far` (12 min, 900 yen) inside both MUSTs; +500 yen cannot rescue
  -- `over`, which is also 20 minutes away, so travel_time is the better target here.
  perform t_check('the travel step unlocks one venue and the budget step none',
                  fn_count_unlocked_if_relaxed(v_event, v_travel_id) = 1
                  and fn_count_unlocked_if_relaxed(v_event, v_budget_id) = 0,
                  fn_count_unlocked_if_relaxed(v_event, v_travel_id)::text || '/' ||
                  fn_count_unlocked_if_relaxed(v_event, v_budget_id)::text);

  v_first := fn_propose_relaxation(v_event);
  v_second := fn_propose_relaxation(v_event);
  v_third := fn_propose_relaxation(v_event);
  v_fourth := fn_propose_relaxation(v_event);
  perform t_check('a proposal is created on the first press', v_first is not null);
  perform t_check('a second call returns the same negotiation, not a duplicate',
                  v_second = v_first, v_second::text);
  perform t_check('four presses produce exactly one negotiation row',
                  (select count(*) from negotiations where event_id = v_event) = 1
                  and v_third = v_first and v_fourth = v_first,
                  (select count(*)::text from negotiations where event_id = v_event));
  perform t_check('and exactly one question is open',
                  (select count(*) from negotiations
                    where event_id = v_event and status = 'PROPOSED') = 1);
  perform t_check('the one question is the best target, +10 minutes',
                  (select proposed_value from negotiations where id = v_first)
                    = '{"max_minutes":15}'::jsonb,
                  (select proposed_value::text from negotiations where id = v_first));

  -- The schema enforces it too, so a concurrent double-press cannot slip past the check.
  begin
    insert into negotiations (event_id, constraint_id, participant_id, proposed_value,
                              unlocked_count)
    values (v_event, v_travel_id, v_pid, '{"max_minutes":15}', 1);
  exception when unique_violation then
    v_raised := true;
  end;
  perform t_check('a partial unique index refuses a second open proposal per event',
                  v_raised);

  -- An open proposal for a DIFFERENT constraint than the one now judged best still wins:
  -- retargeting would withdraw a question somebody is looking at, or ask a second person
  -- while the first has not answered. Rewriting the open row simulates a proposal made when
  -- the ranking looked different; travel_time is the better target now.
  update negotiations set constraint_id = v_budget_id, proposed_value = '{"max_yen":1500}'
   where id = v_first;
  perform t_check('an open proposal for another constraint is returned as is',
                  fn_propose_relaxation(v_event) = v_first);
  perform t_check('and nothing was written for the better target',
                  (select count(*) from negotiations where event_id = v_event) = 1);
  update negotiations set constraint_id = v_travel_id, proposed_value = '{"max_minutes":15}'
   where id = v_first;

  -- Rejection is final for THAT question: re-asking it is the pressure the PRD forbids.
  update negotiations set status = 'REJECTED', responded_at = now() where id = v_first;
  perform t_check('a rejected step is never proposed again',
                  fn_propose_relaxation(v_event) is null);
  perform t_check('and no second row is written',
                  (select count(*) from negotiations where event_id = v_event) = 1);

  -- …but a genuinely different question is allowed, so one "no" cannot dead-end the event:
  -- the participant moved their own ceiling, so the step is no longer the one they declined.
  update participant_constraints set normalized_value = '{"max_minutes":8}'
   where id = v_travel_id;
  v_again := fn_propose_relaxation(v_event);
  perform t_check('a step the participant has not seen may still be asked',
                  v_again is not null and v_again is distinct from v_first);
  perform t_check('and it is the new step, not the rejected one',
                  (select proposed_value from negotiations where id = v_again)
                    = '{"max_minutes":18}'::jsonb,
                  (select proposed_value::text from negotiations where id = v_again));
end $$;

-- ---------------------------------------------------------------------------
-- 0022 (A): the accessibility vocabulary, enforced on both sides, plus the coverage count
-- that stops a zero-candidate result from being silent.
--
-- Nothing had ever written restaurant_features.accessibility_tags (0016 added the column,
-- 0017's writer deliberately skips it), 0021 made an empty tag list fail closed, and
-- accessibility is never relaxable — so 「車椅子で入れる店」 as a MUST meant zero candidates and
-- no proposal, forever. And `needs` was an open string array against a containment test, so the
-- two vocabularies would rarely have met even with data.
--
-- Every scratch venue below carries a unique dietary tag its event requires, so these venues
-- can never be feasible for the demo event and vice versa; the 0-then-3 invariant is
-- re-asserted at the end regardless.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00220000-0000-0000-0000-00000000a000';
  v_pid uuid := '00220000-0000-0000-0000-00000000a001';
  v_needs_id uuid;
  v_result jsonb;
  v_written int;
  v_places text[];
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA accessibility vocabulary', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, gen_random_uuid(), 'Wheelchair user', 'organizer', 'station');
  update events set organizer_participant_id = v_pid where id = v_event;

  -- The vocabulary is exactly the four nullable booleans Google Places (New) returns in
  -- `accessibilityOptions`, named after them so the provider maps onto it 1:1.
  perform t_check('the vocabulary is the four Places accessibilityOptions booleans',
                  fn_accessibility_vocabulary() = array[
                    'wheelchair_accessible_entrance','wheelchair_accessible_parking',
                    'wheelchair_accessible_restroom','wheelchair_accessible_seating'],
                  fn_accessibility_vocabulary()::text);

  -- Canonicalisation is the only place a value is translated, and it never invents a member:
  -- the two examples the old open-ended prompt gave were both about GETTING IN.
  perform t_check('the legacy step_free / wheelchair values map onto the entrance boolean',
                  fn_accessibility_canonical_tags(array['wheelchair','step_free'])
                    = array['wheelchair_accessible_entrance'],
                  fn_accessibility_canonical_tags(array['wheelchair','step_free'])::text);
  perform t_check('a tag outside the vocabulary is dropped rather than stored',
                  fn_accessibility_canonical_tags(array['elevator']) = '{}'::text[],
                  fn_accessibility_canonical_tags(array['elevator'])::text);
  perform t_check('canonical tags are deduped and sorted',
                  fn_accessibility_canonical_tags(array['wheelchair_accessible_seating',
                    'wheelchair_accessible_entrance','wheelchair_accessible_seating'])
                    = array['wheelchair_accessible_entrance','wheelchair_accessible_seating']);
  perform t_check('and the same rule applies to a constraint value',
                  fn_accessibility_canonical_needs(
                    '{"needs":["step_free","elevator"]}')
                    = array['wheelchair_accessible_entrance']
                  and fn_accessibility_canonical_needs('{"needs":["elevator"]}') = '{}'::text[]
                  and fn_accessibility_canonical_needs('{}') = '{}'::text[]
                  and fn_accessibility_canonical_needs('{"needs":"wheelchair"}') = '{}'::text[]);

  insert into restaurants (place_id) values
    ('qa0022_access_full'), ('qa0022_access_partial'), ('qa0022_access_none'),
    ('qa0022_access_and_budget');
  insert into restaurant_features
    (place_id, price_yen_estimate, room_type, dietary_tags, accessibility_tags)
  values
    ('qa0022_access_full', 3000, 'open', array['qa0022_access'],
     array['wheelchair_accessible_entrance','wheelchair_accessible_restroom']),
    ('qa0022_access_partial', 3000, 'open', array['qa0022_access'],
     array['wheelchair_accessible_entrance']),
    -- No data at all: the state every venue was in before this migration.
    ('qa0022_access_none', 3000, 'open', array['qa0022_access'], '{}'),
    -- Also over budget, so it is NOT one phone call away from being a candidate.
    ('qa0022_access_and_budget', 9000, 'open', array['qa0022_access'], '{}');

  -- The venue side is constrained, so 'needs' and 'tags' cannot drift into different languages.
  v_raised := false;
  begin
    update restaurant_features set accessibility_tags = array['step_free']
     where place_id = 'qa0022_access_none';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('the venue side refuses a tag outside the vocabulary', v_raised);

  -- …and the CHECK cannot drift from fn_accessibility_vocabulary, because every member the
  -- function lists is inserted here.
  v_raised := false;
  begin
    update restaurant_features set accessibility_tags = fn_accessibility_vocabulary()
     where place_id = 'qa0022_access_none';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('and accepts every member fn_accessibility_vocabulary lists', not v_raised);
  update restaurant_features set accessibility_tags = '{}'
   where place_id = 'qa0022_access_none';

  -- The provider write path. 0017's fn_record_provider_candidates is frozen and promises never
  -- to touch this column, so anything recorded here came from 0022's second, additive writer.
  v_written := fn_record_provider_accessibility(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0022_access_none',
      'accessibility_tags', jsonb_build_array('wheelchair_accessible_entrance')),
    -- No `accessibility_tags` key at all: Places returned no accessibilityOptions object.
    jsonb_build_object('place_id', 'qa0022_access_full')));
  perform t_check('the provider write path records a confirmed boolean as its member',
                  v_written = 1
                  and (select accessibility_tags from restaurant_features
                        where place_id = 'qa0022_access_none')
                      = array['wheelchair_accessible_entrance'],
                  v_written::text);
  perform t_check('an absent accessibilityOptions object changes nothing',
                  (select accessibility_tags from restaurant_features
                    where place_id = 'qa0022_access_full')
                  = array['wheelchair_accessible_entrance','wheelchair_accessible_restroom']);
  -- A present-but-empty answer is Places saying "nothing confirmed". It must be able to retract
  -- a stale tag: a renovation that removes the ramp cannot be invisible.
  perform fn_record_provider_accessibility(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0022_access_none',
      'accessibility_tags', '[]'::jsonb)));
  perform t_check('an empty answer retracts a tag instead of preserving it',
                  (select accessibility_tags from restaurant_features
                    where place_id = 'qa0022_access_none') = '{}'::text[]);
  -- A stale deployment sending the old vocabulary is canonicalised, never a check violation
  -- that would fail the whole search.
  perform fn_record_provider_accessibility(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0022_access_none',
      'accessibility_tags', jsonb_build_array('step_free', 'elevator'))));
  perform t_check('a legacy or unknown provider tag is canonicalised on the way in',
                  (select accessibility_tags from restaurant_features
                    where place_id = 'qa0022_access_none')
                  = array['wheelchair_accessible_entrance'],
                  (select accessibility_tags::text from restaurant_features
                    where place_id = 'qa0022_access_none'));
  update restaurant_features set accessibility_tags = '{}'
   where place_id = 'qa0022_access_none';

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0022_access"]}', 'ANONYMOUS'),
         (v_event, v_pid, 'MUST', '4000円まで', 'budget', '{"max_yen":4000}', 'PUBLIC');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', '車椅子で入れて、車椅子対応のトイレがある店',
          'accessibility',
          '{"needs":["wheelchair_accessible_entrance","wheelchair_accessible_restroom"]}',
          'ANONYMOUS')
  returning id into v_needs_id;

  perform t_check('an accessibility MUST is MET when the recorded tags cover the needs',
                  fn_candidate_is_feasible(v_event, 'qa0022_access_full'));
  perform t_check('recorded tags that cover only part of the needs stay infeasible',
                  not fn_candidate_is_feasible(v_event, 'qa0022_access_partial'));
  perform t_check('and no recorded tags at all is infeasible, never silently satisfied',
                  not fn_candidate_is_feasible(v_event, 'qa0022_access_none'));

  -- The single MUST chain, now answerable: which types stand in the way?
  perform t_check('the blocking types name accessibility as the only obstacle',
                  fn_candidate_blocking_types(v_event, 'qa0022_access_none')
                    = array['accessibility'],
                  fn_candidate_blocking_types(v_event, 'qa0022_access_none')::text);
  perform t_check('and name both obstacles when there are two',
                  fn_candidate_blocking_types(v_event, 'qa0022_access_and_budget')
                    = array['accessibility','budget'],
                  fn_candidate_blocking_types(v_event, 'qa0022_access_and_budget')::text);
  perform t_check('a venue with no feature row is reported as unknown, not as accessibility',
                  fn_candidate_blocking_types(v_event, 'no_such_place')
                    = array['unknown_venue']);
  perform t_check('and feasibility is exactly "nothing blocks it"',
                  fn_candidate_blocking_types(v_event, 'qa0022_access_full') = '{}'::text[]
                  and fn_candidate_is_feasible(v_event, 'qa0022_access_full'));

  v_result := fn_recompute_feasibility(v_event);
  perform t_check('only the venue whose tags cover every need is feasible',
                  (v_result->>'feasible_count')::int = 1, v_result::text);
  -- The reason is in data the client can already read: 「N件は車椅子対応が確認できませんでした
  -- （お店に確認できます）」 instead of 「0件」. The over-budget venue is deliberately NOT counted:
  -- a phone call about its entrance would not put it on the shortlist.
  perform t_check('the payload reports how many venues are only missing accessibility proof',
                  (v_result->>'accessibility_unverified_count')::int = 2, v_result::text);
  perform t_check('and every pre-0022 key is still there with its old meaning',
                  v_result ? 'run_id' and v_result ? 'feasible_count'
                  and (v_result->>'run_id')::uuid is not null, v_result::text);
  perform t_check('an accessibility MUST is still never proposed for relaxation',
                  fn_propose_relaxation(v_event) is null);

  -- WHY llm-assist filters `needs` server-side instead of trusting the model: one value the
  -- vocabulary cannot express excludes every venue in Tokyo, and accessibility is never
  -- relaxable, so there is no way back out. The boundary drops it and keeps the participant's
  -- own wording in semantic_remainder instead.
  update participant_constraints set normalized_value = '{"needs":["elevator"]}'
   where id = v_needs_id;
  select count(*) into v_written from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('an out-of-vocabulary need can never be matched by any venue',
                  v_written = 0 and not fn_candidate_is_feasible(v_event, 'qa0022_access_full'),
                  v_written::text);
  perform t_check('and cannot be negotiated either, which is why it must never be stored',
                  fn_propose_relaxation(v_event) is null);
  perform t_check('so the canonical form drops it, leaving the wording to semantic_remainder',
                  fn_accessibility_canonical_needs('{"needs":["elevator"]}') = '{}'::text[]);
  update participant_constraints
     set normalized_value =
           '{"needs":["wheelchair_accessible_entrance","wheelchair_accessible_restroom"]}'
   where id = v_needs_id;

  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('and the accessible venue is feasible again afterwards',
                  v_places = array['qa0022_access_full'], v_places::text);
end $$;

-- ---------------------------------------------------------------------------
-- 0022 (B): a `room` MUST no longer dead-ends on a Places-only candidate set.
--
-- room_type is populated only from Hot Pepper's private_room field; Google Places has no
-- private-room field at all, so a candidate discovered through Places and not matched in Hot
-- Pepper has room_type NULL — `distinct from` 'private' AND from the 'semi_private' 0021
-- relaxed it to, so fn_count_unlocked_if_relaxed returned 0 and no question was ever asked.
-- 個室 is the centrepiece of the PRD's demo, so that silence is unacceptable.
--
-- The step now widens the room type AND accepts an unconfirmed one, in ONE question: see
-- fn_relaxed_value for why neither two-rung ordering is reachable.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00220000-0000-0000-0000-00000000b000';
  v_pid uuid := '00220000-0000-0000-0000-00000000b001';
  v_uid uuid := '88888888-8888-8888-8888-888888888888';
  v_room_id uuid;
  v_neg_id uuid;
  v_neg negotiations%rowtype;
  v_result jsonb;
  v_places text[];
  v_baseline int;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA private room', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, v_uid, 'Bob', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into restaurants (place_id) values
    ('qa0022_room_unknown'), ('qa0022_room_semi'), ('qa0022_room_open');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags)
  values
    -- Discovered through Places, no Hot Pepper match: room_type NULL. This is what the real
    -- pipeline produces for most of Tokyo.
    ('qa0022_room_unknown', 3000, null, array['qa0022_room']),
    ('qa0022_room_semi', 3000, 'semi_private', array['qa0022_room']),
    ('qa0022_room_open', 3000, 'open', array['qa0022_room']);

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0022_room"]}', 'ANONYMOUS');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', '個室がいい', 'room', '{"room":"private"}', 'PUBLIC')
  returning id into v_room_id;

  v_result := fn_recompute_feasibility(v_event);
  perform t_check('a 個室 MUST leaves nothing feasible when no venue confirms one',
                  (v_result->>'feasible_count')::int = 0, v_result::text);
  perform t_check('an unconfirmed room type is infeasible, never silently satisfied',
                  not fn_candidate_is_feasible(v_event, 'qa0022_room_unknown'));
  perform t_check('the coverage count is 0 when nobody asked about accessibility',
                  (v_result->>'accessibility_unverified_count')::int = 0, v_result::text);
  perform t_check('and the room MUST is what blocks the unconfirmed venue',
                  fn_candidate_blocking_types(v_event, 'qa0022_room_unknown') = array['room']);

  -- This is the bug: before 0022 this was 0, so no proposal was ever offered.
  perform t_check('the room step unlocks the unconfirmed venue and the confirmed 半個室',
                  fn_count_unlocked_if_relaxed(v_event, v_room_id) = 2,
                  fn_count_unlocked_if_relaxed(v_event, v_room_id)::text);
  v_neg_id := fn_propose_relaxation(v_event);
  perform t_check('a room MUST on an unconfirmed venue is escapable through a proposal',
                  v_neg_id is not null);
  select * into v_neg from negotiations where id = v_neg_id;
  perform t_check('the proposal targets the room MUST', v_neg.constraint_id = v_room_id);
  perform t_check('and widens the room type AND accepts an unconfirmed one, in one question',
                  v_neg.proposed_value
                    = '{"room":"semi_private","accept_unknown":true}'::jsonb,
                  v_neg.proposed_value::text);
  perform t_check('fn_propose_relaxation advertises exactly what fn_relaxed_value delivers',
                  v_neg.proposed_value = fn_relaxed_value('room', '{"room":"private"}')
                  and v_neg.unlocked_count = 2, v_neg.unlocked_count::text);

  perform t_as_user(v_uid);
  v_result := fn_respond_negotiation(v_neg_id, true);
  perform t_check('accepting admits the unconfirmed venue and the confirmed 半個室',
                  (v_result->>'feasible_count')::int = 2, v_result::text);
  perform t_as_admin();
  -- The composition rule: consenting to 半個室 must not smuggle in a venue we KNOW is a
  -- counter-only 大衆酒場.
  perform t_check('a venue known to be the wrong room type still fails after the consent',
                  not fn_candidate_is_feasible(v_event, 'qa0022_room_open'));
  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('so exactly the 半個室 and the unconfirmed venue are admitted',
                  v_places = array['qa0022_room_semi','qa0022_room_unknown'], v_places::text);

  -- The ladder terminates: the relaxed value is a fixed point, so nobody is asked the same
  -- question a second time.
  perform t_check('the relaxed room value is a fixed point',
                  fn_relaxed_value('room', v_neg.proposed_value) = v_neg.proposed_value,
                  fn_relaxed_value('room', v_neg.proposed_value)::text);
  perform t_check('so a second room step unlocks nothing and is never proposed',
                  fn_count_unlocked_if_relaxed(v_event, v_room_id) = 0
                  and fn_propose_relaxation(v_event) is null);

  -- An unreadable room preference fails closed (0021 does the same for smoking) and its step
  -- unlocks nothing, so nobody is asked a question the engine cannot phrase.
  update participant_constraints set normalized_value = '{"room":"たたみ"}' where id = v_room_id;
  select count(*) into v_baseline from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('an unreadable room preference fails closed', v_baseline = 0,
                  v_baseline::text);
  perform t_check('and its step unlocks nothing, so it is never proposed',
                  fn_count_unlocked_if_relaxed(v_event, v_room_id) = 0
                  and fn_relaxed_value('room', '{"room":"たたみ"}')
                      = '{"room":"たたみ","accept_unknown":true}'::jsonb);
  update participant_constraints set normalized_value = '{"room":"semi_private"}'
   where id = v_room_id;
  -- A 半個室 MUST gets the accept_unknown concession only: there is nothing wider to widen to,
  -- and it still never admits a venue known to be `open`.
  perform t_check('a semi_private MUST is relaxed by accepting unknowns alone',
                  fn_relaxed_value('room', '{"room":"semi_private"}')
                    = '{"room":"semi_private","accept_unknown":true}'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 0023 (A): Hot Pepper's 禁煙席 text finally reaches smoking_policy — and only when it is
-- unambiguous about the WHOLE venue.
--
-- 0021 added the column, made a smoking MUST fail closed on NULL and added the accept_unknown
-- step so that would not be a dead end — but nothing ever wrote the column, so every 禁煙 MUST
-- had to spend a negotiation round before one venue could qualify. Hot Pepper answers the
-- question in a response restaurant-search already receives (no `lite` parameter, so the full
-- shop object comes back); the field was simply never declared.
--
-- The value is free text with no published list, and smoking_policy has exactly two legal
-- values, so fn_hotpepper_smoking_policy recognises whole-venue phrasings and answers NULL for
-- everything else — including everything it has never seen. Every scratch venue below carries a
-- unique dietary tag its event requires, so these venues can never be feasible for the demo
-- event and vice versa; the 0-then-3 invariant is re-asserted at the end regardless.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00230000-0000-0000-0000-00000000a000';
  v_pid uuid := '00230000-0000-0000-0000-00000000a001';
  v_uid uuid := '99999999-9999-9999-9999-999999999999';
  v_smoke_id uuid;
  v_written int;
  v_result jsonb;
  v_places text[];
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA hot pepper smoking', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, v_uid, 'Non-smoker', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  -- The mapping table, value by value. Only a value that describes the whole venue may be
  -- recorded, because the column cannot express anything in between.
  perform t_check('an unambiguous 全席禁煙-style value records non_smoking',
                  fn_hotpepper_smoking_policy('全席禁煙') = 'non_smoking'
                  and fn_hotpepper_smoking_policy('全面禁煙') = 'non_smoking'
                  and fn_hotpepper_smoking_policy('店内全席禁煙') = 'non_smoking'
                  and fn_hotpepper_smoking_policy('店内全面禁煙') = 'non_smoking'
                  and fn_hotpepper_smoking_policy('完全禁煙') = 'non_smoking',
                  fn_hotpepper_smoking_policy('全席禁煙'));
  perform t_check('and an unambiguous whole-venue 喫煙可 value records smoking_ok',
                  fn_hotpepper_smoking_policy('全席喫煙可') = 'smoking_ok'
                  and fn_hotpepper_smoking_policy('全席喫煙可能') = 'smoking_ok'
                  and fn_hotpepper_smoking_policy('全面喫煙可') = 'smoking_ok'
                  and fn_hotpepper_smoking_policy('店内全席喫煙可') = 'smoking_ok'
                  and fn_hotpepper_smoking_policy('店内全面喫煙可') = 'smoking_ok',
                  fn_hotpepper_smoking_policy('全席喫煙可'));
  -- THE judgement call: a partition somewhere in the room says nothing about which side a group
  -- of five is seated on, and there is no third value to record it as.
  perform t_check('一部禁煙 and 分煙 record NULL — unconfirmed, never a guess',
                  fn_hotpepper_smoking_policy('一部禁煙') is null
                  and fn_hotpepper_smoking_policy('分煙') is null
                  and fn_hotpepper_smoking_policy('完全分煙') is null
                  and fn_hotpepper_smoking_policy('禁煙席あり') is null
                  and fn_hotpepper_smoking_policy('テラス席のみ喫煙可') is null);
  -- Substring matching is the trap: every value here contains 禁煙 while describing a room
  -- somebody is smoking in, or asserts the absence of a seat rather than what is permitted.
  perform t_check('a partial value that merely CONTAINS 禁煙 is not read as non_smoking',
                  fn_hotpepper_smoking_policy('全席禁煙（喫煙ブースあり）') is null
                  and fn_hotpepper_smoking_policy('店内禁煙（屋外喫煙所あり）') is null
                  and fn_hotpepper_smoking_policy('禁煙席なし') is null
                  and fn_hotpepper_smoking_policy('禁煙') is null);
  perform t_check('every unrecognised, absent or empty value records NULL',
                  fn_hotpepper_smoking_policy('未確認') is null
                  and fn_hotpepper_smoking_policy('あり') is null
                  and fn_hotpepper_smoking_policy('なし') is null
                  and fn_hotpepper_smoking_policy('喫煙可') is null
                  and fn_hotpepper_smoking_policy('座敷のみ喫煙可') is null
                  and fn_hotpepper_smoking_policy('') is null
                  and fn_hotpepper_smoking_policy('   ') is null
                  and fn_hotpepper_smoking_policy(null) is null);
  -- Formatting must not hide a value we do recognise: NFKC folds full-width forms and every
  -- space, including the ideographic U+3000, is removed before matching.
  perform t_check('padding and full-width whitespace do not hide a recognised value',
                  fn_hotpepper_smoking_policy('　全席 禁煙 ') = 'non_smoking'
                  and fn_hotpepper_smoking_policy(' 全席喫煙可　') = 'smoking_ok');
  -- Whatever the text, the output is inside 0021's CHECK by construction, so a provider anomaly
  -- can never fail the whole search with a constraint violation.
  perform t_check('the mapping can only ever emit a value 0021''s CHECK accepts',
                  not exists (
                    select 1 from (values ('全席禁煙'),('一部禁煙'),('分煙'),('全席喫煙可'),
                                          ('未確認'),('あり'),('なし'),(''),('禁煙'),('謎の値'))
                      as v(txt)
                    where fn_hotpepper_smoking_policy(v.txt) is not null
                      and fn_hotpepper_smoking_policy(v.txt)
                            not in ('non_smoking','smoking_ok')));

  insert into restaurants (place_id) values
    ('qa0023_smoke_all_non'), ('qa0023_smoke_partial'), ('qa0023_smoke_places_only');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags)
  values ('qa0023_smoke_all_non', 3000, 'open', array['qa0023_smoke']),
         ('qa0023_smoke_partial', 3000, 'open', array['qa0023_smoke']),
         -- Discovered through Places and never matched in Hot Pepper: nobody can speak to its
         -- smoking policy at all, which is what most of Tokyo looks like.
         ('qa0023_smoke_places_only', 3000, 'open', array['qa0023_smoke']);
  perform t_check('every venue starts unconfirmed, exactly as 0021 left it',
                  (select count(*) from restaurant_features
                    where place_id like 'qa0023_smoke_%' and smoking_policy is null) = 3);

  -- One enriched discovery pass: two candidates matched in Hot Pepper carry the provider's text
  -- verbatim, the Places-only candidate carries no key at all.
  select fn_record_provider_smoking_policy(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_smoke_all_non',
                       'hotpepper_non_smoking', '全席禁煙'),
    jsonb_build_object('place_id', 'qa0023_smoke_partial',
                       'hotpepper_non_smoking', '一部禁煙'),
    jsonb_build_object('place_id', 'qa0023_smoke_places_only'))) into v_written;
  perform t_check('the writer touches only the candidates Hot Pepper answered for',
                  v_written = 2, v_written::text);
  perform t_check('a whole-venue 禁煙 answer is recorded as non_smoking',
                  (select smoking_policy from restaurant_features
                    where place_id = 'qa0023_smoke_all_non') = 'non_smoking',
                  (select smoking_policy from restaurant_features
                    where place_id = 'qa0023_smoke_all_non'));
  perform t_check('a 一部禁煙 answer is recorded as NULL, not as non_smoking',
                  (select smoking_policy from restaurant_features
                    where place_id = 'qa0023_smoke_partial') is null);
  perform t_check('and a candidate Hot Pepper never matched is left untouched',
                  (select smoking_policy from restaurant_features
                    where place_id = 'qa0023_smoke_places_only') is null);

  -- AUTHORITATIVE where there IS an answer. Only Hot Pepper speaks to smoking, so there is no
  -- other provider's enrichment to protect, and 全席禁煙 is a state a venue can leave: keeping
  -- the old policy because the newest answer is 分煙 would certify smoke-free seating on
  -- evidence we no longer have.
  perform fn_record_provider_smoking_policy(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_smoke_all_non',
                       'hotpepper_non_smoking', '分煙')));
  perform t_check('a later partial answer retracts the policy instead of keeping a stale one',
                  (select smoking_policy from restaurant_features
                    where place_id = 'qa0023_smoke_all_non') is null);
  perform fn_record_provider_smoking_policy(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_smoke_all_non',
                       'hotpepper_non_smoking', '全席禁煙')));

  -- ADDITIVE where there is NO answer, which is the common case: a Places-only refetch, a run
  -- where Hot Pepper was down (its failure records a provider_incidents row and returns no
  -- shops), a shop whose 禁煙席 field is blank or not even a string. None of them may erase what
  -- a matched run recorded.
  select fn_record_provider_smoking_policy(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_smoke_all_non'),
    jsonb_build_object('place_id', 'qa0023_smoke_all_non', 'hotpepper_non_smoking', null),
    jsonb_build_object('place_id', 'qa0023_smoke_all_non', 'hotpepper_non_smoking', 42),
    jsonb_build_object('place_id', 'qa0023_smoke_all_non', 'hotpepper_non_smoking', '   '),
    -- Whitespace only, including the ideographic space btrim() would leave behind.
    jsonb_build_object('place_id', 'qa0023_smoke_all_non', 'hotpepper_non_smoking', '　'),
    jsonb_build_object('hotpepper_non_smoking', '全席喫煙可'),
    jsonb_build_object('place_id', 'qa0023_no_such_place',
                       'hotpepper_non_smoking', '全席禁煙'))) into v_written;
  perform t_check('an absent, null, non-string or blank field writes nothing at all',
                  v_written = 0, v_written::text);
  perform t_check('so a run with nothing to say cannot erase a recorded policy',
                  (select smoking_policy from restaurant_features
                    where place_id = 'qa0023_smoke_all_non') = 'non_smoking');
  perform t_check('and a malformed candidate list is ignored rather than raising',
                  fn_record_provider_smoking_policy(v_event, null) = 0
                  and fn_record_provider_smoking_policy(v_event, '{}'::jsonb) = 0
                  and fn_record_provider_smoking_policy(v_event, '[]'::jsonb) = 0);

  -- The point of the whole exercise: a 禁煙 MUST can now be met by provider data, with no
  -- negotiation round at all.
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0023_smoke"]}', 'ANONYMOUS');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', '禁煙の店がいい',
          'smoking', '{"preference":"non_smoking"}', 'PUBLIC')
  returning id into v_smoke_id;

  v_result := fn_recompute_feasibility(v_event);
  perform t_check('a 禁煙 MUST is satisfiable without a negotiation round at all',
                  (v_result->>'feasible_count')::int = 1, v_result::text);
  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('and the one feasible venue is the one Hot Pepper confirmed',
                  v_places = array['qa0023_smoke_all_non'], v_places::text);
  perform t_check('the partial and the unmatched venue are blocked on smoking, not satisfied',
                  fn_candidate_blocking_types(v_event, 'qa0023_smoke_partial')
                    = array['smoking']
                  and fn_candidate_blocking_types(v_event, 'qa0023_smoke_places_only')
                    = array['smoking']);
  -- 0021's escape hatch is untouched for the venues that are genuinely unconfirmed.
  perform t_check('0021''s accept_unknown step still unlocks exactly the unconfirmed two',
                  fn_count_unlocked_if_relaxed(v_event, v_smoke_id) = 2,
                  fn_count_unlocked_if_relaxed(v_event, v_smoke_id)::text);

  -- The write path is the provider pipeline's, not an API caller's: certifying a smoking policy
  -- is not something a participant may do to somebody else's health decision.
  perform t_as_user(v_uid);
  v_raised := false;
  begin
    perform fn_record_provider_smoking_policy(v_event, '[]'::jsonb);
  exception when insufficient_privilege then
    v_raised := true;
  end;
  perform t_check('an API caller cannot record a smoking policy', v_raised);
  perform t_as_admin();

  -- The seed has no Hot Pepper ids and no smoking constraints, so nothing above may have
  -- touched it. Verified, not assumed.
  perform t_check('the demo fixture is still entirely unconfirmed about smoking',
                  (select count(*) from restaurant_features
                    where place_id like 'demo_place_%' and smoking_policy is null) = 4);
end $$;

-- ---------------------------------------------------------------------------
-- 0023 (B): Hot Pepper's barrier_free is NOT mapped onto accessibility_tags, on purpose.
--
-- The same Gourmet Search response carries `barrier_free` (バリアフリー), free text whose
-- documented example is 「なし」. 0022's vocabulary is a closed set of four members, each named
-- after one Google Places accessibilityOptions boolean so the mapping needs no inference.
-- 「なし」 means there are no barrier-free facilities — no tag, which correctly fails the MUST
-- closed — and 「あり」 does not say it is the ENTRANCE that is step-free, or that the restroom
-- is usable, or that a wheelchair user can be seated. Accessibility is never relaxable, so a
-- wrong tag cannot be walked back by a question; it puts someone in front of a step they were
-- told was not there.
--
-- These checks assert the decision holds even against a future deployment that tried to forward
-- the text anyway: canonicalisation drops it, and 0022's venue-side CHECK refuses it outright.
-- Nothing here weakens either.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00230000-0000-0000-0000-00000000b000';
  v_pid uuid := '00230000-0000-0000-0000-00000000b001';
  v_written int;
  v_result jsonb;
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA barrier free', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, gen_random_uuid(), 'Wheelchair user', 'organizer', 'station');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into restaurants (place_id) values ('qa0023_bf_ari');
  -- A venue Hot Pepper describes as barrier_free = 「あり」 and Places says nothing about.
  insert into restaurant_features
    (place_id, price_yen_estimate, room_type, dietary_tags, accessibility_tags)
  values ('qa0023_bf_ari', 3000, 'open', array['qa0023_bf'], '{}');

  perform t_check('0023 leaves the accessibility vocabulary at the four Places booleans',
                  fn_accessibility_vocabulary() = array[
                    'wheelchair_accessible_entrance','wheelchair_accessible_parking',
                    'wheelchair_accessible_restroom','wheelchair_accessible_seating'],
                  fn_accessibility_vocabulary()::text);
  perform t_check('no barrier_free wording can ever become a vocabulary member',
                  fn_accessibility_canonical_tags(
                    array['あり','なし','未確認','バリアフリー','barrier_free','一部'])
                    = '{}'::text[],
                  fn_accessibility_canonical_tags(array['あり','barrier_free'])::text);
  -- Even if something did forward it, 0022's writer canonicalises it away rather than recording
  -- a tag nobody can stand behind.
  select fn_record_provider_accessibility(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_bf_ari',
      'accessibility_tags', jsonb_build_array('あり', 'barrier_free')))) into v_written;
  perform t_check('so the 0022 write path records no tag for a barrier_free positive',
                  (select accessibility_tags from restaurant_features
                    where place_id = 'qa0023_bf_ari') = '{}'::text[],
                  (select accessibility_tags::text from restaurant_features
                    where place_id = 'qa0023_bf_ari'));
  v_raised := false;
  begin
    update restaurant_features set accessibility_tags = array['barrier_free']
     where place_id = 'qa0023_bf_ari';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('and 0022''s venue-side CHECK still refuses it outright', v_raised);

  -- The consequence, stated plainly: 「あり」 buys the venue nothing, which is the honest
  -- outcome. It fails closed AND it is counted as unverified, so the 幹事 can phone the venue
  -- (verification_requirement = 'required', 0018) instead of being shown a silent 0件.
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0023_bf"]}', 'ANONYMOUS'),
         (v_event, v_pid, 'MUST', '車椅子で入れる店',
          'accessibility', '{"needs":["wheelchair_accessible_entrance"]}', 'ANONYMOUS');
  v_result := fn_recompute_feasibility(v_event);
  perform t_check('a venue whose only evidence is 「あり」 still fails the MUST closed',
                  (v_result->>'feasible_count')::int = 0
                  and (v_result->>'accessibility_unverified_count')::int = 1,
                  v_result::text);
  perform t_check('and it is still never proposed for relaxation',
                  fn_propose_relaxation(v_event) is null);
end $$;

-- ---------------------------------------------------------------------------
-- 0023 (C): Google's per-place attributions are stored where the client that must display them
-- can read them.
--
-- Showing Places content without a Google map requires Google Maps attribution AND requires
-- that the per-place third-party attributions the API returns are retrieved and displayed.
-- Neither field mask asked for them, so we did not hold the data at all.
--
-- They live on restaurant_features, not in restaurant_source_records: the raw payload table is
-- service-role only (no client read policy, table privileges revoked from anon and
-- authenticated), and data a client is REQUIRED to display cannot live where the client cannot
-- read it. Both facts are asserted below. The column is jsonb because an attribution's exact
-- wording and markup belong to its provider — string or object, stored as given, never rewritten.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00230000-0000-0000-0000-00000000c000';
  v_pid uuid := '00230000-0000-0000-0000-00000000c001';
  v_uid uuid := '10101010-1010-1010-1010-101010101010';
  v_html text := 'Listings by <a href="https://example.co.jp/">まとめグルメ</a>';
  v_object jsonb := jsonb_build_object(
    'provider', 'Example Provider', 'providerUri', 'https://example.com/');
  v_attributions jsonb;
  v_written int;
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA attributions', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, v_uid, 'Reader', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into restaurants (place_id) values ('qa0023_attr_credited'), ('qa0023_attr_stale');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags)
  values ('qa0023_attr_credited', 3000, 'open', array['qa0023_attr']),
         ('qa0023_attr_stale', 3000, 'open', array['qa0023_attr']);
  -- "Nobody has recorded any" is an empty array, not a null the client has to special-case —
  -- including for every seeded demo venue.
  perform t_check('a venue with no recorded credits holds an empty array, never null',
                  (select count(*) from restaurant_features
                    where provider_attributions = '[]'::jsonb
                      and (place_id like 'qa0023_attr_%' or place_id like 'demo_place_%')) = 6,
                  (select count(*)::text from restaurant_features
                    where provider_attributions = '[]'::jsonb
                      and (place_id like 'qa0023_attr_%' or place_id like 'demo_place_%')));

  select fn_record_provider_attributions(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_attr_credited', 'attributions',
      -- The two shapes an attribution can arrive in, plus four elements that cannot be a credit
      -- in any shape.
      jsonb_build_array(v_html, v_object, 42, true, null, jsonb_build_array('nested'))),
    jsonb_build_object('place_id', 'qa0023_attr_stale', 'attributions',
      jsonb_build_array(v_html)))) into v_written;
  perform t_check('the writer records the credits for every place Places answered for',
                  v_written = 2, v_written::text);
  select provider_attributions into v_attributions
    from restaurant_features where place_id = 'qa0023_attr_credited';
  perform t_check('an HTML-ish credit is stored exactly as given, not escaped or rewritten',
                  v_attributions->>0 = v_html, v_attributions::text);
  perform t_check('an object-shaped credit keeps every field it arrived with',
                  v_attributions->1 = v_object, v_attributions::text);
  perform t_check('elements that cannot be a credit are dropped, never rendered as junk',
                  jsonb_array_length(v_attributions) = 2, v_attributions::text);

  -- Absent key: this run learned nothing about that place (a cached candidate, a skipped
  -- discovery), so the credits the display is already rendering must survive.
  perform fn_record_provider_attributions(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_attr_stale'),
    jsonb_build_object('place_id', 'qa0023_attr_stale', 'attributions', '"not an array"'::jsonb)));
  perform t_check('an absent or unreadable attributions key changes nothing',
                  (select provider_attributions from restaurant_features
                    where place_id = 'qa0023_attr_stale') = jsonb_build_array(v_html));
  -- Present but empty: Places' current answer. Continuing to display a credit the provider no
  -- longer returns is a claim about where today's data came from, not caution.
  perform fn_record_provider_attributions(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0023_attr_stale', 'attributions', '[]'::jsonb)));
  perform t_check('a present-but-empty answer clears a credit that no longer applies',
                  (select provider_attributions from restaurant_features
                    where place_id = 'qa0023_attr_stale') = '[]'::jsonb);

  -- The column keeps the shape the client iterates: always an array, never null.
  v_raised := false;
  begin
    update restaurant_features set provider_attributions = '"oops"'::jsonb
     where place_id = 'qa0023_attr_stale';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('a non-array attributions value is refused', v_raised);
  v_raised := false;
  begin
    update restaurant_features set provider_attributions = null
     where place_id = 'qa0023_attr_stale';
  exception when not_null_violation then
    v_raised := true;
  end;
  perform t_check('and so is a null one', v_raised);

  -- THE READER. A participant's client is what has to render the credit, so it must be able to
  -- read it — and it still must not be able to read the raw provider payload the credit came in.
  perform t_as_user(v_uid);
  perform t_check('the client that must display the credit can read it',
                  (select provider_attributions from restaurant_features
                    where place_id = 'qa0023_attr_credited') = jsonb_build_array(v_html, v_object),
                  (select provider_attributions::text from restaurant_features
                    where place_id = 'qa0023_attr_credited'));
  v_raised := false;
  begin
    perform (select count(*) from restaurant_source_records);
  exception when insufficient_privilege then
    v_raised := true;
  end;
  perform t_check('while the raw payload table stays unreadable, which is why the column exists',
                  v_raised);
  -- And publishing an attribution is the pipeline's job, not a caller's.
  v_raised := false;
  begin
    perform fn_record_provider_attributions(v_event, '[]'::jsonb);
  exception when insufficient_privilege then
    v_raised := true;
  end;
  perform t_check('an API caller cannot record provider attributions', v_raised);
  perform t_as_admin();
end $$;

-- ---------------------------------------------------------------------------
-- 0026: the allergen vocabulary, enforced on both sides, and the coverage count that stops an
-- ALLERGY zero-candidate result from being silent.
--
-- The bug, verified against the live model (openai/gpt-5.6-luna) in the product's own language:
-- 「えびとかにのアレルギーがあります」 came back as {"allergens":["えび","かに"]} — allergy was the
-- only gating category llm-assist's prompt gave no example for, so the model mirrored the
-- writer's language. Venues record 'shellfish_free', the predicate looks for 'えび_free', and
-- allergy is on fn_propose_relaxation's never-relax list: zero candidates, permanently, with no
-- explanation, for a medical requirement. And even with a perfect vocabulary no provider on earth
-- publishes restaurant allergen data (0026's header surveys them), so every live venue arrives
-- with '{}' and fails closed — which is right, but must not be silent.
--
-- Every scratch venue below carries a unique dietary tag its event requires, so these venues can
-- never be feasible for the demo event and vice versa; the demo invariant is re-asserted by the
-- block that follows this one regardless.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00260000-0000-0000-0000-00000000a000';
  v_pid uuid := '00260000-0000-0000-0000-00000000a001';
  v_allergy_id uuid;
  v_result jsonb;
  v_feasible int;
  v_places text[];
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA allergen vocabulary', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, gen_random_uuid(), 'Allergy participant', 'organizer', 'station');
  update events set organizer_participant_id = v_pid where id = v_event;

  -- The vocabularies, asserted against literals so neither can drift from the TypeScript port
  -- (ALLERGEN_VOCABULARY / DIETARY_VOCABULARY in web/src/backend/engine.ts) or from llm-assist.
  perform t_check('the allergen vocabulary is the six labelled members',
                  fn_allergen_vocabulary() = array[
                    'buckwheat','egg','milk','peanut','shellfish','wheat'],
                  fn_allergen_vocabulary()::text);
  perform t_check('the dietary vocabulary is the four patterns',
                  fn_dietary_vocabulary() = array[
                    'gluten_free','halal','vegan','vegetarian'],
                  fn_dietary_vocabulary()::text);
  -- The venue side is the same vocabulary with a suffix, derived rather than restated.
  perform t_check('the venue side speaks the same vocabulary with _free',
                  fn_allergen_safe_tag_vocabulary() = array[
                    'buckwheat_free','egg_free','milk_free','peanut_free','shellfish_free',
                    'wheat_free'],
                  fn_allergen_safe_tag_vocabulary()::text);

  -- Canonicalisation. Every alias names the SAME ingredient as its member, so mapping preserves
  -- the requirement; this is the exact input the live model produced.
  perform t_check('the Japanese the model actually returned maps onto the crustacean member',
                  fn_allergen_canonical_allergens(array['えび','かに','海老','蟹','カニ','甲殻類'])
                    = array['shellfish'],
                  fn_allergen_canonical_allergens(array['えび','かに'])::text);
  perform t_check('and so do the other five 特定原材料 spellings',
                  fn_allergen_canonical_allergens(array['卵','たまご','玉子','鶏卵'])
                    = array['egg']
                  and fn_allergen_canonical_allergens(array['乳','牛乳','ミルク','乳製品'])
                    = array['milk']
                  and fn_allergen_canonical_allergens(array['落花生','ピーナッツ'])
                    = array['peanut']
                  and fn_allergen_canonical_allergens(array['小麦','こむぎ']) = array['wheat']
                  and fn_allergen_canonical_allergens(array['そば','蕎麦'])
                    = array['buckwheat']);
  perform t_check('canonical allergens are deduped and sorted',
                  fn_allergen_canonical_allergens(array['乳','卵','たまご','shellfish','えび'])
                    = array['egg','milk','shellfish'],
                  fn_allergen_canonical_allergens(array['乳','卵','えび'])::text);
  -- 貝 is molluscs and `shellfish` is the CRUSTACEAN tag (甲殻類), so folding it in would record
  -- a WEAKER requirement than was stated. グルテン is a dietary tag, not 小麦. Both are dropped
  -- here and preserved as the participant's own wording by llm-assist / the backfill instead.
  perform t_check('an allergen the vocabulary cannot express is dropped, never approximated',
                  fn_allergen_canonical_allergens(array['貝','大豆','ナッツ','マンゴー','グルテン'])
                    = '{}'::text[],
                  fn_allergen_canonical_allergens(array['貝','マンゴー'])::text);
  perform t_check('a value echoing the venue side''s _free suffix still lands on the allergen',
                  fn_allergen_canonical_allergens(array['SHELLFISH_FREE','Egg-Free'])
                    = array['egg','shellfish'],
                  fn_allergen_canonical_allergens(array['SHELLFISH_FREE'])::text);
  perform t_check('and the same rule applies to a constraint value',
                  fn_allergen_canonical_value('{"allergens":["えび","かに"]}')
                    = array['shellfish']
                  and fn_allergen_canonical_value('{"allergens":["マンゴー"]}') = '{}'::text[]
                  and fn_allergen_canonical_value('{}') = '{}'::text[]
                  -- An unreadable value is not a satisfied one, in either direction.
                  and fn_allergen_canonical_value('{"allergens":"えび"}') = '{}'::text[]);

  -- dietary, the same bug one category over. For 「卵と乳製品がだめです」 the live model invented
  -- {"tags":["egg-free","dairy-free"]} — allergens wearing a dietary shape, matchable by nothing.
  perform t_check('dietary Japanese maps onto the four patterns',
                  fn_dietary_canonical_tags(
                    array['ベジタリアン','ヴィーガン','ハラール','グルテンフリー'])
                    = array['gluten_free','halal','vegan','vegetarian'],
                  fn_dietary_canonical_tags(array['ベジタリアン'])::text);
  perform t_check('a spelling variant is the same token, not a new tag',
                  fn_dietary_canonical_tags(array['Gluten-Free','gluten free'])
                    = array['gluten_free']);
  perform t_check('and the tags the model invented for an ingredient are dropped',
                  fn_dietary_canonical_tags(array['egg-free','dairy-free','no-shellfish'])
                    = '{}'::text[],
                  fn_dietary_canonical_tags(array['egg-free'])::text);
  perform t_check('a dietary constraint value canonicalises the same way',
                  fn_dietary_canonical_value('{"tags":["ベジタリアン"]}') = array['vegetarian']
                  and fn_dietary_canonical_value('{"tags":["egg-free"]}') = '{}'::text[]
                  and fn_dietary_canonical_value('{"tags":"vegan"}') = '{}'::text[]);

  insert into restaurants (place_id) values
    ('qa0026_allergy_full'), ('qa0026_allergy_partial'), ('qa0026_allergy_none'),
    ('qa0026_allergy_and_budget');
  insert into restaurant_features
    (place_id, price_yen_estimate, room_type, dietary_tags, allergy_safe_tags)
  values
    ('qa0026_allergy_full', 3000, 'open', array['qa0026_allergy'],
     array['shellfish_free','egg_free']),
    ('qa0026_allergy_partial', 3000, 'open', array['qa0026_allergy'], array['shellfish_free']),
    -- No data at all: what every provider-discovered venue looks like, forever.
    ('qa0026_allergy_none', 3000, 'open', array['qa0026_allergy'], '{}'),
    -- Also over budget, so it is NOT one phone call away from being a candidate.
    ('qa0026_allergy_and_budget', 9000, 'open', array['qa0026_allergy'], '{}');

  -- The venue side is constrained, so `allergens` and `allergy_safe_tags` cannot drift into
  -- different languages the way they had.
  v_raised := false;
  begin
    update restaurant_features set allergy_safe_tags = array['えび_free']
     where place_id = 'qa0026_allergy_none';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('the venue side refuses a tag outside the vocabulary', v_raised);
  v_raised := false;
  begin
    update restaurant_features set allergy_safe_tags = array['貝_free']
     where place_id = 'qa0026_allergy_none';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('including a mollusc claim no allergen member covers', v_raised);
  -- …and the CHECK cannot drift from the function, because every member it lists is inserted.
  v_raised := false;
  begin
    update restaurant_features set allergy_safe_tags = fn_allergen_safe_tag_vocabulary()
     where place_id = 'qa0026_allergy_none';
  exception when check_violation then
    v_raised := true;
  end;
  perform t_check('and accepts every member fn_allergen_safe_tag_vocabulary lists', not v_raised);
  update restaurant_features set allergy_safe_tags = '{}'
   where place_id = 'qa0026_allergy_none';
  -- A hand-written legacy tag is canonicalised rather than kept: dropping a venue CLAIM is the
  -- fail-closed direction (the venue simply stops asserting something we cannot interpret),
  -- which is the opposite of dropping a participant's allergen.
  perform t_check('a legacy venue tag canonicalises onto the vocabulary',
                  fn_allergen_canonical_safe_tags(array['えび_free','shellfish_free','貝_free',
                                                        'vegan','barrier_free'])
                    = array['shellfish_free'],
                  fn_allergen_canonical_safe_tags(array['えび_free','貝_free'])::text);

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0026_allergy"]}', 'ANONYMOUS'),
         (v_event, v_pid, 'MUST', '4000円まで', 'budget', '{"max_yen":4000}', 'PUBLIC');
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'えびと卵のアレルギーがあります',
          'allergy', '{"allergens":["shellfish","egg"]}', 'ANONYMOUS')
  returning id into v_allergy_id;

  perform t_check('an allergy MUST is MET when the recorded _free tags cover every allergen',
                  fn_candidate_is_feasible(v_event, 'qa0026_allergy_full'));
  perform t_check('tags covering only part of the allergens stay infeasible',
                  not fn_candidate_is_feasible(v_event, 'qa0026_allergy_partial'));
  perform t_check('and no recorded tags at all is infeasible — unknown is not safe',
                  not fn_candidate_is_feasible(v_event, 'qa0026_allergy_none'));
  perform t_check('the predicate the gate and the count share agrees with the gate',
                  fn_allergy_allergens_met(array['shellfish_free','egg_free'],
                                           '{"allergens":["shellfish","egg"]}')
                  and not fn_allergy_allergens_met(array['shellfish_free'],
                                                   '{"allergens":["shellfish","egg"]}')
                  and not fn_allergy_allergens_met('{}'::text[],
                                                   '{"allergens":["shellfish"]}')
                  -- A MUST whose own value cannot be read is never certified as met.
                  and not fn_allergy_allergens_met(array['shellfish_free'],
                                                   '{"allergens":[]}')
                  and not fn_allergy_allergens_met(array['shellfish_free'],
                                                   '{"allergens":"shellfish"}'));
  perform t_check('the blocking types name allergy as the only obstacle',
                  fn_candidate_blocking_types(v_event, 'qa0026_allergy_none')
                    = array['allergy'],
                  fn_candidate_blocking_types(v_event, 'qa0026_allergy_none')::text);
  perform t_check('and name both obstacles when there are two',
                  fn_candidate_blocking_types(v_event, 'qa0026_allergy_and_budget')
                    = array['allergy','budget'],
                  fn_candidate_blocking_types(v_event, 'qa0026_allergy_and_budget')::text);

  v_result := fn_recompute_feasibility(v_event);
  perform t_check('only the venue whose tags cover every allergen is feasible',
                  (v_result->>'feasible_count')::int = 1, v_result::text);
  -- The reason is now in data the client can already read: 「N件はアレルギー対応が確認できません
  -- でした（お店に確認できます）」 instead of 「0件」. The over-budget venue is deliberately NOT
  -- counted: a phone call about its kitchen would not put it on the shortlist.
  perform t_check('the payload reports how many venues are only missing allergy proof',
                  (v_result->>'allergy_unverified_count')::int = 2, v_result::text);
  perform t_check('and every pre-0026 key is still there with its old meaning',
                  v_result ? 'run_id' and v_result ? 'feasible_count'
                  and v_result ? 'accessibility_unverified_count'
                  and (v_result->>'accessibility_unverified_count')::int = 0
                  and (v_result->>'run_id')::uuid is not null, v_result::text);

  -- NEVER RELAXABLE, AND NO accept_unknown. 0021 may ask a group to accept an unconfirmed smoking
  -- policy; nobody may be asked to consent to an unverified allergen claim. The escape is the
  -- count above plus verification_requirement = 'required' — reporting and a phone call, never
  -- consent.
  perform t_check('an allergy MUST is never proposed for relaxation',
                  fn_propose_relaxation(v_event) is null);
  perform t_check('there is no relaxation step for it to advertise',
                  fn_relaxed_value('allergy', '{"allergens":["shellfish"]}')
                    = '{"allergens":["shellfish"]}'::jsonb,
                  fn_relaxed_value('allergy', '{"allergens":["shellfish"]}')::text);
  perform t_check('and relaxing it would unlock nothing, so no question is ever phrased',
                  fn_count_unlocked_if_relaxed(v_event, v_allergy_id) = 0,
                  fn_count_unlocked_if_relaxed(v_event, v_allergy_id)::text);
  perform t_check('the constraint carries the required-verification cue 0018 derives',
                  (select verification_requirement from participant_constraints
                    where id = v_allergy_id) = 'required'
                  and (select sensitivity from participant_constraints
                        where id = v_allergy_id) = 'highly_sensitive');

  -- THE BUG ITSELF, stored the way the live model used to produce it.
  update participant_constraints set normalized_value = '{"allergens":["えび","かに"]}'
   where id = v_allergy_id;
  select count(*) into v_feasible from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('a Japanese allergen can never be matched by any venue',
                  v_feasible = 0
                  and not fn_candidate_is_feasible(v_event, 'qa0026_allergy_full'),
                  v_feasible::text);
  perform t_check('and it cannot be negotiated either, which is why it must never be stored',
                  fn_propose_relaxation(v_event) is null);
  v_result := fn_recompute_feasibility(v_event);
  -- Not silent any more: the three in-budget venues are reported as unverified, which is exactly
  -- what they are — allergy_safe_tags records only positive claims, so absence is never a
  -- contradiction.
  perform t_check('the zero is explained instead of merely reported',
                  (v_result->>'feasible_count')::int = 0
                  and (v_result->>'allergy_unverified_count')::int = 3, v_result::text);

  -- What 0026's one-shot backfill does to that row, using the same expression it uses.
  update participant_constraints
     set normalized_value = jsonb_build_object('allergens',
           to_jsonb(fn_allergen_canonical_value(normalized_value))),
         semantic_remainder = coalesce(semantic_remainder, btrim(raw_text))
   where id = v_allergy_id;
  perform t_check('the backfill rewrites it to the vocabulary and keeps the wording',
                  (select normalized_value from participant_constraints where id = v_allergy_id)
                    = '{"allergens":["shellfish"]}'::jsonb
                  and (select semantic_remainder from participant_constraints
                        where id = v_allergy_id) = 'えびと卵のアレルギーがあります',
                  (select normalized_value::text from participant_constraints
                    where id = v_allergy_id));
  perform t_check('and the venue is reachable again afterwards',
                  fn_candidate_is_feasible(v_event, 'qa0026_allergy_full'));

  -- The row where NOTHING is expressible (「マンゴーアレルギー」, canonicalised to an empty list).
  -- It stays a GATING allergy MUST — 0022 could re-type an inexpressible accessibility need to a
  -- non-gating `other` note, but doing that to a medical requirement would drop it out of the
  -- gate entirely and let the group be recommended a venue nobody has checked.
  update participant_constraints set normalized_value = '{"allergens":[]}'
   where id = v_allergy_id;
  v_result := fn_recompute_feasibility(v_event);
  perform t_check('an inexpressible allergen still fails closed for every venue',
                  (v_result->>'feasible_count')::int = 0, v_result::text);
  perform t_check('and every candidate is reported as unverified, which is simply true',
                  (v_result->>'allergy_unverified_count')::int = 3, v_result::text);
  perform t_check('it is still an allergy MUST, not a note, and still not negotiable',
                  (select normalized_type from participant_constraints
                    where id = v_allergy_id) = 'allergy'
                  and fn_propose_relaxation(v_event) is null);

  update participant_constraints set normalized_value = '{"allergens":["shellfish","egg"]}'
   where id = v_allergy_id;
  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event, r.place_id);
  perform t_check('and the covered venue is the only feasible one at the end',
                  v_places = array['qa0026_allergy_full'], v_places::text);

  -- The seeded fixture went through the migration's backfill: Emma's MUST was already canonical,
  -- so it is untouched and every seeded venue still covers it.
  perform t_check('the demo allergy MUST is canonical after the backfill',
                  (select normalized_value from participant_constraints
                    where event_id = '00000000-0000-0000-0000-000000000001'
                      and normalized_type = 'allergy')
                    = '{"allergens":["shellfish"]}'::jsonb);
  perform t_check('and the seeded venue tags are canonical too',
                  (select bool_and(allergy_safe_tags = array['shellfish_free'])
                     from restaurant_features
                    where place_id like 'demo_place_%'));
end $$;

-- ---------------------------------------------------------------------------
-- 0027: Tabelog's three columns, their write path, and the two things that must NOT happen.
--
-- Tabelog has no API, so the writer of these columns is an HTML scraper whose terms we do not
-- have consent under; it is off unless TABELOG_ENRICHMENT_ENABLED is exactly "true". None of
-- that is testable from SQL. What IS testable, and is what these checks are for:
--
--   * an UNRESOLVED venue is left NULL rather than guessed, and a run that resolved nothing
--     cannot erase an identity an earlier run confirmed (the present/absent key contract 0022
--     and 0023 established);
--   * a malformed resolution cannot reach a column, so a parser fault degrades the enrichment
--     instead of failing the search on a CHECK violation;
--   * TABELOG NEVER WRITES GOOGLE'S COLUMNS, and gates nothing.
--
-- THE "SCORING DOES NOT MOVE" ASSERTION IS GONE, AND WAS CONVERTED RATHER THAN DELETED.
-- 0027 asserted that every score came out byte-identical either side of a Tabelog write, which
-- was the correct assertion for a migration that deliberately stored the data and stopped —
-- 0027's own header says blending the two properly "is a separate change with its own tests".
-- 0028 is that change, so scores now MOVE, and the two halves of the old assertion have gone
-- in two different directions:
--   * the part that is still true is asserted harder than before: a Tabelog write may not touch
--     `rating` / `user_rating_count`, and Tabelog gates NOTHING in fn_candidate_blocking_types
--     (both checked column by column and type by type below);
--   * the part that is no longer true is replaced by the specific movement 0028 predicts —
--     the exact percentiles, the exact methods, and a shortlist that REORDERS. A test that
--     merely said "something changed" would pass for a raw mean too, which is the design 0028
--     exists to rule out.
--
-- The scratch venue carries a unique dietary tag its own event requires, so it can never be
-- feasible for the demo event and vice versa; the 0-then-3 invariant is re-asserted below.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00270000-0000-0000-0000-00000000a000';
  v_pid uuid := '00270000-0000-0000-0000-00000000a001';
  v_uid uuid := '00270000-0000-0000-0000-0000000000aa';
  v_written int;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_order_before text[];
  v_order_after text[];
  v_blocked_before text[];
  v_blocked_after text[];
  v_raised boolean;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA tabelog enrichment', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, v_uid, 'Tabelog QA', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into restaurants (place_id) values
    ('qa0027_resolved'), ('qa0027_unresolved'), ('qa0027_malformed');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags,
                                   rating, user_rating_count)
  values ('qa0027_resolved', 3000, 'open', array['qa0027_tabelog'], 4.0, 380),
         -- Shortlisted, searched, and its identity never confirmed — which is most of what a
         -- phone-only join returns, and the state that must stay NULL.
         ('qa0027_unresolved', 3000, 'open', array['qa0027_tabelog'], 4.4, 82),
         ('qa0027_malformed', 3000, 'open', array['qa0027_tabelog'], 3.9, 500);

  perform t_check('every venue starts with no Tabelog data at all',
                  (select count(*) from restaurant_features
                    where tabelog_id is null and tabelog_rating is null
                      and tabelog_review_count is null and tabelog_budget_yen is null)
                    = (select count(*) from restaurant_features));

  -- One enrichment pass. The `tabelog` key is present ONLY for the venue whose telephone
  -- number matched the page's own; the other two carry no key, which is what the Edge Function
  -- sends for "we could not confirm which page this is".
  select fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_resolved',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                     'rating', 3.39,
                                                     'review_count', 357)),
    jsonb_build_object('place_id', 'qa0027_unresolved'),
    jsonb_build_object('place_id', 'qa0027_malformed'))) into v_written;
  perform t_check('the writer touches only the venues whose identity was confirmed',
                  v_written = 1, v_written::text);
  perform t_check('a confirmed venue records the Tabelog id, score and review count',
                  (select tabelog_id = '13039534' and tabelog_rating = 3.39
                            and tabelog_review_count = 357
                     from restaurant_features where place_id = 'qa0027_resolved'));
  perform t_check('and an unresolved venue is left NULL rather than guessed',
                  (select tabelog_id is null and tabelog_rating is null
                            and tabelog_review_count is null
                     from restaurant_features where place_id = 'qa0027_unresolved'));

  -- Google's columns are Google's. Nothing here may touch them, because a Tabelog 3.39 and a
  -- Google 4.0 are not measurements of the same thing on the same scale.
  perform t_check('Google''s rating and review count are untouched by a Tabelog write',
                  (select rating = 4.0 and user_rating_count = 380
                     from restaurant_features where place_id = 'qa0027_resolved'));

  -- AUTHORITATIVE where there IS a confirmed identity: the score is a live figure and this is a
  -- refreshable cache of it, so a newer resolution replaces the old numbers — including with
  -- NULL when the page has stopped publishing a score.
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_resolved',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                     'rating', 3.41,
                                                     'review_count', 361))));
  perform t_check('a newer resolution replaces the stored score and count',
                  (select tabelog_rating = 3.41 and tabelog_review_count = 361
                     from restaurant_features where place_id = 'qa0027_resolved'));
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_resolved',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534'))));
  perform t_check('a page that publishes no score records NULL, keeping the identity',
                  (select tabelog_id = '13039534' and tabelog_rating is null
                            and tabelog_review_count is null
                     from restaurant_features where place_id = 'qa0027_resolved'));
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_resolved',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                     'rating', 3.39,
                                                     'review_count', 357))));

  -- ADDITIVE where there is NO answer, which is the common case: the flag off, the venue not in
  -- the five-venue shortlist, no telephone number to match on, Tabelog's search finding nothing,
  -- the page printing a different number, the request budget spent. None of them may erase an
  -- identity confirmed by an exact phone match on an earlier run.
  select fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_resolved'),
    jsonb_build_object('place_id', 'qa0027_resolved', 'tabelog', null),
    jsonb_build_object('place_id', 'qa0027_resolved', 'tabelog', '13039534'),
    jsonb_build_object('place_id', 'qa0027_resolved', 'tabelog', jsonb_build_array()),
    jsonb_build_object('tabelog', jsonb_build_object('tabelog_id', '13039534')),
    jsonb_build_object('place_id', 'qa0027_no_such_place',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534')))) into v_written;
  perform t_check('an absent, null or non-object tabelog key writes nothing at all',
                  v_written = 0, v_written::text);
  perform t_check('so a run that resolved nothing cannot erase a confirmed identity',
                  (select tabelog_id = '13039534' and tabelog_rating = 3.39
                     from restaurant_features where place_id = 'qa0027_resolved'));
  perform t_check('and a malformed candidate list is ignored rather than raising',
                  fn_record_tabelog_enrichment(v_event, null) = 0
                  and fn_record_tabelog_enrichment(v_event, '{}'::jsonb) = 0
                  and fn_record_tabelog_enrichment(v_event, '[]'::jsonb) = 0);

  -- THE ID IS THE RESOLUTION. Without a well-formed one there is no identity to attach a score
  -- to, so the whole element is discarded rather than writing loose numbers — a score attributed
  -- to the wrong venue is the failure the phone-only join exists to prevent. A scraper's failure
  -- mode is not a wrong number, it is a URL or an HTML fragment.
  select fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '', 'rating', 3.5)),
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object(
                         'tabelog_id', 'https://tabelog.com/tokyo/A1304/A130401/13039534/',
                         'rating', 3.5)),
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534abc',
                                                     'rating', 3.5)),
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '123', 'rating', 3.5)),
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', null, 'rating', 3.5)))
  ) into v_written;
  perform t_check('an id that is empty, a URL, not digits or too short writes nothing',
                  v_written = 0, v_written::text);
  perform t_check('so a score is never recorded without an identity to attach it to',
                  (select tabelog_rating is null and tabelog_review_count is null
                     from restaurant_features where place_id = 'qa0027_malformed'));

  -- An off-scale score or a junk count is a parser fault, not a fact. It records NULL for that
  -- field — the identity still lands — and can never violate 0027's CHECKs, so it cannot fail a
  -- whole search the way a raw insert would.
  select fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '13100419',
                                                     'rating', 7.2,
                                                     'review_count', -5))) ) into v_written;
  perform t_check('an off-scale score and a negative count are dropped, not recorded',
                  v_written = 1
                  and (select tabelog_id = '13100419' and tabelog_rating is null
                              and tabelog_review_count is null
                         from restaurant_features where place_id = 'qa0027_malformed'));
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '13100419',
                                                     'rating', '3.17',
                                                     'review_count', '315'))));
  perform t_check('a numeric value arriving as a JSON string is still read',
                  (select tabelog_rating = 3.17 and tabelog_review_count = 315
                     from restaurant_features where place_id = 'qa0027_malformed'));
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '13100419',
                                                     'rating', '４.２',
                                                     'review_count', '1,304'))));
  perform t_check('and a full-width or comma-formatted value is NOT guessed at',
                  (select tabelog_rating is null and tabelog_review_count is null
                     from restaurant_features where place_id = 'qa0027_malformed'));

  -- The CHECKs themselves, at the table, for anything that ever writes these columns without
  -- going through the function above. Same shape as 0016's guard rails on Google's rating.
  v_raised := false;
  begin
    update restaurant_features set tabelog_rating = 5.1 where place_id = 'qa0027_unresolved';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('the table refuses a Tabelog score above 5', v_raised);
  v_raised := false;
  begin
    update restaurant_features set tabelog_review_count = -1
     where place_id = 'qa0027_unresolved';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('the table refuses a negative Tabelog review count', v_raised);
  v_raised := false;
  begin
    update restaurant_features set tabelog_id = 'A1304' where place_id = 'qa0027_unresolved';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('the table refuses a Tabelog id that is not digits', v_raised);
  perform t_check('and NULL is legal in all of them, because unresolved is the normal state',
                  (select tabelog_id is null and tabelog_budget_yen is null
                     from restaurant_features where place_id = 'qa0027_unresolved'));

  -- The resolution cache. One row per place, so "we asked and learned nothing" is
  -- representable — an unresolved attempt has no Tabelog id to key a row by, and forgetting it
  -- would make every search re-ask about the venues that will never resolve.
  insert into restaurant_source_records (place_id, provider, source_id, payload)
  values ('qa0027_unresolved', 'tabelog', 'resolution',
          '{"resolved":false,"phone_match":"not_confirmed"}'::jsonb);
  perform t_check('tabelog is a legal provider for a cached resolution',
                  (select count(*) from restaurant_source_records
                    where provider = 'tabelog') = 1);
  v_raised := false;
  begin
    insert into restaurant_source_records (place_id, provider, source_id)
    values ('qa0027_unresolved', 'tabelog_reviews', 'resolution');
  exception when check_violation then v_raised := true;
  end;
  perform t_check('and the provider list is still closed to everything else', v_raised);

  -- WHAT A TABELOG WRITE MAY AND MAY NOT MOVE. Since 0028 it moves the quality dimension, and
  -- these three venues are a worked example of exactly how. Google's own columns and every
  -- feasibility decision stay exactly where they were.
  --
  -- Google, shrunk toward 3.9 with 50 prior reviews — (50*3.9 + r*n)/(50+n):
  --   qa0027_malformed   3.9 / 500  -> 3.9000   percentile (0 + 1/2)/3 = 0.1667
  --   qa0027_resolved    4.0 / 380  -> 3.9884   percentile (1 + 1/2)/3 = 0.5
  --   qa0027_unresolved  4.4 /  82  -> 4.2106   percentile (2 + 1/2)/3 = 0.8333
  -- so BEFORE any Tabelog data the quality scores are 0.2 + 0.8*percentile — 0.3334 / 0.6 /
  -- 0.8666 — and the shortlist is unresolved, resolved, malformed.
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA pool gate',
          'dietary', '{"tags":["qa0027_tabelog"]}', 'ANONYMOUS');
  update restaurant_features set tabelog_id = null, tabelog_rating = null,
                                 tabelog_review_count = null, tabelog_budget_yen = null
   where place_id like 'qa0027_%';
  v_result := fn_recompute_feasibility(v_event);
  perform t_check('the QA venues are feasible before any Tabelog data exists',
                  (v_result->>'feasible_count')::int = 3, v_result::text);
  select jsonb_agg(jsonb_build_object('place', s.restaurant_place_id,
                                      'quality', s.quality_score,
                                      'objective', s.objective_score,
                                      'breakdown', s.score_breakdown)
                   order by s.restaurant_place_id)
    into v_before
    from recommendation_scores s
   where s.run_id = (v_result->>'run_id')::uuid;
  select array_agg(s.restaurant_place_id order by s.objective_score desc, s.restaurant_place_id)
    into v_order_before
    from recommendation_scores s
   where s.run_id = (v_result->>'run_id')::uuid;
  perform t_check('Google alone scores all three on its own pool of three',
                  v_before = jsonb_build_array(
                    jsonb_build_object('place', 'qa0027_malformed', 'quality', 0.3334,
                      'objective', 0.4667, 'breakdown', v_before->0->'breakdown'),
                    jsonb_build_object('place', 'qa0027_resolved', 'quality', 0.6000,
                      'objective', 0.5200, 'breakdown', v_before->1->'breakdown'),
                    jsonb_build_object('place', 'qa0027_unresolved', 'quality', 0.8666,
                      'objective', 0.5733, 'breakdown', v_before->2->'breakdown')),
                  v_before::text);
  perform t_check('and every one of them says google_only',
                  (select bool_and(s.score_breakdown->'quality'->>'method' = 'google_only')
                     from recommendation_scores s
                    where s.run_id = (v_result->>'run_id')::uuid));
  select array_agg(t.blocked order by t.blocked) into v_blocked_before
    from (select unnest(fn_candidate_blocking_types(v_event, 'qa0027_unresolved')) as blocked) t;

  -- Now the same two venues Tabelog resolved, with the figures 0027 already used. Tabelog,
  -- shrunk toward 3.3 — (50*3.3 + r*n)/(50+n):
  --   qa0027_resolved   3.39 / 357 -> 3.3789   percentile (0 + 1/2)/2 = 0.25
  --   qa0027_malformed  4.24 / 360 -> 4.1254   percentile (1 + 1/2)/2 = 0.75
  -- Tabelog's ranking of the two is the OPPOSITE of Google's, so the blend flips them:
  --   resolved   mean(0.5,    0.25) = 0.375   -> 0.2 + 0.8*0.375  = 0.5
  --   malformed  mean(0.1667, 0.75) = 0.4584  -> 0.2 + 0.8*0.4584 = 0.5667
  --   unresolved google only,   0.8333        -> 0.8666, UNCHANGED to the last digit
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0027_resolved',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                     'rating', 3.39,
                                                     'review_count', 357)),
    jsonb_build_object('place_id', 'qa0027_malformed',
                       'tabelog', jsonb_build_object('tabelog_id', '13100419',
                                                     'rating', 4.24,
                                                     'review_count', 360))));
  v_result := fn_recompute_feasibility(v_event);
  select jsonb_agg(jsonb_build_object('place', s.restaurant_place_id,
                                      'quality', s.quality_score,
                                      'objective', s.objective_score,
                                      'breakdown', s.score_breakdown)
                   order by s.restaurant_place_id)
    into v_after
    from recommendation_scores s
   where s.run_id = (v_result->>'run_id')::uuid;
  select array_agg(s.restaurant_place_id order by s.objective_score desc, s.restaurant_place_id)
    into v_order_after
    from recommendation_scores s
   where s.run_id = (v_result->>'run_id')::uuid;

  -- 1. THE SCORES MOVE, and by exactly the amount the percentile blend predicts.
  perform t_check('a Tabelog write now moves the quality scores it has data for',
                  (v_after->0->>'quality')::numeric = 0.5667
                  and (v_after->1->>'quality')::numeric = 0.5000,
                  v_after::text);
  perform t_check('and records which providers spoke for each venue',
                  (select array_agg(s.score_breakdown->'quality'->>'method'
                                    order by s.restaurant_place_id)
                     from recommendation_scores s
                    where s.run_id = (v_result->>'run_id')::uuid)
                  = array['google_and_tabelog', 'google_and_tabelog', 'google_only']);
  perform t_check('with the per-provider percentiles it blended',
                  (select array_agg(
                            coalesce(s.score_breakdown->'quality'->>'google_percentile', 'null')
                            || '/' ||
                            coalesce(s.score_breakdown->'quality'->>'tabelog_percentile', 'null')
                            order by s.restaurant_place_id)
                     from recommendation_scores s
                    where s.run_id = (v_result->>'run_id')::uuid)
                  = array['0.1667/0.7500', '0.5000/0.2500', '0.8333/null'],
                  v_after::text);
  perform t_check('and the volume-adjusted score each rank came from',
                  (select array_agg(s.score_breakdown->'quality'->>'tabelog_shrunk'
                                    order by s.restaurant_place_id)
                     from recommendation_scores s
                    where s.run_id = (v_result->>'run_id')::uuid)
                  = array['4.1254', '3.3789', null]);

  -- 2. PRESENCE IS NEITHER A BONUS NOR A PENALTY. The venue Tabelog said nothing about keeps its
  -- Google-only percentile to the last digit — it is not averaged against 0 and not averaged
  -- against 0.5.
  perform t_check('a venue with no Tabelog score is byte-identical either side of the write',
                  v_before->2 = v_after->2, (v_after->2)::text);

  -- 3. THE SHORTLIST REORDERS, which is what "Tabelog counts" means. Google ranked resolved
  -- above malformed; Tabelog ranks malformed above resolved by more, so the blend swaps them.
  perform t_check('Google alone ordered them unresolved, resolved, malformed',
                  v_order_before = array['qa0027_unresolved', 'qa0027_resolved',
                                         'qa0027_malformed'],
                  v_order_before::text);
  perform t_check('the blend reorders the shortlist',
                  v_order_after = array['qa0027_unresolved', 'qa0027_malformed',
                                        'qa0027_resolved'],
                  v_order_after::text);
  perform t_check('so the two providers genuinely disagreed and the blend heard both',
                  v_order_before <> v_order_after);

  -- 4. WHAT STILL MAY NOT MOVE, asserted harder than 0027 did. Google's two columns are
  -- Google's, and nothing Tabelog supplies gates anything.
  perform t_check('Google''s rating columns are untouched by the write, venue by venue',
                  (select array_agg(rf.rating::text || '/' || rf.user_rating_count::text
                                    order by rf.place_id)
                     from restaurant_features rf where rf.place_id like 'qa0027_%')
                  = array['3.9/500', '4.0/380', '4.4/82']);
  perform t_check('and the breakdown still reports them as Google''s own figures',
                  (v_after->1->'breakdown'->'quality'->>'rating')::numeric = 4.0
                  and (v_after->1->'breakdown'->'quality'->>'user_rating_count')::int = 380
                  and (v_after->1->'breakdown'->'quality'->>'prior_rating')::numeric = 3.9);
  perform t_check('and feasibility is unchanged too — Tabelog gates nothing',
                  (v_result->>'feasible_count')::int = 3
                  and fn_candidate_is_feasible(v_event, 'qa0027_unresolved'),
                  v_result::text);
  perform t_check('every venue is still feasible, and blocked by nothing, after the write',
                  (select bool_and(coalesce(array_length(
                            fn_candidate_blocking_types(v_event, rf.place_id), 1), 0) = 0)
                     from restaurant_features rf where rf.place_id like 'qa0027_%'));
  select array_agg(t.blocked order by t.blocked) into v_blocked_after
    from (select unnest(fn_candidate_blocking_types(v_event, 'qa0027_unresolved')) as blocked) t;
  perform t_check('and the blocking-type answer is identical either side of the write',
                  v_blocked_before is not distinct from v_blocked_after);

  -- The write path is the provider pipeline's. A client that could call it could attribute any
  -- Tabelog page, and any score, to any venue.
  perform t_as_user(v_uid);
  v_raised := false;
  begin
    perform fn_record_tabelog_enrichment(v_event, '[]'::jsonb);
  exception when insufficient_privilege then v_raised := true;
  end;
  perform t_check('an API caller cannot record Tabelog enrichment', v_raised);
  perform t_as_admin();
  perform t_check('service_role may, and only service_role and the owner may',
                  has_function_privilege('service_role',
                    'public.fn_record_tabelog_enrichment(uuid, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated',
                    'public.fn_record_tabelog_enrichment(uuid, jsonb)', 'EXECUTE')
                  and not has_function_privilege('anon',
                    'public.fn_record_tabelog_enrichment(uuid, jsonb)', 'EXECUTE'));

  -- An unknown event is a caller bug, not something to write venue data for.
  v_raised := false;
  begin
    perform fn_record_tabelog_enrichment('00270000-0000-0000-0000-0000000000ff'::uuid,
                                         '[]'::jsonb);
  exception when others then v_raised := true;
  end;
  perform t_check('recording enrichment for an unknown event raises', v_raised);

  -- The three columns are readable by the client that would display them (0024's rule: a new
  -- column reachable by a client needs the grant to exist, and a table-level grant covers
  -- columns added later).
  perform t_check('the new columns are readable through the restaurant_features grant',
                  has_column_privilege('authenticated', 'public.restaurant_features',
                                       'tabelog_rating', 'SELECT')
                  and has_column_privilege('authenticated', 'public.restaurant_features',
                                           'tabelog_review_count', 'SELECT')
                  and has_column_privilege('authenticated', 'public.restaurant_features',
                                           'tabelog_id', 'SELECT'));

  -- Nothing above may have touched the demo fixture: it has no phone numbers, no Places
  -- payloads and no Tabelog rows, and the flag is off anyway. Verified, not assumed.
  perform t_check('the demo fixture holds no Tabelog data whatsoever',
                  (select count(*) from restaurant_features
                    where place_id like 'demo_place_%'
                      and tabelog_id is null and tabelog_rating is null
                      and tabelog_review_count is null and tabelog_budget_yen is null) = 4);
end $$;

-- ---------------------------------------------------------------------------
-- 0028 (A): the two display columns off pages we already fetch.
--
-- restaurant_features.tabelog_budget_yen — the UPPER bound of Tabelog's DINNER band, written by
-- the same fn_record_tabelog_enrichment path on 0027's exact present/absent contract, and NEVER
-- written into price_yen_estimate: that column is Google's priceRange or Hot Pepper's 予算 band,
-- both held under terms that permit it, and a budget MUST is decided against it alone.
--
-- restaurant_features.photo_url — Hot Pepper's photo.pc.m, a sanctioned API field on Recruit's
-- own image host, written by fn_record_provider_photo on 0023's present/absent contract. The
-- CHECK is the interesting part: it makes "never a Google photo, never a Tabelog image"
-- structurally true rather than a promise in a comment.
--
-- The scratch venues carry a unique dietary tag their own event requires, exactly as 0027's do,
-- so they can never be feasible for the demo event and vice versa.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00280000-0000-0000-0000-00000000a000';
  v_pid uuid := '00280000-0000-0000-0000-00000000a001';
  v_uid uuid := '00280000-0000-0000-0000-0000000000aa';
  v_written int;
  v_raised boolean;
  v_all_null boolean;
  v_junk text;
  v_photo text := 'https://imgfp.hotp.jp/IMGH/12/34/P123456789/P123456789_168.jpg';
  v_other text := 'https://imgfp.hotp.jp/IMGH/99/88/P987654321/P987654321_168.jpg';
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA 0028 display fields', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, v_uid, 'Display QA', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into restaurants (place_id) values ('qa0028_band'), ('qa0028_photo');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags)
  values ('qa0028_band', 3000, 'open', array['qa0028_display']),
         ('qa0028_photo', 3000, 'open', array['qa0028_display']);

  perform t_check('both new columns start NULL, because absent is the normal state',
                  (select tabelog_budget_yen is null and photo_url is null
                     from restaurant_features where place_id = 'qa0028_band'));

  -- ---- tabelog_budget_yen -------------------------------------------------
  -- The band's UPPER bound. ￥8,000～￥9,999 is 9999, so a 「max_yen 9000」 question about this
  -- venue has to be answered NO — the same rule placesPriceYen applies to Google's priceRange
  -- and hotPepperBudgetYen to 「3001〜4000円」. The Edge Function does the parsing; what the
  -- write path has to get right is that only a plain positive integer lands.
  select fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0028_band',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                     'rating', 3.39,
                                                     'review_count', 357,
                                                     'budget_yen', 9999)))) into v_written;
  perform t_check('a confirmed venue records the dinner band''s upper bound',
                  v_written = 1
                  and (select tabelog_budget_yen = 9999 from restaurant_features
                        where place_id = 'qa0028_band'), v_written::text);
  perform t_check('and it is NOT written into price_yen_estimate — that column is not Tabelog''s',
                  (select price_yen_estimate = 3000 from restaurant_features
                    where place_id = 'qa0028_band'));

  -- 「-」 (a lunch-only venue), absent, or unparseable is NULL and NEVER 0: 0021 fails a budget
  -- MUST closed on NULL and reports it as coverage, while a 0 would make the venue look free.
  -- The band arrives already parsed, so what reaches here is a number or nothing — and a
  -- full-width numeral is not guessed at, exactly as 0027 established for the score.
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0028_band',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534'))));
  perform t_check('a page with no dinner band records NULL, keeping the identity',
                  (select tabelog_id = '13039534' and tabelog_budget_yen is null
                     from restaurant_features where place_id = 'qa0028_band'));
  perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0028_band',
                       'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                     'budget_yen', 8000))));
  perform t_check('a plain integer is read',
                  (select tabelog_budget_yen = 8000 from restaurant_features
                    where place_id = 'qa0028_band'));

  -- Every one of these is written between two passes that DO land 8000, so a NULL below is the
  -- value being refused rather than the write never happening.
  v_all_null := true;
  for v_junk in
    select value from (values ('0'), ('-'), ('０'), ('８０００'), ('9999.5'),
                              ('￥8,000～￥9,999'), ('-1'), ('1e4'), ('')) as junk(value)
  loop
    perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
      jsonb_build_object('place_id', 'qa0028_band',
                         'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                       'budget_yen', v_junk))));
    if (select tabelog_budget_yen from restaurant_features
         where place_id = 'qa0028_band') is not null
    then
      v_all_null := false;
    end if;
    perform fn_record_tabelog_enrichment(v_event, jsonb_build_array(
      jsonb_build_object('place_id', 'qa0028_band',
                         'tabelog', jsonb_build_object('tabelog_id', '13039534',
                                                       'budget_yen', 8000))));
  end loop;
  perform t_check('but 0, a dash, a full-width numeral, a decimal, a whole band string, a '
                  || 'negative, exponent notation and an empty string all record NULL',
                  v_all_null);
  perform t_check('and the venue is back to a readable band, so the loop above proved a refusal',
                  (select tabelog_budget_yen = 8000 from restaurant_features
                    where place_id = 'qa0028_band'));

  -- The CHECK itself, for anything that writes the column without going through the function.
  v_raised := false;
  begin
    update restaurant_features set tabelog_budget_yen = 0 where place_id = 'qa0028_band';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('the table refuses a dinner band of 0 — free is not a price we observed',
                  v_raised);
  v_raised := false;
  begin
    update restaurant_features set tabelog_budget_yen = -1 where place_id = 'qa0028_band';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('and refuses a negative one', v_raised);

  -- ---- photo_url ----------------------------------------------------------
  select fn_record_provider_photo(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0028_photo', 'photo_url', v_photo))) into v_written;
  perform t_check('a matched shop''s Recruit thumbnail is recorded',
                  v_written = 1
                  and (select photo_url = v_photo from restaurant_features
                        where place_id = 'qa0028_photo'), v_written::text);

  -- ABSENT key = this candidate was never matched in Hot Pepper (about 40% of live venues,
  -- because the join is an exact telephone match and nothing weaker). Nothing learned, nothing
  -- erased — 0017's non-destructive rule.
  select fn_record_provider_photo(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0028_photo'),
    jsonb_build_object('photo_url', v_other),
    jsonb_build_object('place_id', 'qa0028_no_such_place', 'photo_url', v_other))) into v_written;
  perform t_check('an absent photo_url key writes nothing at all', v_written = 0, v_written::text);
  perform t_check('so an unmatched candidate cannot erase a photograph we already have',
                  (select photo_url = v_photo from restaurant_features
                    where place_id = 'qa0028_photo'));

  -- PRESENT key = Hot Pepper's current answer, so it may retract. A shop can remove its
  -- photograph, and pointing a card at a URL we know is withdrawn is worse than showing none.
  select fn_record_provider_photo(v_event, jsonb_build_array(
    jsonb_build_object('place_id', 'qa0028_photo', 'photo_url', null))) into v_written;
  perform t_check('a matched shop with no photograph retracts the stored URL',
                  v_written = 1
                  and (select photo_url is null from restaurant_features
                        where place_id = 'qa0028_photo'), v_written::text);

  -- WHAT MAY NEVER BE STORED, and the reason each one is refused rather than filtered later:
  -- an http URL is a mixed-content image, another host is somebody else's licence, and a
  -- tabelog.com image is the reproduction the whole scraper design refuses to perform (its
  -- photo pages are on our own disallow list and the photographs are not Tabelog's to license).
  v_all_null := true;
  for v_junk in
    select value from (values
      ('http://imgfp.hotp.jp/IMGH/12/34/P1/P1_168.jpg'),
      ('https://lh3.googleusercontent.com/places/ABC/photo.jpg'),
      ('https://tabelog.com/imgview/original?id=r1234567890.jpg'),
      ('https://imgfp.hotp.jp.evil.example/IMGH/12/34/P1/P1_168.jpg'),
      ('https://evil.example/?host=imgfp.hotp.jp'),
      ('//imgfp.hotp.jp/IMGH/12/34/P1/P1_168.jpg'),
      ('https://imgfp.hotp.jp/IMGH/12 34/P1_168.jpg'),
      ('imgfp.hotp.jp/IMGH/12/34/P1_168.jpg'),
      ('HTTPS://IMGFP.HOTP.JP/IMGH/12/34/P1_168.jpg'),
      ('')) as bad(value)
  loop
    -- A good value first, so a NULL below is this value being refused rather than nothing
    -- happening at all.
    perform fn_record_provider_photo(v_event, jsonb_build_array(
      jsonb_build_object('place_id', 'qa0028_photo', 'photo_url', v_photo)));
    perform fn_record_provider_photo(v_event, jsonb_build_array(
      jsonb_build_object('place_id', 'qa0028_photo', 'photo_url', v_junk)));
    if (select photo_url from restaurant_features
         where place_id = 'qa0028_photo') is not null
    then
      v_all_null := false;
    end if;
  end loop;
  perform t_check('an http URL, a Google photo, a Tabelog image, a look-alike host, a '
                  || 'schemeless, whitespace-bearing, upper-cased or empty value: all NULL',
                  v_all_null);

  -- The CHECK, so the same three sentences hold for anything that writes the column directly.
  v_raised := false;
  begin
    update restaurant_features set photo_url = 'https://tabelog.com/img/r1.jpg'
     where place_id = 'qa0028_photo';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('the table itself refuses a Tabelog image URL', v_raised);
  v_raised := false;
  begin
    update restaurant_features set photo_url = 'http://imgfp.hotp.jp/a.jpg'
     where place_id = 'qa0028_photo';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('and refuses a non-https one', v_raised);
  v_raised := false;
  begin
    update restaurant_features
       set photo_url = 'https://imgfp.hotp.jp/' || repeat('a', 500)
     where place_id = 'qa0028_photo';
  exception when check_violation then v_raised := true;
  end;
  perform t_check('and refuses one longer than a URL can honestly be', v_raised);
  update restaurant_features set photo_url = v_photo where place_id = 'qa0028_photo';
  perform t_check('while Recruit''s own host is accepted directly too',
                  (select photo_url = v_photo from restaurant_features
                    where place_id = 'qa0028_photo'));

  -- Neither column gates anything. A photograph obviously cannot, and the Tabelog band
  -- deliberately does not: fn_candidate_blocking_types has no branch that reads either.
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA 0028 pool gate',
          'dietary', '{"tags":["qa0028_display"]}', 'ANONYMOUS'),
         (v_event, v_pid, 'MUST', 'budget under 4000 yen',
          'budget', '{"max_yen":4000}', 'PUBLIC');
  perform t_check('a budget MUST is decided on price_yen_estimate, never on the Tabelog band',
                  fn_candidate_is_feasible(v_event, 'qa0028_band')
                  and (select tabelog_budget_yen = 8000 and price_yen_estimate = 3000
                         from restaurant_features where place_id = 'qa0028_band'));
  update restaurant_features set price_yen_estimate = 5000 where place_id = 'qa0028_band';
  perform t_check('and moving the column that IS the price does gate it',
                  not fn_candidate_is_feasible(v_event, 'qa0028_band')
                  and fn_candidate_blocking_types(v_event, 'qa0028_band') = array['budget']);
  update restaurant_features set price_yen_estimate = 3000 where place_id = 'qa0028_band';

  -- Privileges: both writers are the provider pipeline's, exactly as 0023's and 0027's are.
  perform t_as_user(v_uid);
  v_raised := false;
  begin
    perform fn_record_provider_photo(v_event, '[]'::jsonb);
  exception when insufficient_privilege then v_raised := true;
  end;
  perform t_check('an API caller cannot record a venue photograph', v_raised);
  perform t_as_admin();
  perform t_check('only service_role and the owner may',
                  has_function_privilege('service_role',
                    'public.fn_record_provider_photo(uuid, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated',
                    'public.fn_record_provider_photo(uuid, jsonb)', 'EXECUTE')
                  and not has_function_privilege('anon',
                    'public.fn_record_provider_photo(uuid, jsonb)', 'EXECUTE'));
  v_raised := false;
  begin
    perform fn_record_provider_photo('00280000-0000-0000-0000-0000000000ff'::uuid, '[]'::jsonb);
  exception when others then v_raised := true;
  end;
  perform t_check('recording a photograph for an unknown event raises', v_raised);
  perform t_check('and a malformed candidate list is ignored rather than raising',
                  fn_record_provider_photo(v_event, null) = 0
                  and fn_record_provider_photo(v_event, '{}'::jsonb) = 0
                  and fn_record_provider_photo(v_event, '[]'::jsonb) = 0);

  -- photo_url is read by a client (web/src/backend/supabase.ts selects it), so 0024's rule
  -- applies: the grant has to exist and be asserted where the column is.
  perform t_check('both new columns are readable through the restaurant_features grant',
                  has_column_privilege('authenticated', 'public.restaurant_features',
                                       'photo_url', 'SELECT')
                  and has_column_privilege('authenticated', 'public.restaurant_features',
                                           'tabelog_budget_yen', 'SELECT'));
  perform t_check('and the demo fixture holds neither, because nothing matched it',
                  (select count(*) from restaurant_features
                    where place_id like 'demo_place_%'
                      and photo_url is null and tabelog_budget_yen is null) = 4);
end $$;

-- ---------------------------------------------------------------------------
-- 0028 (B): quality counts Tabelog, as a RANK inside its own provider's pool.
--
-- THE MEASUREMENT THAT DECIDES THE DESIGN, over the same twenty Shinjuku izakaya:
--
--            min    p25   median   p75    max    span
--   Tabelog  3.07   3.09   3.22    3.39   3.53   0.46
--   Google   3.90   4.20   4.40    4.50   4.90   1.00
--
-- A raw mean is off by ~1.16 in level, so it would rank venues by whether we managed to scrape
-- them; a fixed rescale misweights the spread by a factor of two. So each provider's
-- volume-adjusted score is turned into a PERCENTILE within that provider's own pool of feasible
-- candidates, and quality is the mean of the percentiles that exist, banded into [0.2, 1.0].
--
-- What this block pins down, with figures hand-derived from 0028's definitions (the same numbers
-- web/scripts/verify-engine.ts section 24 asserts against the TypeScript port — if the two ever
-- disagree, this file is authoritative):
--   * the percentile's shape: the median of a pool is exactly 0.5, the pool reflects x -> 1-x,
--     a pool of ONE is 0.5, and ties share one value;
--   * the four `method` values, so a client is never left inferring provenance;
--   * presence is neither a bonus nor a penalty;
--   * the demo fixture is untouched: 0 stays 0, and the shortlist is still 001/002/004.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00280000-0000-0000-0000-00000000b000';
  v_pid uuid := '00280000-0000-0000-0000-00000000b001';
  v_uid uuid := '00280000-0000-0000-0000-0000000000bb';
  v_result jsonb;
  v_run uuid;
  v_pcts text[];
  v_scores numeric[];
  v_before_score numeric;
  v_after_score numeric;
begin
  perform t_as_admin();

  -- fn_provider_quality_shrunk / fn_quality_prior_rating, before any pool exists.
  perform t_check('each provider is shrunk toward its own prior',
                  fn_quality_prior_rating('google') = 3.9
                  and fn_quality_prior_rating('tabelog') = 3.3
                  and fn_quality_prior_rating('yelp') is null);
  perform t_check('and an unknown provider yields no score rather than Google''s by default',
                  fn_provider_quality_shrunk(4.3, 800, fn_quality_prior_rating('yelp'))
                    is null);
  perform t_check('shrink(r, n) = (50*prior + r*n)/(50+n), rounded to four decimals',
                  fn_provider_quality_shrunk(4.3, 800, 3.9) = 4.2765
                  and fn_provider_quality_shrunk(5.0, 3, 3.9) = 3.9623
                  and fn_provider_quality_shrunk(3.22, 300, 3.3) = 3.2314);
  perform t_check('so volume beats a small perfect score inside a provider',
                  fn_provider_quality_shrunk(4.3, 800, 3.9)
                    > fn_provider_quality_shrunk(5.0, 3, 3.9));
  perform t_check('no rating, a zero rating or no review count is "no signal", never "terrible"',
                  fn_provider_quality_shrunk(null, 800, 3.9) is null
                  and fn_provider_quality_shrunk(0, 800, 3.9) is null
                  and fn_provider_quality_shrunk(4.3, 0, 3.9) is null
                  and fn_provider_quality_shrunk(4.3, null, 3.9) is null);

  insert into events (id, name, objective, status)
  values (v_event, 'QA 0028 quality percentiles', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference)
  values (v_pid, v_event, v_uid, 'Percentile QA', 'organizer', 'office');
  update events set organizer_participant_id = v_pid where id = v_event;
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'QA 0028 quality pool gate',
          'dietary', '{"tags":["qa0028_quality"]}', 'ANONYMOUS');

  -- FIVE venues, same review count, so the shrunk order is the rating order and the pool is a
  -- clean 0.1 / 0.3 / 0.5 / 0.7 / 0.9. The scoring pass writes at most five cards, which is
  -- exactly this pool.
  insert into restaurants (place_id) values
    ('qa0028_q1'), ('qa0028_q2'), ('qa0028_q3'), ('qa0028_q4'), ('qa0028_q5');
  insert into restaurant_features (place_id, price_yen_estimate, room_type, dietary_tags,
                                   rating, user_rating_count)
  values ('qa0028_q1', 3000, 'open', array['qa0028_quality'], 3.5, 200),
         ('qa0028_q2', 3000, 'open', array['qa0028_quality'], 3.8, 200),
         ('qa0028_q3', 3000, 'open', array['qa0028_quality'], 4.0, 200),
         ('qa0028_q4', 3000, 'open', array['qa0028_quality'], 4.2, 200),
         ('qa0028_q5', 3000, 'open', array['qa0028_quality'], 4.6, 200);

  v_result := fn_recompute_feasibility(v_event);
  v_run := (v_result->>'run_id')::uuid;
  perform t_check('the five QA venues are the feasible pool',
                  (v_result->>'feasible_count')::int = 5, v_result::text);
  select array_agg(s.score_breakdown->'quality'->>'google_percentile'
                   order by s.restaurant_place_id)
    into v_pcts from recommendation_scores s where s.run_id = v_run;
  perform t_check('the median of a five-venue pool is exactly 0.5',
                  v_pcts = array['0.1000', '0.3000', '0.5000', '0.7000', '0.9000'],
                  v_pcts::text);
  perform t_check('the bottom is 0.1 and not 0, and the top is 0.9 and not 1 — percent_rank() '
                  || 'and cume_dist() would penalise and reward exactly those two',
                  v_pcts[1] = '0.1000' and v_pcts[5] = '0.9000');
  perform t_check('and the pool sums to n/2, which is what makes the mid-rank symmetric',
                  (select sum((s.score_breakdown->'quality'->>'google_percentile')::numeric)
                     from recommendation_scores s where s.run_id = v_run) = 2.5);
  select array_agg(s.quality_score order by s.restaurant_place_id)
    into v_scores from recommendation_scores s where s.run_id = v_run;
  perform t_check('the published score is that rank banded into [0.2, 1.0]',
                  v_scores = array[0.2800, 0.4400, 0.6000, 0.7600, 0.9200]::numeric[],
                  v_scores::text);
  perform t_check('every one of them says google_only, and names the pool it was ranked in',
                  (select bool_and(s.score_breakdown->'quality'->>'method' = 'google_only'
                    and (s.score_breakdown->'quality'->>'google_ranked_candidates')::int = 5
                    and (s.score_breakdown->'quality'->>'tabelog_ranked_candidates')::int = 0)
                     from recommendation_scores s where s.run_id = v_run));

  -- TIES SHARE ONE VALUE. q2 is given q3's figures, so both hold (1 + 2/2)/5 = 0.4 — the
  -- midpoint of the 0.3-to-0.5 range they jointly occupy — and neither is ordered above the
  -- other by anything the percentile invented. The pool still sums to n/2.
  update restaurant_features set rating = 4.0 where place_id = 'qa0028_q2';
  v_result := fn_recompute_feasibility(v_event);
  v_run := (v_result->>'run_id')::uuid;
  select array_agg(s.score_breakdown->'quality'->>'google_percentile'
                   order by s.restaurant_place_id)
    into v_pcts from recommendation_scores s where s.run_id = v_run;
  perform t_check('co-equal venues get one percentile, the midpoint of the range they share',
                  v_pcts = array['0.1000', '0.4000', '0.4000', '0.7000', '0.9000'],
                  v_pcts::text);
  perform t_check('and a tie does not change the pool total either',
                  (select sum((s.score_breakdown->'quality'->>'google_percentile')::numeric)
                     from recommendation_scores s where s.run_id = v_run) = 2.5);
  update restaurant_features set rating = 3.8 where place_id = 'qa0028_q2';

  -- A POOL OF ONE IS 0.5. q3 is the only venue either provider scored on its own side, so
  -- neither the scrape nor its absence decides anything: percent_rank() would hand it 0 and
  -- cume_dist() would hand it 1.
  update restaurant_features set rating = null, user_rating_count = null
   where place_id like 'qa0028_q%';
  update restaurant_features set rating = 4.4, user_rating_count = 500
   where place_id = 'qa0028_q3';
  update restaurant_features set tabelog_id = '13100419', tabelog_rating = 3.22,
                                 tabelog_review_count = 300
   where place_id = 'qa0028_q4';
  v_result := fn_recompute_feasibility(v_event);
  v_run := (v_result->>'run_id')::uuid;
  perform t_check('a one-venue Google pool lands on 0.5, and so does a one-venue Tabelog pool',
                  (select s.score_breakdown->'quality'->>'google_percentile' = '0.5000'
                     from recommendation_scores s
                    where s.run_id = v_run and s.restaurant_place_id = 'qa0028_q3')
                  and (select s.score_breakdown->'quality'->>'tabelog_percentile' = '0.5000'
                         from recommendation_scores s
                        where s.run_id = v_run and s.restaurant_place_id = 'qa0028_q4'));
  perform t_check('so both band to the same 0.6 — one provider each, neither extreme',
                  (select bool_and(s.quality_score = 0.6) from recommendation_scores s
                    where s.run_id = v_run
                      and s.restaurant_place_id in ('qa0028_q3', 'qa0028_q4')));
  perform t_check('and the four methods are exactly the four 0028 defines',
                  (select array_agg(s.score_breakdown->'quality'->>'method'
                                    order by s.restaurant_place_id)
                     from recommendation_scores s where s.run_id = v_run)
                  = array['atmosphere_tag_proxy', 'atmosphere_tag_proxy', 'google_only',
                          'tabelog_only', 'atmosphere_tag_proxy']);
  perform t_check('a Tabelog-only venue never borrows Google''s columns to report itself',
                  (select s.score_breakdown->'quality'->>'rating' is null
                            and s.score_breakdown->'quality'->>'user_rating_count' is null
                            and (s.score_breakdown->'quality'->>'tabelog_rating')::numeric = 3.22
                     from recommendation_scores s
                    where s.run_id = v_run and s.restaurant_place_id = 'qa0028_q4'));
  perform t_check('and a Google-only venue never borrows Tabelog''s',
                  (select s.score_breakdown->'quality'->>'tabelog_rating' is null
                            and s.score_breakdown->'quality'->>'tabelog_shrunk' is null
                            and (s.score_breakdown->'quality'->>'rating')::numeric = 4.4
                     from recommendation_scores s
                    where s.run_id = v_run and s.restaurant_place_id = 'qa0028_q3'));
  perform t_check('an unrated venue is out of both pools and keeps 0016''s tag proxy',
                  (select s.quality_score = 0
                            and s.score_breakdown->'quality'->>'google_percentile' is null
                            and s.score_breakdown->'quality'->>'blended_percentile' is null
                     from recommendation_scores s
                    where s.run_id = v_run and s.restaurant_place_id = 'qa0028_q1'));

  -- PRESENCE IS NEITHER A BONUS NOR A PENALTY. Five venues, all rated by Google:
  --   q1 4.1  q2 4.4  q3 4.4  q4 4.4  q5 4.6, each with 500 reviews
  -- so q3 shares a three-way tie in the middle at (1 + 3/2)/5 = 0.5 and bands to 0.6. Giving
  -- q1 and q5 Tabelog scores must not move q3 by a digit: a provider that said nothing about it
  -- contributes no term to its mean, so it is pushed neither toward 0 nor toward 0.5.
  update restaurant_features
     set rating = 4.4, user_rating_count = 500, tabelog_id = null, tabelog_rating = null,
         tabelog_review_count = null
   where place_id like 'qa0028_q%';
  update restaurant_features set rating = 4.1 where place_id = 'qa0028_q1';
  update restaurant_features set rating = 4.6 where place_id = 'qa0028_q5';
  v_result := fn_recompute_feasibility(v_event);
  select s.quality_score into v_before_score from recommendation_scores s
   where s.run_id = (v_result->>'run_id')::uuid and s.restaurant_place_id = 'qa0028_q3';
  perform t_check('the three-way middle of five bands to 0.6', v_before_score = 0.6,
                  v_before_score::text);
  update restaurant_features set tabelog_id = '13100419', tabelog_rating = 3.5,
                                 tabelog_review_count = 300
   where place_id in ('qa0028_q1', 'qa0028_q5');
  v_result := fn_recompute_feasibility(v_event);
  select s.quality_score into v_after_score from recommendation_scores s
   where s.run_id = (v_result->>'run_id')::uuid and s.restaurant_place_id = 'qa0028_q3';
  perform t_check('a venue with no Tabelog score keeps its Google-only score exactly',
                  v_before_score = v_after_score,
                  v_before_score::text || ' -> ' || v_after_score::text);
  perform t_check('and still reports google_only rather than being folded into the blend',
                  (select s.score_breakdown->'quality'->>'method' = 'google_only'
                     and s.score_breakdown->'quality'->>'tabelog_percentile' is null
                     from recommendation_scores s
                    where s.run_id = (v_result->>'run_id')::uuid
                      and s.restaurant_place_id = 'qa0028_q3'));

  -- The three new scoring helpers are implementation details of the guarded
  -- fn_recompute_feasibility RPC, exactly as 0016's are.
  perform t_check('no client role may call the blend or its helpers',
                  not has_function_privilege('authenticated',
                    'public.fn_quality_prior_rating(text)', 'EXECUTE')
                  and not has_function_privilege('anon',
                    'public.fn_provider_quality_shrunk(numeric, integer, numeric)', 'EXECUTE')
                  and not has_function_privilege('authenticated',
                    'public.fn_quality_signal_blended(numeric, integer, numeric, integer, '
                    || 'numeric, integer, numeric, integer, text[])', 'EXECUTE')
                  and has_function_privilege('service_role',
                    'public.fn_quality_signal_blended(numeric, integer, numeric, integer, '
                    || 'numeric, integer, numeric, integer, text[])', 'EXECUTE'));

  -- 0016's structural rule survives: the tag proxy's ceiling is 0.2 and the band's floor is
  -- above it, so a venue nobody rated can never outscore one with a real, if poor, score. A
  -- BARE percentile would have broken this — the worst of five sits at 0.1.
  perform t_check('missing rating data still cannot outscore present rating data',
                  fn_banded_score(1.0, 0.1) > 0.2
                  and (fn_quality_signal(null, null, array['a','b','c'])->>'score')::numeric
                        = 0.2);
end $$;

-- ---------------------------------------------------------------------------
-- 0021: the demo invite code is reachable, and the demo invariant is untouched by
-- everything above (every QA block adds its own events and venues to the same global pool —
-- ten events and twenty-three venues by this point).
-- ---------------------------------------------------------------------------
do $$
declare
  v_event_id uuid := '00000000-0000-0000-0000-000000000001';
  v_bob_pid uuid := '00000000-0000-0000-0000-0000000000b1';
  v_bob_room_id uuid;
  v_code text;
  v_visitor uuid := '77777777-7777-7777-7777-777777777777';
  v_joined uuid;
  v_places text[];
  v_baseline int;
begin
  perform t_as_admin();

  select invite_code into v_code from events where id = v_event_id;
  -- fn_generate_invite_code (0007) only ever emits lowercase characters, and both join
  -- screens lowercase and clamp to 6 what the participant types, so an uppercase seed value
  -- ('DEMO01') could never be matched: the documented demo fixture was unreachable.
  perform t_check('the seeded demo invite code is 6 lowercase characters',
                  v_code ~ '^[0-9a-z]{6}$' and v_code = lower(v_code), v_code);
  perform t_check('and it is exactly what the mock fixture and the docs tell people to type',
                  v_code = 'demo01', v_code);

  -- End-to-end: the code a join screen would send actually resolves. Rolled back through an
  -- aborted subtransaction, because this fixture must keep exactly five personas (plpgsql
  -- variables survive the rollback; the inserted participant does not).
  begin
    perform t_as_user(v_visitor);
    v_joined := fn_join_event(lower(left('DEMO01', 6)), 'QA visitor', 'station');
    raise exception 'rolling back the join probe';
  exception when others then
    null;
  end;
  perform t_as_admin();
  perform t_check('the seeded demo event can actually be joined with its code',
                  v_joined is not null, v_joined::text);
  perform t_check('and the probe left the five-persona fixture alone',
                  (select count(*) from participants where event_id = v_event_id) = 5);

  select id into v_bob_room_id from participant_constraints
   where event_id = v_event_id and participant_id = v_bob_pid
     and normalized_type = 'room';
  select count(*) into v_baseline
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event_id, r.place_id, v_bob_room_id,
                                  '{"room":"private"}'::jsonb);
  perform t_check('the demo fixture still has zero feasible venues at baseline',
                  v_baseline = 0, v_baseline::text);

  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event_id, r.place_id);
  perform t_check('and exactly 001, 002 and 004 after the relaxation — never 003',
                  v_places = array['demo_place_001','demo_place_002','demo_place_004'],
                  v_places::text);
end $$;

-- ---------------------------------------------------------------------------
-- 0024 (A): the app's real access pattern, under the roles PostgREST actually uses.
--
-- Everything above this point proves RLS, and thoroughly — but none of it could ever
-- have failed on a missing GRANT. `t_as_user` does `set role authenticated`, yet the
-- containers this suite runs in hand every new table full CRUD through `alter default
-- privileges`, so the privilege layer was always wide open underneath the policies.
-- On a hosted project it is not: migrations are applied as `postgres` while the
-- default privileges that grant CRUD belong to `supabase_admin`, so every table from
-- 0001-0016 arrived in production with `Dxtm` and no SELECT at all, and the app could
-- not read a single one of its own tables. 0024_table_privileges.sql is the fix; these
-- three blocks are the reason it cannot silently come undone.
--
-- A grant and a policy are two different gates. The blocks below assert the privilege
-- gate: the allow side runs the reads and writes the clients and the Edge Functions
-- actually issue, as the role they actually issue them as, and the deny side matches
-- on `permission denied for table …` rather than on any 42501 — an RLS refusal raises
-- 42501 too, so a looser assertion would pass for the wrong reason and prove nothing
-- about privileges.
--
-- Three mechanics decide how this is written:
--   * `set role` inside a DO block takes effect for the rest of the block and is
--     undone by `reset role` (t_as_admin) — but an aborting subtransaction rolls the
--     GUC stack back too, so a role is always assumed OUTSIDE an exception block,
--     never inside one.
--   * a failed statement aborts the whole block, so every probe expected to fail is
--     wrapped in `begin … exception when insufficient_privilege then … end`, and every
--     probe expected to succeed captures `sqlerrm` so a regression is reported as a
--     FAIL with its exact message instead of killing the run.
--   * `t_check` writes to `test_results`, which is itself a privileged INSERT. Results
--     are therefore collected into variables while impersonating and only recorded
--     after `t_as_admin()`, so these probes do not depend on the client roles being
--     able to append to the harness's own bookkeeping.
--
-- The fixture is private (its own event, its own participants) and adds no venue —
-- `recommendation_scores` points at a seeded place — so the global candidate pool the
-- blocks above assert on is left exactly as it was.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00240000-0000-0000-0000-000000000024';
  v_pid uuid := '00240000-0000-0000-0000-0000000000a1';
  v_other_pid uuid := '00240000-0000-0000-0000-0000000000b1';
  v_uid uuid := '00240000-0000-0000-0000-00000000aaaa';
  v_other_uid uuid := '00240000-0000-0000-0000-00000000bbbb';
  v_run uuid := '00240000-0000-0000-0000-0000000000f1';
  v_constraint uuid;
  -- Every table the two clients read directly (web/src/backend/supabase.ts and
  -- AIKanji/AIKanji/Services/*.swift), plus the four 0017 caches whose SELECT grant
  -- has to survive 0024's revoke-then-grant pass.
  v_reads text[] := array[
    'events', 'participants', 'participant_constraints', 'negotiations',
    'recommendation_runs', 'recommendation_scores', 'restaurants',
    'restaurant_features', 'event_restaurant_candidates', 'travel_matrix_cache',
    'meeting_zones', 'provider_incidents'];
  v_errors text[] := '{}';
  v_tbl text;
  -- Seeded with a value no assertion accepts, so a probe that could not run at all
  -- reports a FAIL carrying the reason instead of a null comparison.
  v_events int := -1; v_parts int := -1; v_own int := -1; v_negs int := -1;
  v_runs int := -1; v_scores int := -1; v_after_insert int := -1;
  v_updated int := -1; v_feed int := -1;
  v_rls_err text; v_insert_err text; v_update_err text; v_feed_err text;
begin
  perform t_as_admin();

  insert into events (id, name, objective, status)
  values (v_event, 'QA 0024 privileges', 'balanced', 'collecting');
  insert into participants (id, event_id, auth_user_id, display_name, role,
                            travel_reference)
  values (v_pid, v_event, v_uid, 'Grantee', 'organizer', 'office'),
         (v_other_pid, v_event, v_other_uid, 'Somebody else', 'participant', 'station');
  update events set organizer_participant_id = v_pid where id = v_event;

  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_pid, 'MUST', 'budget under 5000 yen',
          'budget', '{"max_yen":5000}', 'PUBLIC')
  returning id into v_constraint;
  insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                       normalized_type, normalized_value, visibility)
  values (v_event, v_other_pid, 'MUST', 'not mine to read',
          'other', '{}', 'PRIVATE');

  insert into recommendation_runs (id, event_id, feasible_count, input_snapshot)
  values (v_run, v_event, 1, '{}');
  insert into recommendation_scores (run_id, restaurant_place_id, fairness_score,
                                     satisfaction_score, quality_score, label)
  values (v_run, 'demo_place_001', 0.5, 0.5, 0.5, 'fairest');
  insert into negotiations (event_id, constraint_id, participant_id, proposed_value,
                            unlocked_count)
  values (v_event, v_constraint, v_pid, '{"max_yen":6000}', 1);

  -- --- as the signed-in client ------------------------------------------------
  perform t_as_user(v_uid);

  -- Can the ROLE touch the table at all? One probe per table, so a regression names
  -- the table it broke instead of failing the run at whichever read came first.
  foreach v_tbl in array v_reads loop
    begin
      execute format('select count(*) from public.%I', v_tbl);
      v_errors := v_errors || ''::text;
    exception when others then
      v_errors := v_errors || sqlerrm;
    end;
  end loop;

  -- And the rows it may then see, which is RLS's half of the same question.
  -- `events` is the interesting one: its policy subqueries `participants`, and a
  -- policy predicate is evaluated with the caller's privileges — without SELECT on
  -- `participants` this read fails with "permission denied for table participants"
  -- before RLS is reached at all.
  begin
    select count(*) into v_events from events where id = v_event;
    select count(*) into v_parts from participants where event_id = v_event;
    select count(*) into v_own from participant_constraints where event_id = v_event;
    select count(*) into v_negs from negotiations where participant_id = v_pid;
    select count(*) into v_runs from recommendation_runs where event_id = v_event;
    select count(*) into v_scores from recommendation_scores where run_id = v_run;
  exception when others then
    v_rls_err := sqlerrm;
  end;

  -- The one table a client writes directly: `insertConstraint` in supabase.ts and
  -- ConstraintService.swift's `.insert(ConstraintInsert(...))`.
  begin
    insert into participant_constraints (event_id, participant_id, kind, raw_text,
                                         normalized_type, normalized_value, visibility)
    values (v_event, v_pid, 'WANT', 'italian would be nice',
            'cuisine', '{"include":["italian"]}', 'PUBLIC');
    select count(*) into v_after_insert
      from participant_constraints where participant_id = v_pid;
  exception when others then
    v_insert_err := sqlerrm;
  end;

  -- UPDATE is the privilege behind 0007's "participant updates own raw constraints"
  -- policy, re-stated by 0018 with the post-close closure check. Without it the
  -- policy could never fire.
  begin
    update participant_constraints set raw_text = raw_text || ' (edited)'
     where id = v_constraint;
    get diagnostics v_updated = row_count;
  exception when others then
    v_update_err := sqlerrm;
  end;

  -- The definer RPC path, which needs no table privilege of its own — asserted here
  -- so a failure of the grants above cannot be mistaken for a failure of the RPCs.
  begin
    select count(*) into v_feed from fn_get_sanitized_feed(v_event);
  exception when others then
    v_feed_err := sqlerrm;
  end;

  perform t_as_admin();

  for v_i in 1 .. array_length(v_reads, 1) loop
    perform t_check(format('authenticated may read public.%s', v_reads[v_i]),
                    v_errors[v_i] = '', v_errors[v_i]);
  end loop;

  perform t_check('and the events read returns the caller''s own event',
                  v_events = 1, coalesce(v_rls_err, v_events::text));
  perform t_check('participants read returns the whole membership list',
                  v_parts = 2, coalesce(v_rls_err, v_parts::text));
  perform t_check('while RLS still hides the other participant''s raw constraint',
                  v_own = 1, coalesce(v_rls_err, v_own::text));
  perform t_check('the caller''s open negotiation is readable',
                  v_negs = 1, coalesce(v_rls_err, v_negs::text));
  perform t_check('the latest run is readable', v_runs = 1,
                  coalesce(v_rls_err, v_runs::text));
  perform t_check('and its scores are readable', v_scores = 1,
                  coalesce(v_rls_err, v_scores::text));
  perform t_check('authenticated may insert its own constraint',
                  v_insert_err is null, v_insert_err);
  perform t_check('and the row is really there', v_after_insert = 2,
                  coalesce(v_insert_err, v_after_insert::text));
  perform t_check('authenticated may update its own constraint',
                  v_update_err is null and v_updated = 1,
                  coalesce(v_update_err, v_updated::text));
  perform t_check('and the sanitized feed RPC still answers the same caller',
                  v_feed_err is null and v_feed = 2,
                  coalesce(v_feed_err, v_feed::text));
end $$;

-- ---------------------------------------------------------------------------
-- 0024 (B): what must stay out, stays out — and stays out by privilege.
--
-- Each probe below is refused with `permission denied for table …`, i.e. by the ACL,
-- before RLS is consulted. The distinction is the whole point: RLS also raises 42501,
-- so asserting only "it failed" would let a table that quietly regained INSERT pass as
-- long as some policy happened to refuse the row.
--
-- The statements are inert even if a regression let one through: the writes carry
-- `where false`, and the TRUNCATE probe targets `events`, which `participants`
-- references — so the FK web would refuse it (with a different message, failing the
-- check) rather than emptying the fixture. TRUNCATE is probed because it ignores RLS
-- completely: the inherited `Dxtm` handed it to both client roles, where no policy
-- could ever have contained it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00240000-0000-0000-0000-000000000024';
  v_pid uuid := '00240000-0000-0000-0000-0000000000a1';
  v_uid uuid := '00240000-0000-0000-0000-00000000aaaa';
  v_labels text[];
  v_stmts text[];
  v_msgs text[] := '{}';
  -- Every app table, for the anon sweep: a Supabase anonymous sign-in issues an
  -- `authenticated` JWT, `ensureSession()` guarantees a session before any query, and
  -- restaurant-search's caller-side client forwards the caller's own token — so
  -- nothing in this app ever speaks as `anon`, and `anon` is granted nothing.
  v_all text[] := array[
    'events', 'participants', 'participant_constraints', 'negotiations',
    'recommendation_runs', 'recommendation_scores', 'restaurants',
    'restaurant_features', 'event_restaurant_candidates', 'travel_matrix_cache',
    'meeting_zones', 'provider_incidents', 'restaurant_source_records'];
  v_anon_errors text[] := '{}';
  v_stmt text;
  v_tbl text;
  v_leaks text;
begin
  perform t_as_admin();

  v_labels := array[
    'a client cannot read the raw provider payloads (0017/0023)',
    'a client cannot insert a participant — fn_join_event does that (0020)',
    'a client cannot update a participant — fn_set_travel_reference does (0020)',
    'a client cannot delete a participant (0020)',
    'a client cannot delete a constraint: there is no client delete path at all',
    'a client cannot create an event outside fn_create_event',
    'a client cannot rewrite an event: status, choice and close are all RPCs',
    'a client cannot forge a negotiation for itself',
    'a client cannot answer one by hand instead of fn_respond_negotiation',
    'a client cannot invent a recommendation run',
    'a client cannot rescore a candidate',
    'a client cannot rewrite provider venue data',
    'a client cannot rewrite the provider attributions it is required to display',
    'and TRUNCATE, which no policy could have contained, is gone as well'];
  v_stmts := array[
    'select 1 from public.restaurant_source_records',
    format('insert into public.participants (event_id, auth_user_id, display_name) '
           'select %L, %L, ''forged'' where false', v_event, v_uid),
    'update public.participants set display_name = display_name where false',
    'delete from public.participants where false',
    'delete from public.participant_constraints where false',
    'insert into public.events (name) select ''forged'' where false',
    'update public.events set status = status where false',
    format('insert into public.negotiations (event_id, constraint_id, participant_id, '
           'proposed_value) select %L, id, %L, ''{}''::jsonb '
           'from public.participant_constraints where false', v_event, v_pid),
    'update public.negotiations set status = ''ACCEPTED'' where false',
    format('insert into public.recommendation_runs (event_id, feasible_count, '
           'input_snapshot) select %L, 99, ''{}''::jsonb where false', v_event),
    'update public.recommendation_scores set quality_score = 1 where false',
    'update public.restaurant_features set price_yen_estimate = 1 where false',
    'update public.restaurant_features set provider_attributions = ''[]''::jsonb '
      'where false',
    'truncate public.events'];

  perform t_as_user(v_uid);
  foreach v_stmt in array v_stmts loop
    begin
      execute v_stmt;
      v_msgs := v_msgs || null::text;
    exception when others then
      v_msgs := v_msgs || sqlerrm;
    end;
  end loop;

  -- `anon` next. Still no t_check while impersonating: appending to test_results is a
  -- privileged write, and anon must not have one.
  execute 'set role anon';
  foreach v_tbl in array v_all loop
    begin
      execute format('select 1 from public.%I limit 1', v_tbl);
      v_anon_errors := v_anon_errors || null::text;
    exception when others then
      v_anon_errors := v_anon_errors || sqlerrm;
    end;
  end loop;
  perform t_as_admin();

  for v_i in 1 .. array_length(v_stmts, 1) loop
    perform t_check(v_labels[v_i],
                    coalesce(v_msgs[v_i], '') like 'permission denied for table%',
                    coalesce(v_msgs[v_i], 'NOT REFUSED: ' || v_stmts[v_i]));
  end loop;

  perform t_check('anon is refused on every app table, without exception',
                  (select bool_and(coalesce(v_anon_errors[i], '')
                                     like 'permission denied for table%')
                     from generate_subscripts(v_all, 1) i),
                  (select string_agg(v_all[i] || ' -> ' ||
                                     coalesce(v_anon_errors[i], 'NOT REFUSED'), ', ')
                     from generate_subscripts(v_all, 1) i
                    where coalesce(v_anon_errors[i], '')
                            not like 'permission denied for table%'));

  -- Belt and braces, straight from the catalog: not one ACL entry for `anon` — nor for
  -- PUBLIC, which would reach anon just as well — on any RLS-protected table in
  -- `public`. A privilege granted but not covered by a probe above still shows up here.
  select string_agg(c.relname || ':' || a.grantee::regrole::text || ':' ||
                    a.privilege_type, ', ' order by c.relname, a.privilege_type)
    into v_leaks
    from pg_class c
    cross join aclexplode(c.relacl) a
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'r'
     and c.relrowsecurity
     and (a.grantee = 'anon'::regrole or a.grantee = 0);
  perform t_check('and holds no privilege on them in the catalog either',
                  v_leaks is null, v_leaks);
end $$;

-- ---------------------------------------------------------------------------
-- 0024 (C): service_role, the privilege inventory, and the sequences.
--
-- service_role is the trusted server-side identity — the two Edge Functions' clients
-- and scripts/bootstrap-hosted-fixture.mjs — and it bypasses RLS, so its table
-- privileges are the only boundary it has. It was as broken as the client roles: the
-- same default-ACL gap left it with `Dxtm`, so `select count(*) from participants`
-- raised 42501 and restaurant-search could not read the origins it exists to route.
--
-- The last checks are what make this section a guard rather than a snapshot: an
-- inventory of exactly which privileges the client roles hold on the core tables (so a
-- later blanket `grant all` fails here, loudly), and the sequence invariant — an INSERT
-- on a serial column also needs `usage` on the sequence behind it, a separate ACL the
-- same default-privilege gap would swallow. There is no sequence in `public` today, so
-- 0024 grants none; this is what fails the day somebody adds one and grants only the
-- table.
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid := '00240000-0000-0000-0000-000000000024';
  v_pid uuid := '00240000-0000-0000-0000-0000000000a1';
  -- The server side's read set: restaurant-search reads participants and the WANT
  -- constraints, llm-assist reads the run, its scores and the venue's features, and the
  -- fixture script reads whatever it PATCHes because it sends return=representation.
  v_reads text[] := array[
    'events', 'participants', 'participant_constraints', 'recommendation_runs',
    'recommendation_scores', 'restaurants', 'restaurant_features',
    'restaurant_source_records', 'event_restaurant_candidates',
    'travel_matrix_cache', 'meeting_zones', 'provider_incidents'];
  v_read_errors text[] := '{}';
  v_write_errors text[] := '{}';
  v_labels text[];
  v_stmts text[];
  v_stmt text;
  v_tbl text;
  v_expected text[];
  v_actual text[];
  v_sequences text;
begin
  perform t_as_admin();

  v_labels := array[
    'service_role may rewire a seeded participant to a real Auth uid',
    'service_role may put a room MUST back for the next demo run',
    'service_role may reset the event lifecycle and the decision',
    'service_role may clear the negotiations a demo run left behind',
    'service_role may clear the recommendation runs (scores cascade)'];
  v_stmts := array[
    format('update public.participants set auth_user_id = auth_user_id '
           'where id = %L', v_pid),
    format('update public.participant_constraints set normalized_value = '
           '''{"max_yen":5000}''::jsonb where event_id = %L '
           'and normalized_type = ''budget''', v_event),
    format('update public.events set status = ''collecting'', chosen_place_id = null, '
           'chosen_at = null, preferences_closed_at = null where id = %L', v_event),
    format('delete from public.negotiations where event_id = %L', v_event),
    format('delete from public.recommendation_runs where event_id = %L', v_event)];

  execute 'set role service_role';
  foreach v_tbl in array v_reads loop
    begin
      execute format('select count(*) from public.%I', v_tbl);
      v_read_errors := v_read_errors || ''::text;
    exception when others then
      v_read_errors := v_read_errors || sqlerrm;
    end;
  end loop;
  foreach v_stmt in array v_stmts loop
    begin
      execute v_stmt;
      v_write_errors := v_write_errors || ''::text;
    exception when others then
      v_write_errors := v_write_errors || sqlerrm;
    end;
  end loop;
  perform t_as_admin();

  perform t_check('service_role may read every table its server-side callers read',
                  (select bool_and(e = '') from unnest(v_read_errors) e),
                  (select string_agg(v_reads[i] || ' -> ' || v_read_errors[i], ', ')
                     from generate_subscripts(v_reads, 1) i
                    where v_read_errors[i] <> ''));
  for v_i in 1 .. array_length(v_stmts, 1) loop
    perform t_check(v_labels[v_i], v_write_errors[v_i] = '', v_write_errors[v_i]);
  end loop;

  -- The inventory, for the two roles a leaked publishable key can reach.
  -- `has_table_privilege` rather than information_schema.table_privileges so the same
  -- expectation holds on PG16 and PG17 (MAINTAIN exists only on 17, and 0024's
  -- `revoke all` takes it away there too).
  v_expected := array[
    'events|anon|',
    'events|authenticated|SELECT',
    'participants|anon|',
    'participants|authenticated|SELECT',
    'participant_constraints|anon|',
    'participant_constraints|authenticated|SELECT,INSERT,UPDATE',
    'negotiations|anon|',
    'negotiations|authenticated|SELECT',
    'recommendation_runs|anon|',
    'recommendation_runs|authenticated|SELECT',
    'recommendation_scores|anon|',
    'recommendation_scores|authenticated|SELECT',
    'restaurants|anon|',
    'restaurants|authenticated|SELECT',
    'restaurant_features|anon|',
    'restaurant_features|authenticated|SELECT'];
  select array_agg(t || '|' || r || '|' ||
                   coalesce((select string_agg(p, ',' order by ord)
                               from unnest(array['SELECT','INSERT','UPDATE','DELETE',
                                                 'TRUNCATE','REFERENCES','TRIGGER'])
                                    with ordinality as priv(p, ord)
                              where has_table_privilege(r, 'public.' || t, p)), '')
                   order by tord, rord)
    into v_actual
    from unnest(array['events','participants','participant_constraints','negotiations',
                      'recommendation_runs','recommendation_scores','restaurants',
                      'restaurant_features']) with ordinality as tab(t, tord)
    cross join unnest(array['anon','authenticated']) with ordinality as rl(r, rord);
  perform t_check('the client roles hold exactly the privileges 0024 states, no more',
                  v_actual = v_expected,
                  (select string_agg(a, ', ') from unnest(v_actual) a
                    where a <> all (v_expected)));

  -- service_role is asserted on the allow side only: it is the secret key, so its
  -- boundary is key custody, not the ACL. What must hold is that 0024's revokes hit
  -- the client roles and nothing else — 0017's provider-cache CRUD is still there.
  perform t_check('and 0017''s service_role CRUD on the provider cache is intact',
                  (select bool_and(has_table_privilege('service_role',
                                                       'public.' || t, p))
                     from unnest(array['event_restaurant_candidates',
                                       'travel_matrix_cache', 'meeting_zones',
                                       'restaurant_source_records',
                                       'provider_incidents']) t
                     cross join unnest(array['SELECT','INSERT','UPDATE','DELETE']) p));

  -- No sequence may be reachable by an INSERT the role is allowed to make and still be
  -- unusable. Restricted to the RLS-protected app tables, so the harness's own
  -- `test_results` serial is not read as part of the schema's contract.
  select string_agg(s.relname || ' (behind ' || t.relname || ')', ', ')
    into v_sequences
    from pg_class s
    join pg_depend d
      on d.classid = 'pg_class'::regclass and d.objid = s.oid
     and d.refclassid = 'pg_class'::regclass and d.deptype in ('a', 'i')
    join pg_class t on t.oid = d.refobjid
   where s.relkind = 'S'
     and s.relnamespace = 'public'::regnamespace
     and t.relrowsecurity
     and ((has_table_privilege('authenticated', t.oid, 'INSERT')
           and not has_sequence_privilege('authenticated', s.oid, 'USAGE'))
       or (has_table_privilege('service_role', t.oid, 'INSERT')
           and not has_sequence_privilege('service_role', s.oid, 'USAGE')));
  perform t_check('every sequence behind a table a role may INSERT into is usable',
                  v_sequences is null, v_sequences);
end $$;

\set QUIET off
\pset border 2
select seq, case when passed then 'PASS' else 'FAIL' end as result, name, detail
from test_results order by seq;

select count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
from test_results;

-- Fail the run (non-zero psql exit via ON_ERROR_STOP) if anything failed.
do $$
declare v_failed int;
begin
  select count(*) into v_failed from test_results where not passed;
  if v_failed > 0 then
    raise exception '% test(s) failed', v_failed;
  end if;
end $$;
