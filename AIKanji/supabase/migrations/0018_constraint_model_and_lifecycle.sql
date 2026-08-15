-- P0 completion: the constraint record the PRD actually specifies, plus a real event lifecycle.
--
--   A  participant_constraints.sensitivity / .verification_requirement  (PRD §15 record fields)
--   B  participant_constraints.semantic_remainder                       (parser spec: keep what
--                                                                       the taxonomy dropped)
--   C  events.preferences_closed_at + fn_close_preferences + meaningful
--      'negotiating' / 'ready' statuses                                 (PRD §12)
--   D  fn_get_collection_readiness — "enough responses" instead of "everyone answered" (PRD §12)
--
-- Everything is additive. Every new column is defaulted or nullable, so the app's existing
-- inserts (which do not mention these columns yet) keep working untouched, and the demo seed
-- fixture keeps its meaning: only advisory metadata is added, never a feasibility input.

-- ---------------------------------------------------------------------------
-- A + B. Constraint record fields
-- ---------------------------------------------------------------------------

-- sensitivity              how personal the requirement is. Advisory only: it drives
--                          presentation and logging care, never feasibility and *never*
--                          `visibility`, which stays the participant's own decision (PRD §5:
--                          "LLM may suggest sensitivity, but user controls visibility").
-- verification_requirement whether this MUST needs external confirmation before it can be
--                          trusted (PRD §11: "Unknown ≠ supported"). P0 records the
--                          requirement only; the evidence tiers that consume it are P1.
-- semantic_remainder       the slice of the participant's own wording the taxonomy could not
--                          express. NULL when nothing was left over. P1 semantic matching
--                          embeds exactly this text, so it has to be captured now.
--                          raw_text stays verbatim; this column never replaces it. Like
--                          raw_text it is verbatim human wording, so it stays out of
--                          fn_get_sanitized_feed and out of the group broadcast payload.
alter table public.participant_constraints
  add column if not exists sensitivity text not null default 'normal',
  add column if not exists verification_requirement text not null default 'none',
  add column if not exists semantic_remainder text;

-- Drop-then-add keeps the checks re-runnable on a database that already has 0018.
alter table public.participant_constraints
  drop constraint if exists participant_constraints_sensitivity_check;
alter table public.participant_constraints
  add constraint participant_constraints_sensitivity_check
  check (sensitivity in ('normal','sensitive','highly_sensitive'));

alter table public.participant_constraints
  drop constraint if exists participant_constraints_verification_requirement_check;
alter table public.participant_constraints
  add constraint participant_constraints_verification_requirement_check
  check (verification_requirement in ('none','recommended','required'));

-- The taxonomy mapping lives in the database so the server, not the model, decides it.
-- 'highly_sensitive' is exactly the set that already defaults to ANONYMOUS visibility and is
-- already excluded from relaxation proposals — health, religion and disability data. Budget is
-- 'sensitive' because money talk between coworkers is awkward (PRD §5 sensitive budget), but it
-- is not health data. Keep in sync with SENSITIVITY_BY_TYPE in functions/llm-assist/index.ts.
create or replace function public.fn_constraint_sensitivity(p_normalized_type text)
returns text language sql immutable security definer set search_path = '' as $$
  select case p_normalized_type
    when 'allergy' then 'highly_sensitive'
    when 'dietary' then 'highly_sensitive'
    when 'accessibility' then 'highly_sensitive'
    when 'budget' then 'sensitive'
    else 'normal' end;
$$;

-- Only a MUST can gate a venue, so only a MUST can demand verification.
--   required     safety categories: an unsupported guess here can hurt somebody, so the venue
--                may only stay on the shortlist while clearly marked "needs confirmation".
--   recommended  provider-sourced amenities that go stale (room type, smoking policy): worth a
--                phone call, but a wrong answer is a disappointment, not a hazard.
--   none         computed from our own data (budget, travel_time) or non-gating.
create or replace function public.fn_constraint_verification_requirement(
  p_kind text, p_normalized_type text
) returns text language sql immutable security definer set search_path = '' as $$
  select case
    when p_kind is distinct from 'MUST' then 'none'
    when p_normalized_type in ('allergy','dietary','accessibility') then 'required'
    when p_normalized_type in ('room','smoking') then 'recommended'
    else 'none' end;
$$;

