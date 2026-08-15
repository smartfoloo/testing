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

  select array_agg(r.place_id order by r.place_id) into v_places
    from restaurants r
    join restaurant_features rf on rf.place_id = r.place_id
   where fn_candidate_is_feasible(v_event_id, r.place_id);
  perform t_check('the feasible three are 001, 002 and 004 — never 003',
                  v_places = array['demo_place_001','demo_place_002',
                                   'demo_place_004'],
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
