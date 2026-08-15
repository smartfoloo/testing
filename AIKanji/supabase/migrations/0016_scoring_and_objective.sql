-- 0016_scoring_and_objective.sql
-- Scoring rewrite. Feasibility is untouched as a decision procedure: fn_candidate_is_feasible
-- still gates every candidate before anything below runs, so nothing here can admit a venue
-- that breaks a MUST, and the five-persona seed keeps producing 0 feasible venues at baseline
-- and exactly demo_place_001/002/004 after Bob's room MUST relaxes private -> semi_private.
--
-- What was wrong:
--   1. `events.objective` was stored, shown, and then ignored. The PRD requires it to adjust
--      ranking (never MUSTs), so an objective now selects a documented weight set over the
--      scoring dimensions and those weights produce the ordering score.
--   2. `quality_score` was `least(count(atmosphere_tags),3)/3.0` — tag richness, not quality.
--      It is now a review-volume-adjusted rating (Bayesian shrinkage toward a prior), with the
--      tag proxy kept only as a labelled fallback for venues the provider gave no rating for.
--   3. Burden was travel-only. Cost burden and accessibility burden are now first-class stored
--      dimensions, because PRD §9 protects against disproportionate travel, cost OR
--      accessibility burden.
--   4. One opaque score per card. Every component, the weights applied to it and the
--      provenance of the quality signal are stored in `score_breakdown` for the UI.
--   5. Two bugs: (a) missing travel data scored a PERFECT 1.0000 fairness — a venue with one
--      known travel time beat a venue with a measured 5/30/75-minute spread (0.0141); (b)
--      labels were assigned greedily to the best still-unlabelled row, so a 75-minute commute
--      got `best_access` because the better venue had already taken `fairest`.
--
-- Travel times are read through fn_travel_minutes only. It prefers the event-scoped
-- travel_matrix_cache (created by 0017, which runs AFTER this file) and falls back to the
-- legacy global restaurant_features.travel_minutes_by_participant JSONB, so this migration
-- applies cleanly on its own and the demo seed (JSONB only) keeps working.

-- --- Columns ----------------------------------------------------------------

-- Populated by the provider pipeline (0017 fn_record_provider_candidates). Assume NULL: most
-- rows will have no rating until a search has run, and the seed fixture never has one.
alter table public.restaurant_features add column if not exists rating numeric;
alter table public.restaurant_features add column if not exists user_rating_count int;
-- No accessibility column existed at all. Default '{}' means "no data", which the burden
-- calculation treats as unknown/worst — never as "step-free access confirmed".
alter table public.restaurant_features add column if not exists accessibility_tags text[] default '{}';

-- Guard rails on provider writes: a rating outside Google's 0–5 scale or a negative review
-- count would silently poison every quality score. drop-then-add keeps this re-runnable.
alter table public.restaurant_features drop constraint if exists restaurant_features_rating_range;
alter table public.restaurant_features add constraint restaurant_features_rating_range
  check (rating is null or (rating >= 0 and rating <= 5));
alter table public.restaurant_features drop constraint if exists restaurant_features_rating_count_sane;
alter table public.restaurant_features add constraint restaurant_features_rating_count_sane
  check (user_rating_count is null or user_rating_count >= 0);

-- Per-dimension results the cards render instead of one universal AI score. The burden
-- columns are 0..1 where HIGHER IS WORSE; every component inside score_breakdown is 0..1
-- where higher is better. score_breakdown.scale says so on the wire as well.
alter table public.recommendation_scores add column if not exists cost_burden_score numeric;
alter table public.recommendation_scores add column if not exists accessibility_burden_score numeric;
alter table public.recommendation_scores add column if not exists objective_score numeric;
alter table public.recommendation_scores add column if not exists score_breakdown jsonb;

-- --- Travel lookup ----------------------------------------------------------

