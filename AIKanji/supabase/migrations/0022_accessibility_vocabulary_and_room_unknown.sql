-- 0022_accessibility_vocabulary_and_room_unknown.sql
-- Two dead ends that 0021's fail-closed rules left behind. Feasibility stays a deterministic
-- decision procedure — no LLM, no vector similarity — and the five-persona seed still produces
-- exactly 0 feasible venues at baseline and exactly demo_place_001/002/004 after Bob's room
-- MUST is relaxed (asserted in tests/backend_tests.sql rather than assumed).
--
--   A  AN ACCESSIBILITY MUST COULD NOT BE MET BY ANY VENUE, EVER. 0016 added
--      restaurant_features.accessibility_tags and nothing has ever written it: 0017's
--      fn_record_provider_candidates deliberately skips it. 0021 then made an empty tag list
--      fail closed — right in principle (PRD §11, "unknown ≠ supported") — while
--      accessibility is also hardcoded onto fn_propose_relaxation's never-relax list. So
--      「車椅子で入れる店がいい」 as a MUST produced zero candidates AND no proposal,
--      permanently, in the one category where exclusion is least acceptable. Before 0021 the
--      same MUST was silently *satisfied*; both states are wrong.
--      Compounding it, `needs` was an open string array (llm-assist's prompt only said
--      'e.g. ["step_free","wheelchair"]') while feasibility requires exact array containment,
--      so even once venue data existed the two vocabularies would rarely have met.
--      This file defines the vocabulary ONCE, constrains the recorded tags to it,
--      canonicalises everything on the way in, gives the provider pipeline a write path for
--      it, and makes the exclusion legible in fn_recompute_feasibility's payload instead of
--      showing a wheelchair user 「0件」 with no reason. accessibility stays NEVER RELAXABLE
--      and gets NO accept_unknown step: consenting to an unverified step-free entrance is
--      consenting to the risk of not getting in. The honest escape is reporting coverage —
--      and phoning the venue (verification_requirement = 'required', 0018) — not consent.
--
--   B  A `room` MUST DEAD-ENDED EXACTLY LIKE SMOKING DID. restaurant_features.room_type is
--      populated only from Hot Pepper (hotPepperRoomType in functions/restaurant-search);
--      Google Places has no private-room field at all, so every Places-only candidate has
--      room_type NULL, which `is distinct from` both 'private' and the 'semi_private' that
--      0021's one step relaxed it to — infeasible before AND after, so
--      fn_count_unlocked_if_relaxed returned 0 and no question was ever asked. 個室 is the
--      most culturally central requirement of a Japanese 飲み会 and the centrepiece of the
--      PRD's demo, so a silent zero-candidate outcome is unacceptable. The step now carries
--      0021's `accept_unknown` flag as well; fn_relaxed_value documents why the two
--      concessions are ONE step rather than a two-rung ladder.
--
-- Everything is additive and re-runnable: new columns are not needed, the one new constraint
-- is drop-then-add, the two data normalizations only touch rows that would otherwise be
-- unsatisfiable, and every function is create-or-replace.

-- ---------------------------------------------------------------------------
-- A1. The vocabulary, defined once
-- ---------------------------------------------------------------------------

