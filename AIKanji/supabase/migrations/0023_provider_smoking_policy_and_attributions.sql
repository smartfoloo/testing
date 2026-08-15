-- 0023_provider_smoking_policy_and_attributions.sql
-- Two pieces of provider data the pipeline already FETCHES AND THROWS AWAY. Feasibility stays a
-- deterministic decision procedure — no LLM, no vector similarity — and the five-persona seed
-- still produces exactly 0 feasible venues at baseline and exactly demo_place_001/002/004 after
-- Bob's room MUST is relaxed (asserted in tests/backend_tests.sql rather than assumed).
--
--   A  smoking_policy HAS NO WRITER AT ALL. 0021 added restaurant_features.smoking_policy, made
--      a smoking MUST fail closed on NULL (PRD §11, "unknown ≠ supported") and added the
--      `accept_unknown` relaxation precisely so that fail-closed rule would not be a dead end.
--      But nothing has ever populated the column, so EVERY 禁煙 MUST still has to spend a
--      negotiation round before one single venue can qualify, and the only answer the group can
--      ever be given is 「確認できていません」. Hot Pepper answers this question in its Gourmet
--      Search response (`non_smoking`, 禁煙席) and functions/restaurant-search ALREADY RECEIVES
--      IT — the request sets no `lite` parameter, so the whole shop object comes back and the
--      HotPepperShop interface simply never declared the field. This file owns the mapping from
--      that free text onto the two legal values, and the write path that records it.
--
--   B  GOOGLE'S PER-PLACE ATTRIBUTIONS HAD NOWHERE TO LIVE. Places content displayed without a
--      Google map requires Google Maps attribution AND requires that the third-party
--      `attributions` the API returns for a place are retrieved and displayed. The Text Search
--      field mask never asked for them, so we did not hold the data at all and the display
--      could not be built. restaurant_features gains ONE new column for them — see section C
--      for why the raw-payload table (0017) is the wrong home — and a write path beside the
--      smoking one.
--
-- Everything is additive and re-runnable: the one new column is `add column if not exists`, its
-- constraint is drop-then-add, and every function is create-or-replace. Nothing here touches
-- 0022's accessibility vocabulary or its venue-side CHECK, and nothing here edits 0017's frozen
-- fn_record_provider_candidates.

-- ---------------------------------------------------------------------------
-- A1. Hot Pepper's 禁煙席 text, mapped onto the two legal values
-- ---------------------------------------------------------------------------