create or replace function public.fn_sensitivity_rank(p_sensitivity text)
returns int language sql immutable security definer set search_path = '' as $$
  select case p_sensitivity
    when 'highly_sensitive' then 2
    when 'sensitive' then 1
    else 0 end;
$$;

create or replace function public.fn_derive_constraint_metadata()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_floor text;
begin
  v_floor := public.fn_constraint_sensitivity(new.normalized_type);
  -- Sensitivity is a per-category floor a caller may raise but never lower: the LLM (or the
  -- participant) can say "this cuisine note is personal to me", but nobody gets to declare an
  -- allergy ordinary. `visibility` is untouched here on purpose — the user owns that field.
  if new.sensitivity is null
     or public.fn_sensitivity_rank(new.sensitivity) < public.fn_sensitivity_rank(v_floor)
  then new.sensitivity := v_floor; end if;

  -- Verification is an integrity property of the requirement, not a preference, so it is always
  -- server-derived: a client must not be able to insert an allergy MUST that claims it needs no
  -- confirmation. Whether the requirement has been *met* is P1 evidence state, stored elsewhere.
  new.verification_requirement :=
    public.fn_constraint_verification_requirement(new.kind, new.normalized_type);
  return new;
end; $$;

drop trigger if exists trg_derive_constraint_metadata on public.participant_constraints;
create trigger trg_derive_constraint_metadata
  before insert or update on public.participant_constraints
  for each row execute function public.fn_derive_constraint_metadata();

-- Backfill rows written before this migration. Classifying old rows is bookkeeping, not a
-- participant edit, so the user triggers are held down: it must not bump updated_at and must
-- not emit a `constraint_updated` broadcast to a group that changed nothing.
alter table public.participant_constraints disable trigger user;
update public.participant_constraints pc
   set sensitivity = case
         when public.fn_sensitivity_rank(pc.sensitivity)
              < public.fn_sensitivity_rank(public.fn_constraint_sensitivity(pc.normalized_type))
         then public.fn_constraint_sensitivity(pc.normalized_type)
         else pc.sensitivity end,
       verification_requirement =
         public.fn_constraint_verification_requirement(pc.kind, pc.normalized_type)
 where public.fn_sensitivity_rank(pc.sensitivity)
       < public.fn_sensitivity_rank(public.fn_constraint_sensitivity(pc.normalized_type))
    or pc.verification_requirement is distinct from
       public.fn_constraint_verification_requirement(pc.kind, pc.normalized_type);
alter table public.participant_constraints enable trigger user;

-- ---------------------------------------------------------------------------
-- C. Event lifecycle: closing preference collection, and real intermediate statuses
-- ---------------------------------------------------------------------------

-- Distinct from events.status: this is the point in time after which participant-authored
-- constraint writes stop, while status keeps describing where the *decision* stands.
alter table public.events add column if not exists preferences_closed_at timestamptz;

-- Single place that derives events.status from observable state, so 'negotiating' and 'ready'
-- stop being decorative. Precedence, most blocking first:
--   closed       a restaurant was chosen — terminal, never walked backwards
--   negotiating  somebody owes an answer to a relaxation proposal
--   ready        the latest run produced a non-empty feasible shortlist
--   negotiating  collection is closed and there is still no shortlist: nothing left to collect,
--                the group can only negotiate its way out
--   collecting   still gathering requirements
-- Callers that just produced a run pass its count in; the fallback lookup below is only reached
-- when this transaction created no run (two runs in one transaction share run_at).
create or replace function public.fn_refresh_event_status(
  p_event_id uuid, p_feasible_count int default null
) returns text language plpgsql security definer set search_path = '' as $$
declare v_event public.events%rowtype; v_pending int; v_feasible int; v_next text;
begin
  select * into v_event from public.events e where e.id = p_event_id;
  if not found then return null; end if;
  if v_event.status = 'closed' or v_event.chosen_place_id is not null then
    return v_event.status;
  end if;

  select count(*) into v_pending from public.negotiations n
   where n.event_id = p_event_id and n.status = 'PROPOSED';

  v_feasible := p_feasible_count;
  if v_feasible is null then
    select rr.feasible_count into v_feasible from public.recommendation_runs rr
     where rr.event_id = p_event_id
     order by rr.run_at desc, rr.id desc limit 1;
  end if;

  v_next := case
    when v_pending > 0 then 'negotiating'
    when coalesce(v_feasible, 0) > 0 then 'ready'
    when v_event.preferences_closed_at is not null then 'negotiating'
    else 'collecting' end;

  if v_next is distinct from v_event.status then
    update public.events e set status = v_next where e.id = p_event_id;
  end if;
  return v_next;
