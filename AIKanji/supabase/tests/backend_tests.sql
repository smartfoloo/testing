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