-- The Google Places API (New) `accessibilityOptions` object carries exactly four nullable
-- booleans — wheelchairAccessibleParking, wheelchairAccessibleEntrance,
-- wheelchairAccessibleRestroom, wheelchairAccessibleSeating — and that is the only structured
-- accessibility data any provider of ours can give us. The vocabulary is therefore those four
-- fields and nothing else, named after them so the mapping is 1:1 and needs no inference:
-- restaurant-search records a tag if and only if the corresponding boolean came back `true`.
--
-- What the four members mean here, and why nothing is derived from anything else:
--   wheelchair_accessible_entrance   there is a step-free way in
--   wheelchair_accessible_seating    a wheelchair user can be seated
--   wheelchair_accessible_restroom   the restroom is usable
--   wheelchair_accessible_parking    accessible parking exists
-- A NULL or absent boolean stays UNKNOWN: it never becomes `false` and never becomes a tag.
-- Because we only ever record positives, a tag that is missing always means "unconfirmed",
-- never "confirmed absent" — which is exactly why the count added to
-- fn_recompute_feasibility below is called *unverified* rather than *unsuitable*, and why a
-- venue can honestly be re-checked by phone.
--
-- The same four strings are stated in functions/llm-assist/index.ts (in the prompt AND
-- enforced on the model's answer server-side), mirrored in web/src/backend/engine.ts, and
-- constrained on the venue side by restaurant_features_accessibility_vocabulary below.
create or replace function public.fn_accessibility_vocabulary()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array[
    'wheelchair_accessible_entrance',
    'wheelchair_accessible_parking',
    'wheelchair_accessible_restroom',
    'wheelchair_accessible_seating'
  ]::text[];
$$;

-- Canonicalises any tag list onto the vocabulary: maps the two values the old open-ended
-- prompt suggested, drops everything it cannot express, dedupes and sorts.
--
-- WHY those two aliases and no others: 'step_free' and 'wheelchair' are the literal examples
-- llm-assist's prompt used to give, so they are the values already in the wild, and both are
-- about GETTING IN — which is precisely what wheelchairAccessibleEntrance certifies. Mapping
-- them there preserves the precondition and invents nothing further (it does not silently add
-- a restroom or a seating requirement nobody stated). Anything else — 'elevator', a model's
-- free invention, a hand-edited row — is dropped rather than kept, because a tag outside the
-- vocabulary can never be matched by provider data and would therefore turn a MUST into a
-- permanent zero. Dropping is never silent: llm-assist flags needs_clarification and preserves
-- the participant's own wording in semantic_remainder, and the backfill below does the same.
create or replace function public.fn_accessibility_canonical_tags(p_tags text[])
returns text[] language sql immutable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.canonical order by m.canonical), '{}'::text[])
  from (
    select case t.tag
      when 'step_free' then 'wheelchair_accessible_entrance'
      when 'wheelchair' then 'wheelchair_accessible_entrance'
      else t.tag end as canonical
    from pg_catalog.unnest(coalesce(p_tags, '{}'::text[])) as t(tag)
  ) m
  where m.canonical = any (public.fn_accessibility_vocabulary());
$$;

-- The same operation on a constraint's normalized_value ({"needs": string[]}). A missing or
-- non-array `needs` yields an empty array, which the callers below read as "the taxonomy
-- expresses none of this".
create or replace function public.fn_accessibility_canonical_needs(p_value jsonb)
returns text[] language sql immutable security definer set search_path = '' as $$
  select public.fn_accessibility_canonical_tags(
    case when jsonb_typeof(p_value->'needs') = 'array'
      then array(select jsonb_array_elements_text(p_value->'needs'))
      else '{}'::text[] end);
$$;

-- ---------------------------------------------------------------------------
-- A2. The vocabulary, enforced on the venue side
-- ---------------------------------------------------------------------------

-- Existing rows first: the constraint is validated against them, and a live project could
-- hold hand-written tags. Nothing in the repo writes this column yet (0017 skips it, seed.sql
-- leaves it '{}'), so in practice this is a no-op that keeps the migration safe anyway.
update public.restaurant_features rf
   set accessibility_tags = public.fn_accessibility_canonical_tags(rf.accessibility_tags)
 where rf.accessibility_tags is distinct from
       public.fn_accessibility_canonical_tags(rf.accessibility_tags);

-- drop-then-add keeps this re-runnable, matching 0016/0021's guard rails. The member list is
-- written out rather than read from fn_accessibility_vocabulary() on purpose: a CHECK that
-- calls a function is restored before that function exists by pg_dump/pg_restore, and it
-- would silently stop validating if the function were ever replaced. tests/backend_tests.sql
-- asserts the two agree by inserting fn_accessibility_vocabulary() itself.
--
-- `<@` is array containment, so '{}' (no data recorded) passes and a NULL element fails.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_accessibility_vocabulary;
alter table public.restaurant_features
  add constraint restaurant_features_accessibility_vocabulary
  check (accessibility_tags is null or accessibility_tags <@ array[
    'wheelchair_accessible_entrance',
    'wheelchair_accessible_parking',
    'wheelchair_accessible_restroom',
    'wheelchair_accessible_seating'
  ]::text[]);

