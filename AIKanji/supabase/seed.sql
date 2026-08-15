-- Deterministic demo fixture: exactly 0 feasible restaurants initially, exactly 3
-- after Bob's room MUST relaxes to semi_private. Do not alter the values.

insert into events (id, name, invite_code, objective, status)
values ('00000000-0000-0000-0000-000000000001', 'Team 飲み会', 'DEMO01', 'balanced', 'collecting');

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