-- The single place either implementation reads a travel time. NULL means "we do not know",
-- never "zero minutes": travel_minutes_by_participant is one global object per place_id, so
-- one event's search used to overwrite another's and an event went 3 feasible -> 0 silently.
-- travel_matrix_cache arrives in 0017, so the lookup is dynamic and simply skipped until then.
create or replace function public.fn_travel_minutes(
  p_event_id uuid, p_place_id text, p_participant_id uuid
) returns int language plpgsql stable security definer set search_path = '' as $$
declare v_minutes int;
begin
  if pg_catalog.to_regclass('public.travel_matrix_cache') is not null then
    execute 'select c.minutes from public.travel_matrix_cache c
             where c.event_id = $1 and c.place_id = $2 and c.participant_id = $3'
      into v_minutes using p_event_id, p_place_id, p_participant_id;
    if v_minutes is not null then return v_minutes; end if;
  end if;
  select (rf.travel_minutes_by_participant ->> p_participant_id::text)::int into v_minutes
  from public.restaurant_features rf where rf.place_id = p_place_id;
  return v_minutes;
end; $$;

-- --- Scoring primitives -----------------------------------------------------

-- Objective weight table. Each row sums to 1.0.
--
--   objective  | travel_fairness | travel_access | satisfaction | quality | cost_fit | accessibility_fit
--   -----------+-----------------+---------------+--------------+---------+----------+------------------
--   balanced   |            0.20 |          0.15 |         0.25 |    0.20 |     0.10 |              0.10
--   access     |            0.25 |          0.35 |         0.10 |    0.05 |     0.10 |              0.15
--   cost       |            0.10 |          0.10 |         0.15 |    0.10 |     0.45 |              0.10
--   experience |            0.10 |          0.10 |         0.25 |    0.35 |     0.10 |              0.10
--   custom     | = balanced
--
-- WHY these numbers:
--   * the 幹事's objective may only re-emphasize. Feasibility is decided before scoring, so
--     no weight can resurrect a venue that breaks somebody's MUST;
--   * every objective keeps a floor of 0.10 under travel_fairness and accessibility_fit, so
--     "cheap" or "impressive" can never be bought by dumping the burden on one participant;
--   * `access` splits emphasis between proximity and equity and lifts accessibility_fit —
--     step-free access is access too;
--   * `custom` has no bespoke weights yet (nothing in the UI can express them), so it
--     resolves to balanced rather than inventing a fifth profile.
create or replace function public.fn_objective_weights(p_objective text)
returns jsonb language sql immutable security definer set search_path = '' as $$
  select case coalesce(p_objective, 'balanced')
    when 'access' then '{"travel_fairness":0.25,"travel_access":0.35,"satisfaction":0.10,
                         "quality":0.05,"cost_fit":0.10,"accessibility_fit":0.15}'::jsonb
    when 'cost' then '{"travel_fairness":0.10,"travel_access":0.10,"satisfaction":0.15,
                       "quality":0.10,"cost_fit":0.45,"accessibility_fit":0.10}'::jsonb
    when 'experience' then '{"travel_fairness":0.10,"travel_access":0.10,"satisfaction":0.25,
                             "quality":0.35,"cost_fit":0.10,"accessibility_fit":0.10}'::jsonb
    else '{"travel_fairness":0.20,"travel_access":0.15,"satisfaction":0.25,
           "quality":0.20,"cost_fit":0.10,"accessibility_fit":0.10}'::jsonb
  end;
$$;

-- Scores derived from COMPLETE data land in [0.2, 1.0]; anything with a gap is squeezed into
-- [0, 0.2). This is how "missing data must never win" is enforced structurally instead of
-- hoping the arithmetic works out: the old fairness formula gave 1.0000 to a venue whose
-- travel map held a single entry. Within each band the score still grades, so a partially
-- measured venue can be compared with another partially measured venue.
create or replace function public.fn_banded_score(p_coverage numeric, p_credit numeric)
returns numeric language sql immutable security definer set search_path = '' as $$
  select case when coalesce(p_coverage, 0) >= 1
    then round(0.2 + 0.8 * greatest(0, least(1, coalesce(p_credit, 0))), 4)
    else round(0.2 * greatest(0, least(1, coalesce(p_coverage, 0)))
                   * greatest(0, least(1, coalesce(p_credit, 0))), 4) end;