end; $$;

-- 幹事-only close (PRD §12). Same authorization shape as fn_choose_restaurant: organizer
-- identity through events.organizer_participant_id, with the request-context guard so
-- service_role and direct SQL sessions (migrations, the SQL harness) still work.
create or replace function public.fn_close_preferences(p_event_id uuid)
returns table (preferences_closed_at timestamptz, status text)
language plpgsql security definer set search_path = '' as $$
declare v_is_organizer boolean; v_existing timestamptz; v_status text;
begin
  select exists (
    select 1
    from public.events e
    join public.participants p on p.id = e.organizer_participant_id
    where e.id = p_event_id
      and p.auth_user_id = auth.uid()
  ) into v_is_organizer;

  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
     and not v_is_organizer
  then
    raise exception 'only the organizer can close preference collection';
  end if;

  select e.preferences_closed_at into v_existing from public.events e where e.id = p_event_id;
  if not found then
    raise exception 'event not found';
  end if;

  -- Idempotent: re-closing keeps the first timestamp, so "post-close" stays well defined.
  if v_existing is null then
    update public.events e set preferences_closed_at = now() where e.id = p_event_id;
  end if;

  -- Deliberately no fn_recompute_feasibility call: PRD §12 requires post-close changes to be
  -- recalculated *explicitly*, so closing only moves the marker and re-derives the status.
  v_status := public.fn_refresh_event_status(p_event_id);

  perform realtime.send(
    jsonb_build_object('status', v_status),
    'preferences_closed',
    'event-' || p_event_id::text,
    true
  );

  return query
  select e.preferences_closed_at, e.status
  from public.events e
  where e.id = p_event_id;
end; $$;

-- Post-close integrity is enforced here, in RLS, not in the client: hiding the form would still
-- leave the table writable to anyone with the anon key and a participant session.
-- Definer helper for the same reason fn_my_event_ids exists — a policy that reaches into
-- another RLS-protected table from inside a policy predicate is how the recursion bugs started.
create or replace function public.fn_preferences_closed(p_event_id uuid)
returns boolean language sql security definer stable set search_path = '' as $$
  select exists (
    select 1 from public.events e
    where e.id = p_event_id and e.preferences_closed_at is not null
  );
$$;

-- Ownership stays in `using`, closure goes in `with check`: a failed `with check` raises a
-- policy violation the client must surface, while a failed `using` would silently update zero
-- rows — and silence is exactly what PRD §12 forbids here.
drop policy if exists "participant writes own raw constraints" on public.participant_constraints;
create policy "participant writes own raw constraints"
  on public.participant_constraints for insert
  with check (
    exists (
      select 1 from public.participants p
      where p.id = participant_id
        and p.event_id = participant_constraints.event_id
        and p.auth_user_id = (select auth.uid())
    )
    and not public.fn_preferences_closed(participant_constraints.event_id)
  );

drop policy if exists "participant updates own raw constraints" on public.participant_constraints;
create policy "participant updates own raw constraints"
  on public.participant_constraints for update
  using (exists (
    select 1 from public.participants p
    where p.id = participant_id
      and p.event_id = participant_constraints.event_id
      and p.auth_user_id = (select auth.uid())
  ))
  with check (
    exists (
      select 1 from public.participants p
      where p.id = participant_id
        and p.event_id = participant_constraints.event_id
        and p.auth_user_id = (select auth.uid())
    )
    and not public.fn_preferences_closed(participant_constraints.event_id)
  );
-- There is still no delete policy, so RLS keeps denying client deletes outright.
-- fn_respond_negotiation rewrites a constraint as security definer, which is the one sanctioned
-- post-close change: it is explicit, targeted, and it recomputes.

