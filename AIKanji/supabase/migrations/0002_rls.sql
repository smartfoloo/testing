alter table events enable row level security;
alter table participants enable row level security;
alter table participant_constraints enable row level security;
alter table negotiations enable row level security;
alter table restaurants enable row level security;
alter table restaurant_features enable row level security;
alter table recommendation_runs enable row level security;
alter table recommendation_scores enable row level security;

create policy "event visible to its participants"
  on events for select
  using (id in (select event_id from participants where auth_user_id = auth.uid()));

create policy "participant reads own event membership list"
  on participants for select
  using (event_id in (select event_id from participants where auth_user_id = auth.uid()));

create policy "participant reads own raw constraints"
  on participant_constraints for select
  using (participant_id in (select id from participants where auth_user_id = auth.uid()));

create policy "participant writes own raw constraints"
  on participant_constraints for insert
  with check (participant_id in (select id from participants where auth_user_id = auth.uid()));

create policy "participant updates own raw constraints"
  on participant_constraints for update
  using (participant_id in (select id from participants where auth_user_id = auth.uid()));

create policy "participant reads own negotiations"
  on negotiations for select
  using (participant_id in (select id from participants where auth_user_id = auth.uid()));

create policy "restaurants readable by any authenticated user"
  on restaurants for select to authenticated using (true);

create policy "restaurant_features readable by any authenticated user"
  on restaurant_features for select to authenticated using (true);

create policy "recommendation_runs readable by event participants"
  on recommendation_runs for select
  using (event_id in (select event_id from participants where auth_user_id = auth.uid()));

create policy "recommendation_scores readable by event participants"
  on recommendation_scores for select
  using (run_id in (select id from recommendation_runs where event_id in
          (select event_id from participants where auth_user_id = auth.uid())));
