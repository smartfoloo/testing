-- 0021_must_coverage_and_proposal_integrity.sql
-- Four confirmed engine bugs. Feasibility stays a deterministic decision procedure: no LLM,
-- no similarity, and the five-persona seed still produces exactly 0 feasible venues at
-- baseline and exactly demo_place_001/002/004 after Bob's room MUST relaxes private ->
-- semi_private (the seed states no accessibility and no smoking MUST, so nothing below can
-- touch it — asserted in tests/backend_tests.sql rather than assumed).
--
--   1  accessibility / smoking MUSTs fell through the if/elsif chain in
--      fn_candidate_is_feasible and were therefore SILENTLY MET. 「車椅子で入れる店」 as a
--      hard requirement was ignored while accessibility was simultaneously on the
--      never-relax list — too sacred to negotiate, never actually enforced. Both types now
--      have a branch, fail-closed on absent venue data exactly like dietary/allergy
--      (PRD §11 "unknown ≠ supported"), and `smoking` gets a relaxation step so the
--      fail-closed rule cannot dead-end a group (see fn_relaxed_value).
--   2  (seed.sql) the demo invite code was unreachable through either join screen.
--   3  (v->>'max_yen')::int raised invalid_text_representation on {"max_yen":"cheap"} and
--      RLS lets any participant write arbitrary normalized_value, so ONE bad row aborted
--      the whole event's recompute. Every jsonb->int read in the engine now goes through
--      fn_jsonb_int.
--   4  fn_propose_relaxation was not idempotent: pressing 「条件に合うお店を探す」 four times
--      while feasible = 0 wrote four identical PROPOSED rows and asked the same participant
--      the same question four times, which PRD §9 explicitly forbids. It now returns the
--      open proposal instead of writing another one, a partial unique index makes that
--      invariant true even under a concurrent double-press, and a step somebody already
--      REJECTED is never offered again.

-- ---------------------------------------------------------------------------
-- A. Safe jsonb readers
-- ---------------------------------------------------------------------------

-- Bug 3. Mirrors nullableInt() in web/src/backend/engine.ts, which has always returned null
-- for anything non-finite — so this makes SQL match the TypeScript port, not the reverse.
--
-- The SQL NULL semantics are load-bearing and unchanged: a MISSING key already yielded NULL,
-- `x > null` is NULL, and `if` treats NULL as false, so a MUST whose key is absent still
-- PASSES. All that changes is that a present-but-not-numeric value yields NULL instead of
-- raising and killing the whole run. A value outside int range is also reported as absent,
-- for the same reason: `price > null` is false either way, so both implementations agree on
-- the outcome without either of them raising.
create or replace function public.fn_jsonb_int(p_value jsonb, p_key text)
returns int language sql immutable security definer set search_path = '' as $$
  select case
    when p_value is null or p_value->p_key is null then null
    -- Guard the cast with a regex on the TEXT form and a range check, and do it inside the
    -- CASE: a cast written next to the guard in a WHERE clause may be evaluated first.
    when p_value->>p_key ~ '^-?[0-9]+(\.[0-9]+)?$'
      and (p_value->>p_key)::numeric between -2147483648 and 2147483647
      then trunc((p_value->>p_key)::numeric)::int
    else null end;
$$;

-- Strict boolean read, used for the smoking relaxation flag. Only a real JSON `true`
-- counts: the flag is written by fn_relaxed_value, so anything else in that key is a
-- hand-edited or malformed value and must not widen a MUST. Never raises.
create or replace function public.fn_jsonb_flag(p_value jsonb, p_key text)
returns boolean language sql immutable security definer set search_path = '' as $$
  select coalesce(p_value->p_key = 'true'::jsonb, false);
$$;

-- ---------------------------------------------------------------------------
-- B. The missing venue attribute for smoking
-- ---------------------------------------------------------------------------