-- ---------------------------------------------------------------------------
-- A3. The vocabulary, applied to accessibility rows written before it existed
-- ---------------------------------------------------------------------------

-- A live event can hold {"needs":["step_free","wheelchair"]} — values written against a
-- vocabulary that was only ever exemplified. Left alone they are bug A all over again for
-- exactly the participants this file protects: no recorded tag will ever match them, and the
-- MUST is not relaxable. They are canonicalised here, once, the way 0012 canonicalised the
-- pre-taxonomy dietary/allergy/cuisine shapes.
--
--   * needs that map onto the vocabulary are rewritten to it;
--   * needs that do not are dropped from `needs` and NOT forgotten: the row keeps the
--     participant's own raw_text in semantic_remainder (0018 created that column for exactly
--     this, and P1 semantic matching reads it);
--   * a row where NOTHING survives would become {"needs":[]}, which fails closed for every
--     venue and cannot be relaxed — the dead end this file removes. It is re-typed as `other`
--     instead: a non-gating note a human 幹事 can act on, which is honest about the engine
--     being unable to check it, rather than a MUST that silently excludes all of Tokyo.
--     verification_requirement is re-derived because 0018 owns it as a pure function of
--     (kind, normalized_type); `sensitivity` is deliberately left alone, since it is a floor a
--     caller may raise but never lower and this is still disability information.
--
-- Re-running is a no-op: canonical rows produce an identical value, and a re-typed row is no
-- longer normalized_type = 'accessibility'. Classifying old rows is bookkeeping, not a
-- participant edit, so the user triggers are held down exactly as in 0018's backfill: it must
-- not bump updated_at and must not broadcast `constraint_updated` to a group that changed
-- nothing.
alter table public.participant_constraints disable trigger user;
with canonical as (
  select pc.id,
         pc.kind,
         pc.raw_text,
         pc.semantic_remainder,
         pc.normalized_value as before_value,
         case when coalesce(array_length(t.tags, 1), 0) = 0
           then 'other' else 'accessibility' end as after_type,
         case when coalesce(array_length(t.tags, 1), 0) = 0
           then '{}'::jsonb else jsonb_build_object('needs', to_jsonb(t.tags)) end as after_value
  from public.participant_constraints pc
  cross join lateral (
    select public.fn_accessibility_canonical_needs(pc.normalized_value) as tags
  ) t
  where pc.normalized_type = 'accessibility'
)
update public.participant_constraints pc
   set normalized_type = c.after_type,
       normalized_value = c.after_value,
       semantic_remainder =
         coalesce(c.semantic_remainder, nullif(pg_catalog.btrim(c.raw_text), '')),
       verification_requirement =
         public.fn_constraint_verification_requirement(c.kind, c.after_type)
  from canonical c
 where pc.id = c.id
   and (c.after_value is distinct from c.before_value or c.after_type <> 'accessibility');
alter table public.participant_constraints enable trigger user;

-- ---------------------------------------------------------------------------
-- B. The provider write path for accessibility_tags
-- ---------------------------------------------------------------------------

