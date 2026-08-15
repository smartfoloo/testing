-- Deterministic demo fixture: exactly 0 feasible restaurants initially, exactly 3
-- after Bob's room MUST relaxes to semi_private. Do not alter the values.

-- The invite code is lowercase because that is the only thing that can be typed in:
-- fn_generate_invite_code (0007) emits 6 characters from '23456789abcdefghjkmnpqrstuvwxyz'
-- — all lowercase — and both join screens lowercase and clamp to 6 what the user enters
-- (JoinEventView on iOS, JoinEvent.tsx on the web). The former 'DEMO01' could therefore
-- never be matched, which made the documented demo fixture unreachable on a real project.
-- Kept as 'demo01' to stay identical to the web mock fixture (web/src/backend/mock.ts) and
-- to the code the mock-mode welcome screen and the browser suites tell people to type.
insert into events (id, name, invite_code, objective, status)
values ('00000000-0000-0000-0000-000000000001', 'Team 飲み会', 'demo01', 'balanced', 'collecting');

insert into participants (id, event_id, auth_user_id, display_name, role, travel_reference) values
('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000001',gen_random_uuid(),'Alice','organizer','office'),
('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-000000000001',gen_random_uuid(),'Bob','participant','office'),
('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-000000000001',gen_random_uuid(),'Charlie','participant','station'),
('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-000000000001',gen_random_uuid(),'David','participant','home'),
('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-000000000001',gen_random_uuid(),'Emma','participant','office');

insert into participant_constraints (event_id, participant_id, kind, raw_text, normalized_type, normalized_value, visibility) values
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1','MUST','budget under 4000 yen','budget','{"max_yen":4000}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1','WANT','yakitori','cuisine','{"include":["yakitori"],"exclude":[]}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000b1','MUST','private room','room','{"room":"private"}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000b1','WANT','good sake selection','other','{"note":"good sake"}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000c1','MUST','vegetarian options','dietary','{"tags":["vegetarian"]}','ANONYMOUS'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000c1','WANT','quiet atmosphere','atmosphere','{"tags":["quiet"]}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d1','MUST','within 35 min travel','travel_time','{"max_minutes":35}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d1','WANT','casual','atmosphere','{"tags":["casual"]}','PUBLIC'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000e1','MUST','shellfish allergy','allergy','{"allergens":["shellfish"]}','ANONYMOUS'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000e1','WANT','traditional japanese atmosphere','atmosphere','{"tags":["traditional_japanese"]}','PUBLIC');

insert into restaurants (place_id) values
('demo_place_001'), ('demo_place_002'), ('demo_place_003'), ('demo_place_004');

-- `accessibility_tags` (0016) and `smoking_policy` (0021) are deliberately left at their
-- defaults (empty / NULL = no data). Both MUST types are enforced fail-closed since 0021, so
-- claiming step-free access or a non-smoking floor here would be inventing venue facts; the
-- five personas state neither requirement, so the 0-then-3 invariant is untouched either way.
insert into restaurant_features
  (place_id, price_yen_estimate, room_type, dietary_tags, allergy_safe_tags,
   atmosphere_tags, travel_minutes_by_participant) values
('demo_place_001', 3800, 'semi_private', array['vegetarian'], array['shellfish_free'],
   array['quiet','traditional_japanese'],
   jsonb_build_object('00000000-0000-0000-0000-0000000000d1', 20)),
('demo_place_002', 3500, 'semi_private', array['vegetarian'], array['shellfish_free'],
   array['casual'],
   jsonb_build_object('00000000-0000-0000-0000-0000000000d1', 30)),
('demo_place_003', 4200, 'open', array[]::text[], array['shellfish_free'],
   array['quiet'],
   jsonb_build_object('00000000-0000-0000-0000-0000000000d1', 15)),
('demo_place_004', 3900, 'semi_private', array['vegetarian'], array['shellfish_free'],
   array['quiet'],
   jsonb_build_object('00000000-0000-0000-0000-0000000000d1', 25));

-- --- Provider cache for the demo event (0017) --------------------------------
--
-- `demo_place_001..004` are synthetic: no Google Places text search or Hot Pepper
-- query can ever return them, so live discovery for this event would replace a
-- deterministic fixture with whatever Tokyo happens to hold today. Seeding the
-- event-scoped provider cache makes 「条件に合うお店を探す」 a guaranteed cache hit
-- on a hosted project: restaurant-search finds fresh candidates for unshifted
-- meeting zones, calls no provider, and therefore needs no travel origin at all
-- (an origin is only required when discovery actually has to run).
--
-- `participants.travel_reference_place_id` is deliberately left NULL for all five
-- personas. A made-up id (the web mock's `mock_place_*`) would send a real Places
-- `places.get` per persona, fail, log fake provider incidents and still resolve
-- zero origins; a real Tokyo place id would resolve origins, produce meeting zones
-- that match no zone this event ever searched, and force exactly the live
-- discovery this fixture must not do — pulling real venues into the pool the
-- feasibility engine iterates and destroying the 0-then-3 invariant. The five
-- personas are reported honestly in the function's `unresolved_participants`
-- instead: the fixture has no geocoded reference points, and says so.
--
-- Both timestamps are stamped now() so the rows are fresh against the function's
-- 6h discovery TTL and 24h travel TTL. Both statements are idempotent upserts, so
-- re-applying this file before a demo simply re-stamps them.

insert into event_restaurant_candidates (event_id, place_id, discovered_at)
select '00000000-0000-0000-0000-000000000001', place_id, now()
from (values ('demo_place_001'), ('demo_place_002'), ('demo_place_003'),
             ('demo_place_004')) as v(place_id)
on conflict (event_id, place_id) do update set discovered_at = now();

-- The only commutes this fixture claims to know are David's, and they are exactly
-- the four values `restaurant_features.travel_minutes_by_participant` already
-- encodes (20/30/15/25, all inside his 35-minute MUST). travel_matrix_cache is the
-- authoritative per-event copy of those same legs, so fn_travel_minutes now reads
-- them from the cache instead of the legacy JSONB fallback and gets the same
-- numbers. Nobody else gets a leg: an invented commute would fake travel fairness
-- for four participants who never told us where they are.
insert into travel_matrix_cache
  (event_id, participant_id, place_id, minutes, fetched_at) values
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d1','demo_place_001',20,now()),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d1','demo_place_002',30,now()),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d1','demo_place_003',15,now()),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d1','demo_place_004',25,now())
on conflict (event_id, participant_id, place_id) do update
  set minutes = excluded.minutes, fetched_at = now();