-- Bug 1. There was no smoking column at all, so a smoking MUST could not have been
-- evaluated even if the if/elsif chain had reached it. Nullable and undefaulted in the
-- style of room_type / price_yen_estimate: NULL means "we do not know", which the branch
-- below treats as NOT satisfied, never as "non-smoking confirmed".
--
-- No provider of ours can speak to this yet (0017's fn_record_provider_candidates does not
-- write it, and must not be edited); a nullable column keeps that upsert working untouched.
-- 分煙 (a separated smoking area) is deliberately NOT a third value: from provider text we
-- cannot certify which side of the partition a group would sit on, so such a venue stays
-- NULL = unconfirmed and reaches the participant through the relaxation step instead of
-- being quietly counted as non-smoking.
alter table public.restaurant_features add column if not exists smoking_policy text;

-- drop-then-add keeps this re-runnable, matching 0016's guard rails.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_smoking_policy_check;
alter table public.restaurant_features
  add constraint restaurant_features_smoking_policy_check
  check (smoking_policy is null or smoking_policy in ('non_smoking','smoking_ok'));

-- ---------------------------------------------------------------------------
-- C. Travel lookup, with the unsafe cast removed
-- ---------------------------------------------------------------------------

-- Re-declared from 0016 with exactly one change: the legacy JSONB fallback is read through
-- fn_jsonb_int. Cache precedence, event scoping and "NULL means unknown, never zero
-- minutes" are unchanged. The JSONB is merged from provider writes and from rows other
-- events touched, and a single junk entry used to raise here — inside the loop that decides
-- feasibility for every candidate.
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
  select public.fn_jsonb_int(rf.travel_minutes_by_participant, p_participant_id::text)
  into v_minutes
  from public.restaurant_features rf where rf.place_id = p_place_id;
  return v_minutes;
end; $$;

-- ---------------------------------------------------------------------------
-- D. The relaxation step, in one place
-- ---------------------------------------------------------------------------

-- The single step the engine is willing to propose, per constraint type. It was duplicated
-- verbatim in fn_count_unlocked_if_relaxed and fn_propose_relaxation, so "what would we
-- offer?" and "what did we offer?" could drift; bug 4's REJECTED rule needs to compare them,
-- so they are now one function.
--
--   room         private -> semi_private (a divider instead of a door)
--   travel_time  +10 minutes
--   budget       +500 yen
--   smoking      keep the preference, accept an UNCONFIRMED venue
--
-- WHY the smoking step is "accept_unknown" and nothing else:
--   * a fail-closed smoking MUST is unsatisfiable today, because no provider fills
--     smoking_policy. Without a step, fn_count_unlocked_if_relaxed returns 0, no proposal is
--     ever offered, and the group is stuck with 0 candidates and no question to answer —
--     which is why `smoking` is deliberately NOT on the never-relax list;
--   * what actually blocks these venues is MISSING DATA, not a known conflict, so the honest
--     question to ask is 「禁煙が確認できていないお店も候補に入れてよいですか？」. The
--     participant trades certainty for options, and the constraint record already carries
--     verification_requirement = 'recommended' (0018), which is the UI's cue to say
--     「お店に電話で確認してください」;
--   * it never trades away what the participant asked for: a venue KNOWN to be 喫煙可 still
--     fails a non_smoking MUST after the relaxation. Only unconfirmed venues are admitted.
--   * accessibility gets no step on purpose. It stays on the never-relax list with allergy
--     and dietary: asking a wheelchair user to accept an unverified step-free entrance is
--     asking them to risk not getting in. There the escape hatch is human verification
--     (verification_requirement = 'required'), not a negotiation.
-- A type with no step (cuisine, atmosphere, other, and the safety trio) returns its value
-- unchanged, so fn_count_unlocked_if_relaxed measures a no-op and reports 0 unlocked.
create or replace function public.fn_relaxed_value(
  p_normalized_type text, p_normalized_value jsonb
) returns jsonb language sql immutable security definer set search_path = '' as $$
  select case p_normalized_type
    when 'room' then jsonb_build_object('room', 'semi_private')
    -- coalesce(...,0) matches relaxedValue() in engine.ts. The old inline version wrote
    -- {"max_minutes": null} for an unreadable value, and accepting THAT would have deleted
    -- the MUST (every comparison against null passes) instead of loosening it.
    when 'travel_time' then jsonb_build_object('max_minutes',
      coalesce(public.fn_jsonb_int(p_normalized_value, 'max_minutes'), 0) + 10)
    when 'budget' then jsonb_build_object('max_yen',
      coalesce(public.fn_jsonb_int(p_normalized_value, 'max_yen'), 0) + 500)
    when 'smoking' then jsonb_build_object(
      'preference', p_normalized_value->>'preference', 'accept_unknown', true)
    else p_normalized_value end;