-- 0017's fn_record_provider_candidates is frozen (its comment promises it never writes this
-- column, and editing it would rewrite a shipped migration), so the accessibility write is a
-- second, additive statement the Edge Function makes with the same candidate array.
--
-- Shape of each element: {"place_id": text, "accessibility_tags": string[]}. The key is
-- PRESENT ONLY WHEN Places actually returned an accessibilityOptions object, and that
-- distinction is the whole contract:
--   * key absent      → we did not learn anything this run; whatever is recorded stays.
--   * key present     → this is Places' current answer and it REPLACES the recorded set,
--                       including with '{}' when every boolean was null/false. Accessibility
--                       is the one attribute where a retraction must be able to land: a
--                       renovation that removes the ramp has to be able to take the tag away,
--                       and since we only ever record positives, an empty list is honestly
--                       "unconfirmed" rather than a downgrade of somebody's verified fact.
--                       (0017's writes are additive because Places and Hot Pepper overwrite
--                       each other's enrichment there; only Places speaks to accessibility,
--                       so there is nothing to protect it from.)
-- Incoming values are canonicalised, so a stale deployment sending 'step_free' is mapped
-- rather than raising a check violation that would fail the whole search.
--
-- accessibility_tags belongs to 0016. The write is gated behind an information_schema lookup
-- and executed dynamically, mirroring how 0017 gated 0016's `rating` write, so this function
-- can be created no matter which order the migrations arrive in.
create or replace function public.fn_record_provider_accessibility(
  p_event_id uuid,
  p_candidates jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_candidate jsonb;
  v_place_id text;
  v_tags text[];
  v_rows int;
  v_count int := 0;
  v_has_column boolean;
begin
  -- Same request-context shape as 0017: the service_role Edge Function client and direct SQL
  -- sessions (no JWT claims) are the admin/definer path; an API caller must never write
  -- provider data, least of all a safety attribute.
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record accessibility tags';
  end if;

  if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' then
    return 0;
  end if;

  if not exists (select 1 from public.events e where e.id = p_event_id) then
    raise exception 'event % not found', p_event_id;
  end if;

  select exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'restaurant_features'
      and c.column_name = 'accessibility_tags'
  ) into v_has_column;
  if not v_has_column then
    return 0;
  end if;

  for v_candidate in select value from jsonb_array_elements(p_candidates)
  loop
    v_place_id := nullif(v_candidate->>'place_id', '');
    if v_place_id is null then
      continue;
    end if;
    -- Absent, or present as anything other than an array: the provider said nothing we can
    -- read, so nothing is recorded and nothing is erased.
    if jsonb_typeof(v_candidate->'accessibility_tags') is distinct from 'array' then
      continue;
    end if;

    v_tags := public.fn_accessibility_canonical_tags(
      array(select jsonb_array_elements_text(v_candidate->'accessibility_tags')));

    execute 'update public.restaurant_features rf
                set accessibility_tags = $2::text[]
              where rf.place_id = $1'
      using v_place_id, v_tags;
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end; $$;

-- ---------------------------------------------------------------------------
-- C. Feasibility, factored so "why was this venue excluded?" is answerable
-- ---------------------------------------------------------------------------

-- The accessibility predicate, in one place: both fn_candidate_blocking_types and the
-- coverage count read it, so the gate and the explanation cannot disagree.
--
-- Unchanged from 0021 in every respect: `needs` must be a non-empty array (a MUST whose own
-- value cannot be read is not one we may certify as met), the venue must have tags recorded,
-- and those tags must CONTAIN every need. No tags recorded means UNKNOWN, and unknown is not
-- step-free.
create or replace function public.fn_accessibility_needs_met(
  p_venue_tags text[], p_value jsonb
) returns boolean language sql immutable security definer set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_value->'needs') = 'array'
    and coalesce(jsonb_array_length(p_value->'needs'), 0) > 0
    and coalesce(array_length(p_venue_tags, 1), 0) > 0
    and p_venue_tags @> array(select jsonb_array_elements_text(p_value->'needs')),
    false);
$$;