-- `non_smoking` (禁煙席) in Recruit's Gourmet Search response is FREE-TEXT JAPANESE, not an
-- enum. The reference's own example value is 「一部禁煙」, sibling fields carry things like
-- 「あり」/「なし」/「未確認」, and NO EXHAUSTIVE LIST IS PUBLISHED. smoking_policy, by contrast,
-- has exactly two legal values by design (0021), so this function's contract is: recognise a
-- small allowlist of values that unambiguously describe THE WHOLE VENUE, and answer NULL —
-- "unconfirmed" — for everything else, including everything it has never seen.
--
-- THE MAPPING TABLE (after normalization; anything not listed is NULL):
--   'non_smoking'  全席禁煙 / 全面禁煙 / 店内全席禁煙 / 店内全面禁煙 / 完全禁煙
--   'smoking_ok'   全席喫煙可 / 全席喫煙可能 / 全面喫煙可 / 店内全席喫煙可 / 店内全面喫煙可
--   NULL           一部禁煙, 分煙, 禁煙席あり, 禁煙席なし, 喫煙可, テラス席のみ喫煙可,
--                  全席禁煙(喫煙ブースあり), あり, なし, 未確認, 禁煙, '', and every value
--                  this list does not name
--
-- WHY PARTIAL IS NULL AND NOT A GUESS. 一部禁煙 and 分煙 say a boundary exists somewhere in the
-- room; they do not say which side a group of five will be seated on, and there is no third
-- value to record it as. Recording 'non_smoking' would CERTIFY to a non-smoker that the table
-- they are sent to is smoke-free, on evidence that says the opposite is equally likely.
-- Recording 'smoking_ok' would tell a smoker they may smoke at the table and would also, via
-- 0021's rule, permanently exclude the venue from every non-smoking MUST. NULL is the honest
-- answer, and it is not a dead end: 0021's `accept_unknown` step exists for exactly this state,
-- and the group is asked 「禁煙が確認できていないお店も候補に入れてよいですか？」 instead of being
-- told a fact nobody verified.
--
-- WHY EXACT MATCHES AND NOT SUBSTRINGS. `like '%禁煙%'` is the trap this function exists to
-- avoid: 「一部禁煙」, 「禁煙席あり」 and 「全席禁煙(喫煙ブースあり)」 all contain 禁煙 while
-- describing a room somebody is smoking in, and 「禁煙席なし」 contains 禁煙席 while asserting the
-- opposite of one. An unrecognised value therefore stays unconfirmed, which is the pre-0023
-- status quo for that venue — never a wrong policy. Extending the allowlist is a data question:
-- add a value only once it has been OBSERVED in a live response, and only if it names the whole
-- venue.
--
-- Two values that look mappable and deliberately are not:
--   禁煙        no scope at all. A bare token may summarise 店内禁煙(屋外喫煙所あり) just as
--               easily as 全席禁煙, and we cannot tell which.
--   禁煙席なし  says which seats are MISSING, not what is permitted. A venue that banned
--               smoking outright under the 2020 改正健康増進法 has no 禁煙席 to advertise
--               either, so reading it as "smoking is allowed throughout" is an inference.
--
-- Normalization before matching, so formatting cannot hide a match we do recognise:
-- NFKC folds full-width alphanumerics and half-width katakana onto their canonical forms, and
-- every whitespace character (including the ideographic space U+3000) is removed. `normalize`
-- is SQL-standard syntax whose second argument is a keyword, so it is the one call here that
-- cannot be written schema-qualified; it resolves in pg_catalog, which is always implicitly
-- searched even under `search_path = ''`. Parenthetical remarks are deliberately NOT stripped —
-- 「(喫煙ブースあり)」 is precisely the part that decides the answer.
create or replace function public.fn_hotpepper_smoking_policy(p_value text)
returns text language sql immutable security definer set search_path = '' as $$
  select case pg_catalog.regexp_replace(
           normalize(coalesce(p_value, ''), NFKC), '[[:space:]　]+', '', 'g')
    when '全席禁煙' then 'non_smoking'
    when '全面禁煙' then 'non_smoking'
    when '店内全席禁煙' then 'non_smoking'
    when '店内全面禁煙' then 'non_smoking'
    when '完全禁煙' then 'non_smoking'
    when '全席喫煙可' then 'smoking_ok'
    when '全席喫煙可能' then 'smoking_ok'
    when '全面喫煙可' then 'smoking_ok'
    when '店内全席喫煙可' then 'smoking_ok'
    when '店内全面喫煙可' then 'smoking_ok'
    else null end;
$$;

-- ---------------------------------------------------------------------------
-- A2. The provider write path for smoking_policy
-- ---------------------------------------------------------------------------