$$;

-- ---------------------------------------------------------------------------
-- E. Feasibility
-- ---------------------------------------------------------------------------

-- Re-declared from 0016 with the two missing branches and the safe integer reads. Every
-- other branch is byte-for-byte the 0016 text, so the demo fixture is unaffected.
--
-- The new branches follow the convention dietary/allergy already set: ABSENT VENUE DATA IS
-- NOT SATISFACTION (PRD §11), and a MUST whose own normalized_value cannot be read is not a
-- MUST we may certify as met either. That is fail-closed in both directions, which for a
-- wheelchair user or somebody with asthma is the only defensible default.
create or replace function public.fn_candidate_is_feasible(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_candidate record; v_must record; v_value jsonb; v_preference text;
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
        or v_candidate.price_yen_estimate > public.fn_jsonb_int(v_value, 'max_yen')
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
    -- normalized_value is {"needs": string[]} (see functions/llm-assist/index.ts). Same
    -- shape check as dietary, against 0016's accessibility_tags: no tags recorded means the
    -- venue is UNKNOWN, and unknown is not step-free. Never relaxable, so the only way a
    -- venue passes this is real data.
    elsif v_must.normalized_type = 'accessibility' then
      if jsonb_typeof(v_value->'needs') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'needs'), 0) = 0
        or coalesce(array_length(v_candidate.accessibility_tags, 1), 0) = 0
        or not (v_candidate.accessibility_tags @> array(
          select jsonb_array_elements_text(v_value->'needs')))
      then return false; end if;
    -- normalized_value is {"preference": "non_smoking"|"smoking_ok"}, optionally carrying
    -- "accept_unknown": true once the participant has accepted the relaxation in
    -- fn_relaxed_value. `v_preference is null` is checked explicitly because `null not in
    -- (...)` is NULL, which `if` reads as false — the exact shape of the bug being fixed.
    elsif v_must.normalized_type = 'smoking' then
      v_preference := v_value->>'preference';
      if v_preference is null
        or v_preference not in ('non_smoking','smoking_ok')
        or (v_candidate.smoking_policy is null
            and not public.fn_jsonb_flag(v_value, 'accept_unknown'))
        or (v_candidate.smoking_policy is not null
            and v_candidate.smoking_policy <> v_preference)
      then return false; end if;
    elsif v_must.normalized_type = 'travel_time' then
      if coalesce(public.fn_travel_minutes(p_event_id, p_place_id, v_must.participant_id), 9999)
        > public.fn_jsonb_int(v_value, 'max_minutes')
      then return false; end if;
    end if;
  end loop;
  return true;
end; $$;

-- ---------------------------------------------------------------------------
-- F. What-if counting
-- ---------------------------------------------------------------------------