-- Which MUST TYPES stand between this event and this venue — '{}' meaning "feasible".
--
-- This is 0021's fn_candidate_is_feasible with its `return false`s turned into an accumulator,
-- and it exists so that "0 candidates" can be explained instead of merely reported: a
-- wheelchair user must never be shown a silent empty result. fn_candidate_is_feasible is now a
-- one-line wrapper over it, so there is exactly one implementation of the MUST chain and the
-- gate cannot drift from the explanation.
--
-- Every branch is 0021's text with two deliberate changes, both in `room` (bug B):
--   * an unreadable room preference now fails closed, exactly like smoking's. Previously
--     `room_type is distinct from (value->>'room')` quietly PASSED a venue whose room_type is
--     also NULL when the MUST had no readable room at all — an accidental pass on two unknowns;
--   * a venue whose room_type is NULL (every Places-only candidate) is admissible only once
--     the participant has accepted `accept_unknown`, and a venue KNOWN to be the wrong type
--     still fails afterwards.
-- 'unknown_venue' is deliberately not a normalized_type: a place with no restaurant_features
-- row was infeasible in 0016/0021 too, and this way no caller can mistake it for an
-- accessibility-only exclusion.
create or replace function public.fn_candidate_blocking_types(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns text[] language plpgsql security definer set search_path = '' as $$
declare v_candidate record; v_must record; v_value jsonb; v_preference text; v_room text;
  v_blocked text[] := '{}'::text[];
begin
  select rf.* into v_candidate from public.restaurant_features rf
  where rf.place_id = p_place_id;
  if not found then return array['unknown_venue']::text[]; end if;
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
      then v_blocked := v_blocked || 'budget'::text; end if;
    -- normalized_value is {"room": "private"|"semi_private"|"open"}, optionally carrying
    -- "accept_unknown": true once the participant has accepted the relaxation step (see
    -- fn_relaxed_value). Same three-part rule as smoking: an unreadable preference is not a
    -- satisfied one, an UNCONFIRMED venue passes only with the flag, and a venue KNOWN to be
    -- another room type always fails — so consenting to 半個室 never lets a counter-only
    -- 大衆酒場 in.
    elsif v_must.normalized_type = 'room' then
      v_room := v_value->>'room';
      if v_room is null
        or v_room not in ('private','semi_private','open')
        or (v_candidate.room_type is null
            and not public.fn_jsonb_flag(v_value, 'accept_unknown'))
        or (v_candidate.room_type is not null and v_candidate.room_type <> v_room)
      then v_blocked := v_blocked || 'room'::text; end if;
    elsif v_must.normalized_type = 'dietary' then
      if jsonb_typeof(v_value->'tags') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'tags'), 0) = 0
        or coalesce(array_length(v_candidate.dietary_tags, 1), 0) = 0
        or not (v_candidate.dietary_tags @> array(
          select jsonb_array_elements_text(v_value->'tags')))
      then v_blocked := v_blocked || 'dietary'::text; end if;
    elsif v_must.normalized_type = 'allergy' then
      if jsonb_typeof(v_value->'allergens') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'allergens'), 0) = 0
        or coalesce(array_length(v_candidate.allergy_safe_tags, 1), 0) = 0
        or not (v_candidate.allergy_safe_tags @> array(
          select allergen || '_free' from jsonb_array_elements_text(
            v_value->'allergens') as allergen))
      then v_blocked := v_blocked || 'allergy'::text; end if;
    -- normalized_value is {"needs": string[]} drawn from fn_accessibility_vocabulary(), which
    -- llm-assist states in its prompt and enforces on the model's answer. Never relaxable, so
    -- the only way a venue passes this is recorded provider data that covers every need.
    elsif v_must.normalized_type = 'accessibility' then
      if not public.fn_accessibility_needs_met(v_candidate.accessibility_tags, v_value)
      then v_blocked := v_blocked || 'accessibility'::text; end if;
    elsif v_must.normalized_type = 'smoking' then
      v_preference := v_value->>'preference';
      if v_preference is null
        or v_preference not in ('non_smoking','smoking_ok')
        or (v_candidate.smoking_policy is null
            and not public.fn_jsonb_flag(v_value, 'accept_unknown'))
        or (v_candidate.smoking_policy is not null
            and v_candidate.smoking_policy <> v_preference)
      then v_blocked := v_blocked || 'smoking'::text; end if;
    elsif v_must.normalized_type = 'travel_time' then
      if coalesce(public.fn_travel_minutes(p_event_id, p_place_id, v_must.participant_id), 9999)
        > public.fn_jsonb_int(v_value, 'max_minutes')
      then v_blocked := v_blocked || 'travel_time'::text; end if;
    end if;
  end loop;
  -- Deduped and sorted so two participants blocked on the same type read as one reason, and
  -- so a caller can compare against a literal array.
  return coalesce(
    (select array_agg(distinct t order by t) from pg_catalog.unnest(v_blocked) as t),
    '{}'::text[]);