-- 0017's fn_record_provider_candidates is frozen — its comment promises it never writes columns
-- no provider could speak to, and editing a shipped migration is not an option — so this is a
-- second, additive statement the Edge Function makes with the SAME candidate array, exactly as
-- 0022 added fn_record_provider_accessibility beside it.
--
-- Shape of each element: {"place_id": text, "hotpepper_non_smoking": text}. The value is Hot
-- Pepper's own text, forwarded verbatim; the mapping onto the two legal values lives in
-- fn_hotpepper_smoking_policy above and nowhere else, so a mapping fix is a migration rather
-- than a redeploy, and the Edge Function and the database cannot drift into two opinions about
-- what 一部禁煙 means. The raw text also lands in restaurant_source_records (0017), so the
-- decision is auditable against the payload that produced it.
--
-- ADDITIVE OR AUTHORITATIVE? Both, along the axis that matters, and the KEY'S PRESENCE is the
-- whole contract:
--   * key ABSENT (or null, or not a string, or blank) → nothing learned, nothing written.
--     This is the common case and the reason the distinction exists: only candidates MATCHED in
--     Hot Pepper (hotPepperSearch's ~100m match) have any answer at all, and Google Places has
--     no smoking field whatsoever. A Places-only candidate, or a re-run where Hot Pepper was
--     down (its failure records a provider_incidents row and returns an empty shop list), must
--     never erase a policy an earlier matched run recorded. That is 0017's non-destructive
--     rule, kept.
--   * key PRESENT with a real answer → that answer REPLACES what is recorded, including with
--     NULL when the text is partial or unrecognised. Only Hot Pepper speaks to smoking, so
--     there is no other provider's enrichment to protect here (the same argument 0022 made for
--     accessibility), and a retraction has to be able to land: 「全席禁煙」 is a legal state a
--     venue can leave, and the 2020 改正健康増進法 moved a great many venues in both directions.
--     Keeping a stale 'non_smoking' because the newest answer is 一部禁煙 would certify
--     smoke-free seating to a non-smoker on evidence we no longer have — the one outcome the
--     whole fail-closed design exists to prevent. Retracting to NULL costs the group only a
--     negotiation round, which is a question, not a false promise.
-- Nothing outside fn_hotpepper_smoking_policy's two-value range can be written, so 0021's CHECK
-- can never be violated by this path and a provider anomaly cannot fail the whole search.
--
-- smoking_policy belongs to 0021. The write is gated behind an information_schema lookup and
-- executed dynamically, mirroring how 0017 gated 0016's `rating` write and 0022 gated
-- accessibility_tags, so this function can be created no matter which order the migrations
-- arrive in.
create or replace function public.fn_record_provider_smoking_policy(
  p_event_id uuid,
  p_candidates jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_candidate jsonb;
  v_place_id text;
  v_probe text;
  v_policy text;
  v_rows int;
  v_count int := 0;
  v_has_column boolean;
begin
  -- Same request-context shape as 0017/0022: the service_role Edge Function client and direct
  -- SQL sessions (no JWT claims) are the admin/definer path; an API caller must never write
  -- provider data, least of all an attribute somebody's health decision rests on.
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record a smoking policy';
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
      and c.column_name = 'smoking_policy'
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
    -- Absent, or present as anything other than a JSON string: Hot Pepper did not match this
    -- candidate (or said nothing readable), so nothing is recorded and nothing is erased.
    if jsonb_typeof(v_candidate->'hotpepper_non_smoking') is distinct from 'string' then
      continue;
    end if;
    -- A string that is blank once whitespace is folded away is not an answer either, and must
    -- not retract a recorded policy. NFKC first so the ideographic space U+3000 — which plain
    -- btrim() does not touch — counts as whitespace like everything else. Hot Pepper spells "we
    -- do not know" as 未確認, which IS an answer and is mapped (to NULL) rather than skipped.
    v_probe := nullif(
      pg_catalog.regexp_replace(
        normalize(v_candidate->>'hotpepper_non_smoking', NFKC), '[[:space:]]+', '', 'g'), '');
    if v_probe is null then
      continue;
    end if;

    -- Mapped from the ORIGINAL text, never from the probe above: fn_hotpepper_smoking_policy
    -- owns normalization and has to see exactly what the provider sent.
    v_policy := public.fn_hotpepper_smoking_policy(
      v_candidate->>'hotpepper_non_smoking');

    execute 'update public.restaurant_features rf
                set smoking_policy = $2::text
              where rf.place_id = $1'
      using v_place_id, v_policy;
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end; $$;

-- ---------------------------------------------------------------------------
-- B. Hot Pepper's barrier_free is NOT an accessibility source. Deliberately.
-- ---------------------------------------------------------------------------

-- The same Gourmet Search response carries `barrier_free` (バリアフリー), also free text, whose
-- documented example value is 「なし」. It is not mapped onto anything, and this comment is the
-- justification, because "we forgot" and "we decided not to" must not look the same in a
-- repository.
--
-- 0022 established a CLOSED four-member vocabulary (fn_accessibility_vocabulary:
-- wheelchair_accessible_entrance / _parking / _restroom / _seating), each member named after
-- one Google Places `accessibilityOptions` boolean so the mapping is 1:1 and involves no
-- inference at all. Hot Pepper's field cannot honestly justify ANY member:
--   * 「なし」 means there are no barrier-free facilities. The honest recording of that is no
--     tag — which is exactly what happens if we map nothing, and which correctly fails an
--     accessibility MUST closed.
--   * 「あり」 is a vague positive over an unspecified set of facilities. It does not say the
--     ENTRANCE is step-free, or that the RESTROOM is usable, or that a wheelchair user can be
--     SEATED — and those are the only three things the vocabulary can express about a venue a
--     group is deciding on. Choosing one of them from 「あり」 would be a guess dressed as a
--     provider fact.
--   * anything else (未確認, 一部, a sentence describing a slope) is neither.
-- Accessibility is the one attribute with NO relaxation step: it is on fn_propose_relaxation's
-- never-relax list, and 0022 explains why (consenting to an unverified step-free entrance is
-- consenting to the risk of not getting in). So a false positive here cannot be walked back by
-- a question — it puts a wheelchair user in front of a step they were told was not there. A
-- missing tag, by contrast, is visible and actionable: it fails closed, it is counted in
-- fn_recompute_feasibility's accessibility_unverified_count, and the constraint carries
-- verification_requirement = 'required' (0018) so the 幹事 can phone the venue.
--
-- Nothing here weakens 0022: the vocabulary function, the venue-side CHECK
-- (restaurant_features_accessibility_vocabulary) and fn_accessibility_canonical_tags are
-- untouched. Because canonicalisation drops everything outside the vocabulary, even a future
-- deployment that tried to forward 「あり」 or a literal 'barrier_free' as a tag could not land
-- it — asserted in tests/backend_tests.sql. The Edge Function declares the field in
-- HotPepperShop and reads it nowhere, which is how the decision stays visible at the boundary
-- where somebody would otherwise "fix" it.

-- ---------------------------------------------------------------------------
-- C. Where Google's per-place attributions live
-- ---------------------------------------------------------------------------

-- Google's policy: Places content shown WITHOUT a Google map needs Google Maps attribution,
-- and the third-party `attributions` the API returns for a place must be retrieved and
-- displayed. The first half is a static credit the client renders; the second half is DATA, and
-- data that has to reach the client.
--
-- WHY A COLUMN HERE AND NOT restaurant_source_records. The raw-payload table (0017) already
-- receives the whole Places object, attributions included — but it is service-role only: it has
-- no client read policy, RLS therefore denies anon and authenticated outright, and 0017 revokes
-- their table privileges as well ("provider content under provider terms: server-side only").
-- Data a client is REQUIRED to display cannot live somewhere the client cannot read, and
-- widening that table's policy would expose every raw field we ever fetch in order to publish
-- one that must be published. restaurant_features is the opposite: it is the normalized,
-- per-place, refreshable cache (fetched_at) that both clients already read under
-- "restaurant_features readable by any authenticated user" (0002), and both of them select
-- explicit column lists, so one more column changes no existing decode.
--
-- jsonb, and the elements stored VERBATIM. An attribution is a credit line whose exact wording
-- and markup belong to its provider: Places (New) documents per-place attributions as objects
-- carrying a provider name and a provider URI, while the same concept has historically arrived
-- as HTML-ish strings. Storing them as text[] would force either rewriting an object into an
-- anchor tag we invented or dropping it, and truncating a string would publish a MISattribution.
-- jsonb keeps whichever shape the provider sent, unaltered, and lets the display code decide how
-- to render each element. It is `not null default '[]'` so "nobody has recorded any" is an empty
-- array rather than a null the client has to special-case, and the CHECK keeps it an array so a
-- client can iterate it without a type test.
alter table public.restaurant_features
  add column if not exists provider_attributions jsonb not null default '[]'::jsonb;

-- drop-then-add keeps this re-runnable, matching 0016/0021/0022's guard rails.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_provider_attributions_array;
alter table public.restaurant_features
  add constraint restaurant_features_provider_attributions_array
  check (jsonb_typeof(provider_attributions) = 'array');

-- The intended reader, stated where the column is defined. The select policy from 0002 already
-- covers every authenticated participant; this restates the table privilege so the new column's
-- reader is not left implicit. No grant to anon: both clients hold an authenticated session
-- (an anonymous sign-in is still the `authenticated` role), and provider content is not public.
grant select on table public.restaurant_features to authenticated;

-- ---------------------------------------------------------------------------
-- C2. The provider write path for provider_attributions
-- ---------------------------------------------------------------------------

-- Shape of each element: {"place_id": text, "attributions": jsonb[]}. Same present/absent
-- contract as the smoking writer, for the same reason and with the opposite default risk:
--   * key ABSENT (or not an array) → nothing learned, nothing written. A cached candidate whose
--     Places payload was not re-fetched this run keeps the credits it already has, so a run
--     that skipped discovery cannot blank the attributions the display is rendering.
--   * key PRESENT → it is Places' CURRENT answer for that place and it REPLACES the stored
--     array, including with '[]'. Attribution is an obligation attached to the content we are
--     showing: if the newest response no longer credits a provider, continuing to display that
--     credit is not caution, it is a false claim about where today's data came from.
-- Elements are stored verbatim. The only filtering is by JSON type: a string or an object can be
-- an attribution, whereas a number, a boolean, a JSON null or a nested array cannot be rendered
-- as a credit and would only reach the UI as junk. Nothing is truncated, escaped or rewritten —
-- an edited attribution is a misattribution.
create or replace function public.fn_record_provider_attributions(
  p_event_id uuid,
  p_candidates jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_candidate jsonb;
  v_place_id text;
  v_attributions jsonb;
  v_rows int;
  v_count int := 0;
  v_has_column boolean;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record provider attributions';
  end if;

  if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' then
    return 0;
  end if;

  if not exists (select 1 from public.events e where e.id = p_event_id) then
    raise exception 'event % not found', p_event_id;
  end if;

  -- The column is created above, so this guard is only about ordering robustness — the same
  -- dynamic-execute shape 0022 used, kept so the function body never hard-depends on a column
  -- some other deployment might not have yet.
  select exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'restaurant_features'
      and c.column_name = 'provider_attributions'
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
    if jsonb_typeof(v_candidate->'attributions') is distinct from 'array' then
      continue;
    end if;

    -- `with ordinality` so the credits keep the order the provider listed them in; jsonb_agg
    -- without an explicit ORDER BY is only incidentally ordered.
    select coalesce(jsonb_agg(e.value order by e.idx), '[]'::jsonb)
      into v_attributions
      from jsonb_array_elements(v_candidate->'attributions')
             with ordinality as e(value, idx)
     where jsonb_typeof(e.value) in ('string', 'object');

    execute 'update public.restaurant_features rf
                set provider_attributions = $2::jsonb
              where rf.place_id = $1'
      using v_place_id, v_attributions;
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end; $$;

-- ---------------------------------------------------------------------------
-- D. Privileges
-- ---------------------------------------------------------------------------

-- Same rule as 0009/0015/0016/0021/0022: these are implementation details of the provider
-- pipeline, which runs as service_role and is their only caller. A client that could call the
-- writers could certify a smoking policy or publish an attribution of its own choosing.
revoke execute on function public.fn_hotpepper_smoking_policy(text)
  from public, anon, authenticated;
revoke execute on function public.fn_record_provider_smoking_policy(uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_record_provider_attributions(uuid, jsonb)
  from public, anon, authenticated;

grant execute on function public.fn_hotpepper_smoking_policy(text) to service_role;
grant execute on function public.fn_record_provider_smoking_policy(uuid, jsonb) to service_role;
grant execute on function public.fn_record_provider_attributions(uuid, jsonb) to service_role;