-- Re-declared from 0009 with the inline relaxation CASE replaced by fn_relaxed_value (which
-- also makes the +10 / +500 arithmetic safe on a malformed value). Guards, the baseline vs
-- relaxed comparison and the "writes nothing" property are unchanged.
create or replace function public.fn_count_unlocked_if_relaxed(
  p_event_id uuid, p_constraint_id uuid
) returns int language plpgsql security definer set search_path = '' as $$
declare v_constraint record; v_relaxed jsonb; v_baseline int; v_relaxed_count int;
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
  select count(*) filter (where public.fn_candidate_is_feasible(p_event_id, r.place_id)),
    count(*) filter (where public.fn_candidate_is_feasible(
      p_event_id, r.place_id, p_constraint_id, v_relaxed))
  into v_baseline, v_relaxed_count
  from public.restaurants r
  join public.restaurant_features rf on rf.place_id = r.place_id;
  return v_relaxed_count - v_baseline;
end; $$;

-- ---------------------------------------------------------------------------
-- G. One open proposal per event, enforced by the schema
-- ---------------------------------------------------------------------------

-- Bug 4, in the schema. The function below is careful, but a concurrent double-press would
-- still slip past a check-then-insert, and PRD §9 ("do not pressure repeatedly") deserves an
-- invariant rather than a best effort. Scoped to the EVENT, not the constraint, because two
-- open questions at once are also wrong: each unlocked_count was computed assuming the other
-- MUST unchanged, so accepting both over-relaxes the group. ACCEPTED / REJECTED history is
-- unconstrained — an event legitimately accumulates one row per answered question.
--
-- Existing duplicates have to go first or the index cannot be built. They are exactly the
-- rows this bug created: byte-identical, unanswered questions. The OLDEST open proposal per
-- event survives (it is the one already in front of a participant); the rest are deleted
-- rather than re-labelled, because the only statuses available are ACCEPTED and REJECTED and
-- recording a rejection nobody made would both lie and — through the rule below — stop the
-- group from ever being asked that question again.
delete from public.negotiations n
using public.negotiations keeper
where n.status = 'PROPOSED'
  and keeper.status = 'PROPOSED'
  and keeper.event_id = n.event_id
  and (keeper.created_at, keeper.id) < (n.created_at, n.id);

create unique index if not exists ux_negotiations_one_open_per_event
  on public.negotiations (event_id) where status = 'PROPOSED';

-- ---------------------------------------------------------------------------
-- H. Idempotent relaxation proposals
-- ---------------------------------------------------------------------------