end; $$;

-- Re-declared from 0021 as a wrapper. Same signature, same defaults, same meaning: a
-- candidate is feasible when nothing blocks it.
create or replace function public.fn_candidate_is_feasible(
  p_event_id uuid, p_place_id text, p_override_constraint_id uuid default null,
  p_override_value jsonb default null
) returns boolean language plpgsql security definer set search_path = '' as $$
begin
  return coalesce(array_length(public.fn_candidate_blocking_types(
    p_event_id, p_place_id, p_override_constraint_id, p_override_value), 1), 0) = 0;
end; $$;

-- ---------------------------------------------------------------------------
-- D. The relaxation step, still in one place
-- ---------------------------------------------------------------------------

-- Re-declared from 0021 with one change: the `room` step also sets `accept_unknown`.
-- fn_count_unlocked_if_relaxed and fn_propose_relaxation both call this function and are
-- untouched, which is why "what would we offer?" and "what did we offer?" still cannot drift.
--
--   room         private -> semi_private (a divider instead of a door) AND accept an
--                UNCONFIRMED venue
--   travel_time  +10 minutes
--   budget       +500 yen
--   smoking      keep the preference, accept an UNCONFIRMED venue
--
-- WHY THE TWO ROOM CONCESSIONS ARE ONE STEP AND NOT A TWO-RUNG LADDER. Both orderings were
-- considered, and each is unreachable in one of the two worlds this engine has to serve:
--   * widen first ({"room":"semi_private"}, then accept_unknown). On a Places-only candidate
--     set — the case bug B is about — every room_type is NULL, so widening unlocks NOTHING,
--     fn_propose_relaxation's `if v_best_unlocked <= 0 then return null` fires, and the second
--     rung is never offered because the first was never accepted. The ladder cannot start.
--   * accept unknown first ({"room":"private","accept_unknown":true}, then widen). On the
--     seeded demo — where every venue HAS a room_type — that unlocks nothing either, so Bob is
--     never asked and the 0-then-3 invariant dies.
--   fn_relaxed_value is a pure function of (type, value) by design; it cannot look at the
--   candidate pool to choose a rung, and giving it a step index would reintroduce exactly the
--   drift 0021 removed. Composing the two concessions into one step is reachable in both
--   worlds, asks the participant one question instead of two (PRD §9: do not pressure
--   repeatedly), and stays legible in the data: {"room":"semi_private","accept_unknown":true}
--   says 「半個室でも、個室かどうか確認できていないお店でも良いですか？」.
--
-- What it never trades away: the room type is still checked against the venue whenever the
-- venue HAS one, so an accepted step admits only confirmed 半個室 and unconfirmed venues —
-- never a venue known to be `open`. And the ladder terminates: relaxing an already-relaxed
-- room value returns the identical jsonb, so it unlocks 0 and is never proposed again.
-- An unreadable room value is carried over as SQL NULL rather than invented, which keeps the
-- relaxed value infeasible and therefore un-proposable — the same treatment smoking gives a
-- preference it cannot read.
--
-- accessibility still gets no step, on purpose: it stays on the never-relax list with allergy
-- and dietary. Asking a wheelchair user to accept an unverified step-free entrance is asking
-- them to risk not getting in, which is not the same class of trade as an unverified smoking
-- policy or an unconfirmed divider. There the escape is human verification plus the coverage
-- count added in section E — reporting, not consent.
create or replace function public.fn_relaxed_value(
  p_normalized_type text, p_normalized_value jsonb
) returns jsonb language sql immutable security definer set search_path = '' as $$
  select case p_normalized_type
    when 'room' then jsonb_build_object(
      'room', case when p_normalized_value->>'room' = 'private'
        then 'semi_private' else p_normalized_value->>'room' end,
      'accept_unknown', true)
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
-- E. Accessibility coverage in the recompute payload
-- ---------------------------------------------------------------------------