$$;

-- Travel equity and proximity for one venue in one event. Coverage is counted over the
-- event's own participants, never over the keys of the shared JSONB, so another event's
-- stale leg cannot pass as data about this group.
create or replace function public.fn_travel_profile(p_event_id uuid, p_place_id text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_total int; v_known int; v_spread int; v_avg numeric; v_coverage numeric;
begin
  select count(*) into v_total from public.participants p where p.event_id = p_event_id;
  select count(m.minutes), coalesce(max(m.minutes) - min(m.minutes), 0), avg(m.minutes)
  into v_known, v_spread, v_avg
  from (select public.fn_travel_minutes(p_event_id, p_place_id, p.id) as minutes
        from public.participants p where p.event_id = p_event_id) m;
  if v_known < 2 then v_spread := 0; end if;
  v_coverage := case when v_total = 0 then 1 else v_known::numeric / v_total end;
  return jsonb_build_object(
    'participants', v_total, 'known', v_known, 'spread_minutes', v_spread,
    'average_minutes', case when v_avg is null then null else round(v_avg, 4) end,
    'complete', v_coverage >= 1,
    -- 30 minutes between the luckiest and the unluckiest participant halves the fairness
    -- credit; an average one-way trip of two hours earns no access credit at all.
    'fairness', public.fn_banded_score(v_coverage, 1.0 / (1.0 + v_spread / 30.0)),
    'access', public.fn_banded_score(v_coverage,
      case when v_avg is null then 0 else 1 - v_avg / 120.0 end));
end; $$;

-- Restaurant quality adjusted for review volume: shrink(r, n) = (50 * 3.9 + r * n) / (50 + n)
-- scaled onto 0..1 by Google's 5-point maximum. Every venue starts out as "an average Tokyo
-- izakaya with 50 reviews", so a 5.0 from 3 reviews (0.7925) cannot beat a 4.3 from 800
-- (0.8553). Google's scale starts at 1.0 and the field is absent for unrated places, so
-- rating <= 0 or a zero review count means "no signal", not "terrible": those fall back to
-- the historical atmosphere-tag proxy, which is capped at 0.2 — the floor of the shrunk
-- rating — so a venue with no rating data can never outscore one that has it.
create or replace function public.fn_quality_signal(
  p_rating numeric, p_user_rating_count int, p_atmosphere_tags text[]
) returns jsonb language plpgsql immutable security definer set search_path = '' as $$
declare v_tags int; v_shrunk numeric;
begin
  v_tags := least(coalesce(array_length(p_atmosphere_tags, 1), 0), 3);
  if p_rating is not null and p_rating > 0 and coalesce(p_user_rating_count, 0) > 0 then
    v_shrunk := (50 * 3.9 + least(5.0, greatest(1.0, p_rating)) * p_user_rating_count)
                / (50 + p_user_rating_count);
    return jsonb_build_object(
      'score', round(greatest(0, least(1, v_shrunk / 5.0)), 4),
      'method', 'rating_bayesian_shrunk', 'rating', p_rating,
      'user_rating_count', p_user_rating_count, 'prior_rating', 3.9,
      'prior_reviews', 50, 'atmosphere_tags', v_tags);
  end if;
  return jsonb_build_object(
    'score', round(0.2 * v_tags / 3.0, 4),
    'method', 'atmosphere_tag_proxy', 'rating', p_rating,
    'user_rating_count', p_user_rating_count, 'prior_rating', 3.9,
    'prior_reviews', 50, 'atmosphere_tags', v_tags);
end; $$;

-- How unfairly a price sits against the participants' budget MUSTs. The TIGHTEST budget in
-- the group decides, because a venue at the very top of it burdens that one person far more
-- than a venue comfortably under everyone's ceiling. An unknown price is the worst case, not
-- free. With no budget MUST at all there is nothing to be unfair against, so a documented
-- reference budget (a typical Tokyo 飲み会 per head) keeps the `cost` objective meaningful.
-- The regex guard is deliberate: (->>'max_yen')::int raises on a non-numeric value, and a
-- malformed constraint must not abort a whole scoring run.
create or replace function public.fn_cost_burden(p_event_id uuid, p_price_yen int)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_tightest int; v_count int; v_reference int;
begin
  -- The cast lives inside a CASE, not next to the regex in a WHERE clause: quals may be
  -- reordered by the planner, and a single malformed value would then abort the whole run.
  select min(v.max_yen), count(v.max_yen) into v_tightest, v_count
  from (
    select case when pc.normalized_value->>'max_yen' ~ '^[0-9]+$'
      then (pc.normalized_value->>'max_yen')::int end as max_yen
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST' and pc.normalized_type = 'budget'
  ) v
  where v.max_yen > 0;
  v_reference := coalesce(v_tightest, 6000);
  return jsonb_build_object(
    'burden', case when p_price_yen is null then 1.0
      else round(greatest(0, least(1, p_price_yen::numeric / v_reference)), 4) end,
    'price_yen', p_price_yen, 'tightest_budget_yen', v_tightest,
    'budget_musts', coalesce(v_count, 0), 'reference_yen', v_reference);
end; $$;

-- Accessibility burden. Both MUST and WANT rows count: fn_candidate_is_feasible has no
-- accessibility branch (such a MUST is silently satisfied) and an accessibility MUST is never
-- eligible for relaxation, so ranking is the only place the need can be honoured at all.
-- A venue with no accessibility data is UNKNOWN, which scores as full burden — never as
-- "supported". The worst-affected request set decides, so one participant whose needs are
-- entirely unmet is not averaged away by four who need nothing.
create or replace function public.fn_accessibility_burden(
  p_event_id uuid, p_accessibility_tags text[]
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_tags text[] := coalesce(p_accessibility_tags, '{}'::text[]);
  v_sets jsonb; v_needs text[]; v_unmet text[]; v_requests int; v_burden numeric;
begin
  -- Collect the well-formed need arrays first, inside a CASE, so nothing downstream can call
  -- jsonb_array_length on an object: one malformed row must not abort a scoring run.
  select coalesce(jsonb_agg(x.needs), '[]'::jsonb) into v_sets
  from (
    select case when jsonb_typeof(pc.normalized_value->'needs') = 'array'
      then pc.normalized_value->'needs' end as needs
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.normalized_type = 'accessibility'
  ) x
  where x.needs is not null and x.needs <> '[]'::jsonb;
  v_requests := jsonb_array_length(v_sets);
  select coalesce(max(r.unmet_ratio), 0) into v_burden
  from (
    select (select count(*) from jsonb_array_elements_text(s.needs) as t(need)
            where not (v_tags @> array[t.need]))::numeric
           / jsonb_array_length(s.needs) as unmet_ratio
    from jsonb_array_elements(v_sets) as s(needs)
  ) r;
  select coalesce(array_agg(distinct t.need order by t.need), '{}'::text[]) into v_needs
  from jsonb_array_elements(v_sets) as s(needs)
  cross join lateral jsonb_array_elements_text(s.needs) as t(need);
  select coalesce(array_agg(n order by n), '{}'::text[]) into v_unmet
  from unnest(v_needs) as n where not (v_tags @> array[n]);
  return jsonb_build_object(
    'burden', round(v_burden, 4), 'needs', to_jsonb(v_needs), 'unmet_needs', to_jsonb(v_unmet),
    'venue_tags', to_jsonb(v_tags), 'data_present', coalesce(array_length(v_tags, 1), 0) > 0,
    'requests', coalesce(v_requests, 0));
end; $$;

-- --- Feasibility ------------------------------------------------------------

-- Re-declared from 0009 with exactly one change: the travel_time branch reads
-- fn_travel_minutes instead of the global JSONB directly, so feasibility is event-scoped
-- once 0017 lands. Behaviour on the seed is identical (no cache rows -> JSONB fallback), and
-- an unknown travel time still fails a travel MUST rather than passing it.
create or replace function public.fn_candidate_is_feasible(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_candidate record; v_must record; v_value jsonb;
begin
  select rf.* into v_candidate from public.restaurant_features rf
  where rf.place_id = p_place_id;
  if not found then return false; end if;
  for v_must in
    select pc.id, pc.participant_id, pc.normalized_type, pc.normalized_value
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST'
  loop
    v_value := case when v_must.id = p_override_constraint_id
      then p_override_value else v_must.normalized_value end;
    if v_must.normalized_type = 'budget' then
      if v_candidate.price_yen_estimate is null
        or v_candidate.price_yen_estimate > (v_value->>'max_yen')::int
      then return false; end if;
    elsif v_must.normalized_type = 'room' then
      if v_candidate.room_type is distinct from (v_value->>'room')
      then return false; end if;
    elsif v_must.normalized_type = 'dietary' then
      if jsonb_typeof(v_value->'tags') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'tags'), 0) = 0
        or coalesce(array_length(v_candidate.dietary_tags, 1), 0) = 0
        or not (v_candidate.dietary_tags @> array(
          select jsonb_array_elements_text(v_value->'tags')))
      then return false; end if;
    elsif v_must.normalized_type = 'allergy' then
      if jsonb_typeof(v_value->'allergens') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'allergens'), 0) = 0
        or coalesce(array_length(v_candidate.allergy_safe_tags, 1), 0) = 0
        or not (v_candidate.allergy_safe_tags @> array(
          select allergen || '_free' from jsonb_array_elements_text(
            v_value->'allergens') as allergen))
      then return false; end if;
    elsif v_must.normalized_type = 'travel_time' then
      if coalesce(public.fn_travel_minutes(p_event_id, p_place_id, v_must.participant_id), 9999)
        > (v_value->>'max_minutes')::int
      then return false; end if;
    end if;
  end loop;
  return true;