-- Re-declared verbatim from 0014 (itself the 0009 definition) with one addition: the lifecycle
-- refresh. Guards, snapshot shape, candidate ordering and return payload are unchanged.
-- If a later migration rewrites this function (candidate enumeration, snapshot contents), keep
-- the fn_refresh_event_status call at the end — it is the only thing 0018 adds here.
create or replace function public.fn_recompute_feasibility(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run_id uuid; v_feasible_count int := 0; v_candidate record;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;
  for v_candidate in
    select r.place_id from public.restaurants r
    join public.restaurant_features rf on rf.place_id = r.place_id
    order by r.place_id
  loop
    if public.fn_candidate_is_feasible(p_event_id, v_candidate.place_id)
    then v_feasible_count := v_feasible_count + 1; end if;
  end loop;
  insert into public.recommendation_runs (event_id, feasible_count, input_snapshot)
  values (p_event_id, v_feasible_count, jsonb_build_object('must_count',
    (select count(*) from public.participant_constraints
     where event_id = p_event_id and kind = 'MUST')))
  returning id into v_run_id;
  if v_feasible_count > 0
  then perform public.fn_score_feasible_candidates(v_run_id, p_event_id); end if;
  -- A fresh shortlist is what makes an event 'ready'; pass the count so the status never
  -- depends on which of two same-timestamp runs sorts first.
  perform public.fn_refresh_event_status(p_event_id, v_feasible_count);
  return jsonb_build_object('run_id', v_run_id, 'feasible_count', v_feasible_count);
end; $$;

-- Re-declared verbatim from 0014 plus the refresh: an unanswered proposal is what 'negotiating'
-- means. Safety categories stay excluded from relaxation, membership guard unchanged, and the
-- "nothing unlocks anything" path still returns null without touching the event.
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
  for v_candidate in
    select pc.id as constraint_id, pc.participant_id, pc.normalized_type,
      pc.normalized_value
    from public.participant_constraints pc
    where pc.event_id = p_event_id and pc.kind = 'MUST'
      and pc.normalized_type not in ('allergy','dietary','accessibility')
    order by pc.id
  loop
    v_unlocked := public.fn_count_unlocked_if_relaxed(
      p_event_id, v_candidate.constraint_id);
    if v_unlocked > v_best_unlocked then
      v_best_unlocked := v_unlocked; v_best_constraint := v_candidate;
    end if;
  end loop;
  if v_best_unlocked <= 0 then return null; end if;
  insert into public.negotiations
    (event_id, constraint_id, participant_id, proposed_value, unlocked_count)
  values (p_event_id, v_best_constraint.constraint_id,
    v_best_constraint.participant_id,
    case v_best_constraint.normalized_type
      when 'room' then jsonb_build_object('room','semi_private')
      when 'travel_time' then jsonb_build_object('max_minutes',
        (v_best_constraint.normalized_value->>'max_minutes')::int + 10)
      when 'budget' then jsonb_build_object('max_yen',
        (v_best_constraint.normalized_value->>'max_yen')::int + 500)
      else v_best_constraint.normalized_value end, v_best_unlocked)
  returning id into v_negotiation_id;
  perform public.fn_refresh_event_status(p_event_id);
  return v_negotiation_id;
end; $$;

-- Re-declared verbatim from 0009 (the 0006 definition) plus one refresh on the reject path.
-- The accept path is already refreshed by fn_recompute_feasibility with the authoritative
-- count, so it is not refreshed twice; rejecting creates no run, it only clears the block.
create or replace function public.fn_respond_negotiation(
  p_negotiation_id uuid, p_accept boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_neg public.negotiations%rowtype; v_caller_participant_id uuid;
  v_result jsonb;
begin
  select * into v_neg from public.negotiations where id = p_negotiation_id;
  if not found then raise exception 'negotiation not found'; end if;
  select id into v_caller_participant_id from public.participants
  where auth_user_id = auth.uid() and event_id = v_neg.event_id;
  if v_neg.participant_id is distinct from v_caller_participant_id
  then raise exception 'not authorized to respond to this negotiation'; end if;
  if v_neg.status <> 'PROPOSED'
  then raise exception 'negotiation already resolved'; end if;
  if p_accept then
    update public.participant_constraints set normalized_value = v_neg.proposed_value,
      updated_at = now() where id = v_neg.constraint_id;
    update public.negotiations set status = 'ACCEPTED', responded_at = now()
      where id = p_negotiation_id;
    v_result := public.fn_recompute_feasibility(v_neg.event_id);
  else
    update public.negotiations set status = 'REJECTED', responded_at = now()
      where id = p_negotiation_id;
    select jsonb_build_object('feasible_count', feasible_count) into v_result
    from public.recommendation_runs where event_id = v_neg.event_id
    order by run_at desc limit 1;
    perform public.fn_refresh_event_status(v_neg.event_id);
  end if;
  return v_result;
end; $$;

-- ---------------------------------------------------------------------------
-- D. Progressive search readiness
-- ---------------------------------------------------------------------------

-- PRD §12: provisional recommendations start once *enough* people have answered, so the group
-- is never held hostage by one silent colleague. fn_get_response_count keeps its bare-count
-- signature (clients depend on it); this sits alongside it and counts *people*, not rows.
--
-- Threshold for a 4-8 person 飲み会: three responders, or 60% of the group, whichever is
-- larger, capped at the group size — 4→3, 5→3, 6→4, 7→5, 8→5. Three is the smallest sample
-- where a fairness trade-off is real rather than a coin flip between two people, and the 60%
-- floor keeps a shortlist for eight people from being decided by three of them. A closed event
-- is ready by definition: no further answers are coming.
create or replace function public.fn_get_collection_readiness(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_participants int; v_responded int; v_threshold int; v_met boolean;
  v_closed timestamptz;
begin
  if coalesce(auth.role(), '') <> 'service_role'
    and nullif(current_setting('request.jwt.claims', true), '') is not null
    and not exists (
      select 1 from public.participants
      where event_id = p_event_id and auth_user_id = auth.uid())
  then raise exception 'not a participant of this event'; end if;

  select count(*) into v_participants
  from public.participants p where p.event_id = p_event_id;
  select count(distinct pc.participant_id) into v_responded
  from public.participant_constraints pc where pc.event_id = p_event_id;
  select e.preferences_closed_at into v_closed
  from public.events e where e.id = p_event_id;

  v_threshold := least(v_participants, greatest(3, ceil(v_participants * 0.6)::int));
  v_met := (v_participants > 0 and v_responded >= v_threshold);

  return jsonb_build_object(
    'participant_count', v_participants,
    'responded_count', v_responded,
    'threshold_count', v_threshold,
    'threshold_met', v_met,
    'provisional_ready', (v_met or v_closed is not null),
    'preferences_closed', (v_closed is not null),
    'preferences_closed_at', v_closed
  );
end; $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

-- The deterministic classifiers are safe to expose: they are pure functions of the taxonomy and
-- reveal nothing about any event, and a client can use them to preview a badge before saving.
revoke execute on function public.fn_constraint_sensitivity(text) from public, anon;
revoke execute on function public.fn_constraint_verification_requirement(text, text)
  from public, anon;
grant execute on function public.fn_constraint_sensitivity(text) to authenticated, service_role;
grant execute on function public.fn_constraint_verification_requirement(text, text)
  to authenticated, service_role;

-- Internal ordering helper and the trigger body: not RPCs. `authenticated` keeps execute on the
-- trigger function because revoking from public would otherwise strip it from every writer.
revoke execute on function public.fn_sensitivity_rank(text) from public, anon;
grant execute on function public.fn_sensitivity_rank(text) to authenticated, service_role;
revoke execute on function public.fn_derive_constraint_metadata() from public, anon;
grant execute on function public.fn_derive_constraint_metadata() to authenticated, service_role;

-- Status derivation is an implementation detail of the guarded RPCs above: exposing it would
-- let any caller nudge another event's status.
revoke execute on function public.fn_refresh_event_status(uuid, int)
  from public, anon, authenticated;
grant execute on function public.fn_refresh_event_status(uuid, int) to service_role;

-- fn_preferences_closed is evaluated inside the constraint write policies, so `authenticated`
-- must be able to execute it or every insert would fail with a permission error.
revoke execute on function public.fn_preferences_closed(uuid) from public, anon;
grant execute on function public.fn_preferences_closed(uuid) to authenticated, service_role;

revoke execute on function public.fn_close_preferences(uuid) from public, anon;
grant execute on function public.fn_close_preferences(uuid) to authenticated, service_role;

revoke execute on function public.fn_get_collection_readiness(uuid) from public, anon;
grant execute on function public.fn_get_collection_readiness(uuid) to authenticated, service_role;

revoke execute on function public.fn_recompute_feasibility(uuid) from public, anon;
revoke execute on function public.fn_propose_relaxation(uuid) from public, anon;
revoke execute on function public.fn_respond_negotiation(uuid, boolean) from public, anon;
grant execute on function public.fn_recompute_feasibility(uuid) to authenticated, service_role;
grant execute on function public.fn_propose_relaxation(uuid) to authenticated, service_role;
grant execute on function public.fn_respond_negotiation(uuid, boolean)
  to authenticated, service_role;