-- Re-declared from 0018 (itself 0014's/0009's definition plus the lifecycle refresh, which is
-- kept at the end as that file asks) with two changes:
--
--   1. the candidate loop reads fn_candidate_blocking_types once per venue instead of calling
--      fn_candidate_is_feasible, so the same pass that counts feasible venues can also count
--      why the others were not;
--   2. ONE NEW KEY, `accessibility_unverified_count`. Every existing key keeps its name and
--      its exact meaning — the web and Swift clients decode this payload and adding a key is
--      the only backwards-compatible way to say something new.
--
-- accessibility_unverified_count is the number of candidates whose ONLY unmet MUSTs are
-- accessibility ones: venues that would be on the shortlist if their accessibility could be
-- confirmed. That is the honest, actionable number behind 「N件は車椅子対応が確認できませんで
-- した（お店に確認できます）」, and it is the reason a wheelchair user is not simply shown
-- 「0件」 with no explanation. It is deliberately NOT "every venue that fails an accessibility
-- MUST": a venue that also breaks somebody's budget would not become available by a phone
-- call, so counting it would invite a false conclusion.
-- "Unverified" rather than "unsuitable" because we only ever record positive tags: a need the
-- recorded tags do not cover is unconfirmed, never confirmed-absent.
-- It is 0 unless somebody stated an accessibility MUST, so nothing changes for events that
-- did not.
create or replace function public.fn_recompute_feasibility(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run_id uuid; v_feasible_count int := 0; v_unverified_count int := 0;
  v_candidate record; v_blocked text[];
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
    v_blocked := public.fn_candidate_blocking_types(p_event_id, v_candidate.place_id);
    if coalesce(array_length(v_blocked, 1), 0) = 0 then
      v_feasible_count := v_feasible_count + 1;
    elsif v_blocked = array['accessibility']::text[] then
      v_unverified_count := v_unverified_count + 1;
    end if;
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
  return jsonb_build_object('run_id', v_run_id, 'feasible_count', v_feasible_count,
    'accessibility_unverified_count', v_unverified_count);
end; $$;

-- ---------------------------------------------------------------------------
-- F. Privileges
-- ---------------------------------------------------------------------------

-- Same rule as 0009/0016/0021: these are implementation details of the guarded RPCs. A client
-- that can call fn_candidate_blocking_types gets a cross-event feasibility oracle, and one
-- that can call the vocabulary helpers learns nothing it needs. `create or replace` keeps
-- existing grants, so only the new functions strictly need this — the rest is restated so the
-- privilege story lives next to the definitions.
revoke execute on function public.fn_accessibility_vocabulary()
  from public, anon, authenticated;
revoke execute on function public.fn_accessibility_canonical_tags(text[])
  from public, anon, authenticated;
revoke execute on function public.fn_accessibility_canonical_needs(jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_accessibility_needs_met(text[], jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_blocking_types(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_relaxed_value(text, jsonb) from public, anon, authenticated;
revoke execute on function public.fn_record_provider_accessibility(uuid, jsonb)
  from public, anon, authenticated;

grant execute on function public.fn_accessibility_vocabulary() to service_role;
grant execute on function public.fn_accessibility_canonical_tags(text[]) to service_role;
grant execute on function public.fn_accessibility_canonical_needs(jsonb) to service_role;
grant execute on function public.fn_accessibility_needs_met(text[], jsonb) to service_role;
grant execute on function public.fn_candidate_blocking_types(uuid, text, uuid, jsonb)
  to service_role;
grant execute on function public.fn_candidate_is_feasible(uuid, text, uuid, jsonb)
  to service_role;
grant execute on function public.fn_relaxed_value(text, jsonb) to service_role;
-- The provider pipeline runs as service_role and is the only caller of the write path.
grant execute on function public.fn_record_provider_accessibility(uuid, jsonb) to service_role;

-- fn_recompute_feasibility stays a client RPC: it is guarded by the membership check above.
revoke execute on function public.fn_recompute_feasibility(uuid) from public, anon;
grant execute on function public.fn_recompute_feasibility(uuid) to authenticated, service_role;