end; $$;

-- --- Scoring ----------------------------------------------------------------

-- Candidate enumeration is unchanged (restaurants joined to features, gated by
-- fn_candidate_is_feasible) so the scored set can never disagree with the feasible_count
-- fn_recompute_feasibility just wrote. What changed is what happens to a feasible row:
-- six 0..1 components, an objective-weighted composite that decides both the order and
-- which five survive, a stored breakdown, and honest labels.
create or replace function public.fn_score_feasible_candidates(
  p_run_id uuid, p_event_id uuid
) returns void language plpgsql security definer set search_path = '' as $$
declare v_want_count int; v_objective text; v_weights jsonb; v_label text;
begin
  select count(*) into v_want_count from public.participant_constraints
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
      public.fn_quality_signal(rf.rating, rf.user_rating_count, rf.atmosphere_tags) as quality,
      public.fn_cost_burden(p_event_id, rf.price_yen_estimate) as cost,
      public.fn_accessibility_burden(p_event_id, rf.accessibility_tags) as accessibility
    from public.restaurants r
    join public.restaurant_features rf on rf.place_id = r.place_id
    where public.fn_candidate_is_feasible(p_event_id, r.place_id)
  ), comp as (
    select c.*,
      (c.travel->>'fairness')::numeric as travel_fairness,
      (c.travel->>'access')::numeric as travel_access,
      case when v_want_count = 0 then 1.0
        else round(c.wants_matched::numeric / v_want_count, 4) end as satisfaction,
      (c.quality->>'score')::numeric as quality_score,
      -- The columns store burden (higher is worse); the components are its complement so
      -- the objective can stay a plain weighted sum of "higher is better" numbers.
      round(1 - (c.cost->>'burden')::numeric, 4) as cost_fit,
      round(1 - (c.accessibility->>'burden')::numeric, 4) as accessibility_fit
    from cand c
  ), scored as (
    select comp.*,
      round((v_weights->>'travel_fairness')::numeric * comp.travel_fairness, 4) as c_fairness,
      round((v_weights->>'travel_access')::numeric * comp.travel_access, 4) as c_access,
      round((v_weights->>'satisfaction')::numeric * comp.satisfaction, 4) as c_satisfaction,
      round((v_weights->>'quality')::numeric * comp.quality_score, 4) as c_quality,
      round((v_weights->>'cost_fit')::numeric * comp.cost_fit, 4) as c_cost,
      round((v_weights->>'accessibility_fit')::numeric * comp.accessibility_fit, 4) as c_access_fit,
      round((v_weights->>'travel_fairness')::numeric * comp.travel_fairness
          + (v_weights->>'travel_access')::numeric * comp.travel_access
          + (v_weights->>'satisfaction')::numeric * comp.satisfaction
          + (v_weights->>'quality')::numeric * comp.quality_score
          + (v_weights->>'cost_fit')::numeric * comp.cost_fit
          + (v_weights->>'accessibility_fit')::numeric * comp.accessibility_fit, 4)
        as objective_score
    from comp
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
  -- 3–5 differentiated options. This is the one line the objective actually changes: it
  -- decides both which five feasible venues become cards and the order they are written in
  -- (the old `order by wants_matched desc` ignored the 幹事's objective entirely).
  order by s.objective_score desc nulls last, s.place_id
  limit 5;

  -- Honest labels. The old pass handed each label to the best still-UNLABELLED row, which
  -- made the badges lie. Now, per label, in this fixed order:
  --   * a row with no value for the metric can never lead it;
  --   * if every row shares the best value the metric separates nothing, so the badge is
  --     dropped — there is no "most X" to claim (leaders < total);
  --   * ties are legitimate co-leaders and the first by place_id that is still unlabelled
  --     takes it;
  --   * if every genuine leader already carries a badge the label goes UNUSED rather than
  --     being handed to a row that does not deserve it. Fewer than five labels is expected
  --     and the clients already render a null label as the neutral 「おすすめ」 badge.
  -- best_value reads cost_fit rather than the raw price: same ordering, but measured against
  -- the group's tightest budget, and an unknown price becomes ineligible instead of last.
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
end; $$;

-- --- Privileges -------------------------------------------------------------

-- Every function above is an implementation detail of the guarded fn_recompute_feasibility
-- RPC. Clients must not be able to call them: fn_travel_minutes and fn_travel_profile would
-- be cross-event travel oracles, fn_cost_burden leaks the tightest budget in a group, and
-- fn_score_feasible_candidates writes rows for any run_id it is handed (it was callable by
-- authenticated since 0005 — closed here).
revoke execute on function public.fn_travel_minutes(uuid, text, uuid)
  from public, anon, authenticated;
revoke execute on function public.fn_objective_weights(text) from public, anon, authenticated;
revoke execute on function public.fn_banded_score(numeric, numeric)
  from public, anon, authenticated;
revoke execute on function public.fn_travel_profile(uuid, text) from public, anon, authenticated;
revoke execute on function public.fn_quality_signal(numeric, int, text[])
  from public, anon, authenticated;
revoke execute on function public.fn_cost_burden(uuid, int) from public, anon, authenticated;
revoke execute on function public.fn_accessibility_burden(uuid, text[])
  from public, anon, authenticated;
revoke execute on function public.fn_score_feasible_candidates(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  from public, anon, authenticated;

-- The provider pipeline (service_role Edge Functions) reads travel minutes; nothing else
-- needs a direct grant, because the definer chain runs as the function owner.
grant execute on function public.fn_travel_minutes(uuid, text, uuid) to service_role;
grant execute on function public.fn_objective_weights(text) to service_role;
grant execute on function public.fn_banded_score(numeric, numeric) to service_role;
grant execute on function public.fn_travel_profile(uuid, text) to service_role;
grant execute on function public.fn_quality_signal(numeric, int, text[]) to service_role;
grant execute on function public.fn_cost_burden(uuid, int) to service_role;
grant execute on function public.fn_accessibility_burden(uuid, text[]) to service_role;
grant execute on function public.fn_score_feasible_candidates(uuid, uuid) to service_role;