-- Re-declared from 0018 (which added the lifecycle refresh to the 0009 definition) with
-- three changes, all of them bug 4:
--
--   1. AN OPEN PROPOSAL IS RETURNED, NEVER DUPLICATED. Four presses now produce one row and
--      one returned id, so the caller's 「参加者に条件の変更をお願いしました」 stays true and
--      the participant is asked once.
--   2. WHAT IF THE OPEN PROPOSAL IS FOR A DIFFERENT CONSTRAINT than the one now judged best?
--      The open one still wins, and no new one is written. Retargeting would either withdraw
--      a question somebody is looking at, or put a second question to a second person while
--      the first is unanswered — and since each unlocked_count assumes every other MUST is
--      unchanged, two acceptances would relax more than the group needed. Nothing is lost:
--      answering the open proposal takes it out of PROPOSED, and the next call re-ranks from
--      scratch and picks whatever is best then. The better target is deferred one round, not
--      dropped.
--   3. A REJECTED STEP IS NEVER RE-OFFERED. PRD: "on rejection, keep the MUST and do not
--      pressure repeatedly" — re-proposing what somebody just declined is precisely that
--      pressure, and re-asking is what makes a participant feel worn down into agreeing.
--      Matched on (constraint_id, proposed_value), not constraint_id alone, so that "no"
--      means no to THAT question: if the participant later edits their own MUST (4000 ->
--      4200 yen), the step is a different one and asking it is a new question rather than a
--      repeat. It also avoids blacklisting a constraint forever, which could dead-end an
--      event whose only relaxable MUST was declined once.
create or replace function public.fn_propose_relaxation(p_event_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_negotiation_id uuid; v_candidate record; v_best_constraint record;
  v_best_unlocked int := -1; v_unlocked int;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;

  -- Reuse before propose.
  select n.id into v_negotiation_id from public.negotiations n
   where n.event_id = p_event_id and n.status = 'PROPOSED'
   order by n.created_at, n.id limit 1;
  if v_negotiation_id is not null then
    -- An unanswered proposal is what 'negotiating' means, so keep the status honest even
    -- though this call wrote nothing.
    perform public.fn_refresh_event_status(p_event_id);
    return v_negotiation_id;
  end if;

  for v_candidate in
    select pc.id as constraint_id, pc.participant_id, pc.normalized_type,
      pc.normalized_value
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST'
      and pc.normalized_type not in ('allergy','dietary','accessibility')
      and not exists (
        select 1 from public.negotiations n
        where n.constraint_id = pc.id and n.status = 'REJECTED'
          and n.proposed_value = public.fn_relaxed_value(
            pc.normalized_type, pc.normalized_value))
    order by pc.id
  loop
    v_unlocked := public.fn_count_unlocked_if_relaxed(
      p_event_id, v_candidate.constraint_id);
    if v_unlocked > v_best_unlocked then
      v_best_unlocked := v_unlocked; v_best_constraint := v_candidate;
    end if;
  end loop;
  if v_best_unlocked <= 0 then return null; end if;

  begin
    insert into public.negotiations
      (event_id, constraint_id, participant_id, proposed_value, unlocked_count)
    values (p_event_id, v_best_constraint.constraint_id,
      v_best_constraint.participant_id,
      public.fn_relaxed_value(
        v_best_constraint.normalized_type, v_best_constraint.normalized_value),
      v_best_unlocked)
    returning id into v_negotiation_id;
  exception when unique_violation then
    -- A concurrent double-press committed first. Return ITS row: the caller asked for "the
    -- open question for this event", and there is exactly one.
    select n.id into v_negotiation_id from public.negotiations n
     where n.event_id = p_event_id and n.status = 'PROPOSED'
     order by n.created_at, n.id limit 1;
  end;

  perform public.fn_refresh_event_status(p_event_id);
  return v_negotiation_id;
end; $$;

-- ---------------------------------------------------------------------------
-- I. Privileges
-- ---------------------------------------------------------------------------

-- The readers and the relaxation table are internal to the guarded RPCs. They are pure
-- functions, but a client that can call fn_relaxed_value learns nothing it needs and a
-- client that can call fn_candidate_is_feasible / fn_count_unlocked_if_relaxed gets a
-- cross-event feasibility oracle, so the 0009/0016 revocations are restated here — a
-- `create or replace` keeps existing grants, and these functions are new.
revoke execute on function public.fn_jsonb_int(jsonb, text) from public, anon, authenticated;
revoke execute on function public.fn_jsonb_flag(jsonb, text) from public, anon, authenticated;
revoke execute on function public.fn_relaxed_value(text, jsonb) from public, anon, authenticated;
revoke execute on function public.fn_travel_minutes(uuid, text, uuid)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid)
  from public, anon, authenticated;

-- The provider pipeline runs as service_role and reads travel minutes directly (0016); the
-- rest only need to be reachable for the same admin/backfill paths the other definer
-- helpers are.
grant execute on function public.fn_jsonb_int(jsonb, text) to service_role;
grant execute on function public.fn_jsonb_flag(jsonb, text) to service_role;
grant execute on function public.fn_relaxed_value(text, jsonb) to service_role;
grant execute on function public.fn_travel_minutes(uuid, text, uuid) to service_role;
grant execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  to service_role;
grant execute on function public.fn_count_unlocked_if_relaxed(uuid, uuid) to service_role;

-- fn_propose_relaxation stays a client RPC: it is guarded by the membership check above.
revoke execute on function public.fn_propose_relaxation(uuid) from public, anon;
grant execute on function public.fn_propose_relaxation(uuid) to authenticated, service_role;
