-- 0026_allergen_vocabulary_and_unverified_coverage.sql
-- The same shape of dead end 0022 removed for accessibility, in the one category where it is
-- worst: ALLERGY. Feasibility stays a deterministic decision procedure — no LLM, no vector
-- similarity — and the five-persona seed still produces exactly 0 feasible venues at baseline
-- and exactly demo_place_001/002/004 after Bob's room MUST is relaxed (asserted in
-- tests/backend_tests.sql rather than assumed).
--
--   A  AN ALLERGY MUST WAS UNSATISFIABLE THE MOMENT IT WAS WRITTEN IN JAPANESE. Verified
--      against the live model (openai/gpt-5.6-luna through OpenRouter), in the product's own
--      language, on the most safety-critical input the product has:
--        「えびとかにのアレルギーがあります」
--          -> {"normalized_type":"allergy","normalized_value":{"allergens":["えび","かに"]}}
--        「マンゴーアレルギー」
--          -> {"allergens":["マンゴー"]}
--        「卵と乳製品がだめです」
--          -> {"normalized_type":"dietary","normalized_value":{"tags":["egg-free","dairy-free"]}}
--      Venues store allergy_safe_tags = {shellfish_free} and the engine tests
--      `allergens || '_free' <@ allergy_safe_tags`, so it looked for 'えび_free' and matched
--      nothing, ever. Allergy is on the never-relax list with dietary and accessibility, so
--      there was no proposal to escape through either: ZERO CANDIDATES, PERMANENTLY, WITH NO
--      EXPLANATION — for the participant whose requirement is a medical one.
--      The root cause was in functions/llm-assist's SYSTEM_PROMPT: `allergy
--      {"allergens": string[]}` was the ONLY gating category with no example, so the model
--      mirrored the writer's language. dietary -> 'vegetarian' and atmosphere -> 'quiet' came
--      back English only because they had exemplars — luck, not a contract; and the third probe
--      above shows dietary failing in a second way, by inventing 'egg-free'/'dairy-free', which
--      no venue tag can ever match either. This file defines both vocabularies ONCE,
--      canonicalises Japanese and English synonyms onto them, constrains the venue side of the
--      allergen one to the same language, and canonicalises the rows written before it existed.
--      llm-assist states the closed lists in its prompt AND enforces them on the model's answer
--      server-side: the prompt is a hint, the server is the contract.
--
--   B  AND EVEN WITH A PERFECT VOCABULARY, NO PROVIDER CAN FILL allergy_safe_tags. This was
--      researched rather than assumed. Japan's 特定原材料 labelling obligation covers packaged
--      and processed food, NOT restaurant menus, so no structured per-restaurant allergen
--      dataset exists to buy or query. Hot Pepper returns 51 fields per shop and not one is
--      allergen-related (checked empirically against the live API). Google Places has none.
--      Gurunavi's API is corporate-only, Tabelog has no API at all. Yelp and HappyCow expose
--      *dietary* flags (vegan / gluten-free), not allergens, with thin Japan coverage. The
--      Japanese allergy apps people actually use (allergy connect, CAN EAT) publish no API.
--      So allergy_safe_tags is hand-authored fixture data: every provider-discovered venue
--      arrives with '{}', the branch fails closed — correctly, PRD §11 "unknown ≠ supported" —
--      and the group is shown 「0件」 with no reason. Fixing only the vocabulary moves the
--      participant between two impossible states.
--      That is README punch list item B4 ("add a needs-confirmation evidence tier for live
--      provider data whose dietary/allergy attributes are not verified"), and 0022 already
--      solved this exact shape for accessibility. fn_recompute_feasibility therefore gains ONE
--      key, `allergy_unverified_count`, built exactly like 0022's
--      accessibility_unverified_count: the candidates whose ONLY unmet MUSTs are allergy ones —
--      the venues that would be on the shortlist if somebody phoned them. Every existing key
--      keeps its name and its meaning; the web and Swift clients decode this payload.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO. It does not add a relaxation step for allergy and it
-- does not weaken the predicate. 0021 can offer 「禁煙が確認できていないお店も候補に入れてよいで
-- すか？」 because the cost of being wrong about a smoking policy is disappointment; 0022
-- refused the equivalent for accessibility because the cost is not getting in. Allergy is the
-- far end of that scale: asking somebody to consent to an unverified allergen claim is asking
-- them to accept a medical risk on the strength of data we have just documented does not exist.
-- The honest escape is exactly the one 0022 chose — report the coverage, and phone the venue
-- (verification_requirement is already 'required' for every allergy MUST, 0018) — never
-- consent. Allergy stays on fn_propose_relaxation's never-relax list and fn_relaxed_value is
-- left untouched.
--
-- Everything is additive and re-runnable: the one new constraint is drop-then-add, the two data
-- normalizations only touch rows that would otherwise be unsatisfiable, and every function is
-- create-or-replace.

-- ---------------------------------------------------------------------------
-- A1. The vocabularies, defined once
-- ---------------------------------------------------------------------------

-- The CLOSED allergen vocabulary. Six members, and they are not invented here: they are the
-- terms this codebase already speaks — allergenLabel() in web/src/design/copy.ts,
-- AppCopy.allergen in AIKanji/AIKanji/DesignSystem/AppCopy.swift and ALLERGEN_WORDS in
-- web/src/backend/mock.ts all enumerate exactly these, and seed.sql's venue side stores
-- 'shellfish_free'. Every one of them also has a Japanese label already written, which is why a
-- fully Japanese UI can print a canonical English tag without a translation being guessed:
--   shellfish  甲殻類      egg      卵        milk       乳
--   peanut     落花生      wheat    小麦      buckwheat  そば
-- Five of the six are 消費者庁の特定原材料 (卵・乳・小麦・そば・落花生) and the sixth covers the
-- other two (えび・かに) as one crustacean tag, because that is the granularity the venue side
-- has ever recorded. That is the whole justification for the list being closed at six: a
-- seventh member could never be matched by any recorded tag, and an allergy MUST is never
-- relaxable, so storing one would mean zero candidates forever (bug A).
--
-- Sorted, like fn_accessibility_vocabulary(), so callers can compare against a literal.
-- The same six strings are stated in functions/llm-assist/index.ts (in the prompt AND enforced
-- on the model's answer server-side), mirrored in web/src/backend/engine.ts and
-- web/src/backend/mock.ts, and constrained on the venue side by
-- restaurant_features_allergen_safe_tag_vocabulary below.
create or replace function public.fn_allergen_vocabulary()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array[
    'buckwheat',
    'egg',
    'milk',
    'peanut',
    'shellfish',
    'wheat'
  ]::text[];
$$;

-- The CLOSED dietary vocabulary — the same bug, one category over, and a live probe already
-- shows the model inventing members ('egg-free', 'dairy-free'). Four members, read off
-- DIETARY_WORDS in web/src/backend/mock.ts, dietaryLabel() in web/src/design/copy.ts and the
-- 'vegetarian' tag seed.sql stores on venues. Unlike the allergen list this one is a set of
-- *patterns a venue can claim to cater for* rather than ingredients, which is why 'gluten_free'
-- belongs here and not in the allergen vocabulary: 小麦 is the 特定原材料, グルテンフリー is the
-- kitchen's menu claim.
create or replace function public.fn_dietary_vocabulary()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array[
    'gluten_free',
    'halal',
    'vegan',
    'vegetarian'
  ]::text[];
$$;

-- ---------------------------------------------------------------------------
-- A2. Canonicalisation — the only place a value is ever translated
-- ---------------------------------------------------------------------------

-- Shared spelling normalization, applied before any lookup so the alias tables below stay a
-- list of *words* instead of a list of typographies: case-folded, and space / ideographic space
-- / ASCII hyphen / fullwidth hyphen / U+2010 hyphen all folded to '_', so 'gluten free',
-- 'Gluten-Free' and 'gluten_free' are one token. lower() is a no-op on Japanese, which is
-- exactly what we want — nothing about kana or kanji is rewritten here, and the katakana
-- prolonged sound mark 'ー' is deliberately NOT in the fold set: it is a letter in ピーナッツ and
-- ミルク, not punctuation.
create or replace function public.fn_taxonomy_token(p_raw text)
returns text language sql immutable security definer set search_path = '' as $$
  select nullif(
    pg_catalog.btrim(
      pg_catalog.translate(pg_catalog.lower(coalesce(p_raw, '')), ' 　-－‐', '_____')),
    '');
$$;

-- One allergen word -> one vocabulary member, or NULL when the vocabulary cannot express it.
--
-- WHY THESE ALIASES AND NOT MORE. Each one names the SAME ingredient as its canonical member,
-- so mapping it preserves the requirement exactly and invents nothing:
--   shellfish  えび/エビ/海老/かに/カニ/蟹/甲殻類 — the two crustaceans 特定原材料 lists, plus
--              the collective noun, plus the English the model emits for them.
--   egg        卵/たまご/タマゴ/玉子/鶏卵.
--   milk       乳/牛乳/ミルク/乳製品/乳成分/チーズ/バター — 乳 is the 特定原材料 and the others
--              are the forms it reaches a menu in.
--   peanut     落花生/ピーナッツ/ピーナツ.
--   wheat      小麦/こむぎ/コムギ/小麦粉.
--   buckwheat  そば/蕎麦/ソバ/そば粉.
-- A trailing '_free' is stripped first, so a model (or a stale client) that echoes the venue
-- side's 'shellfish_free' into the constraint's allergens array still lands on 'shellfish'
-- rather than being dropped.
--
-- WHAT IS DELIBERATELY *NOT* MAPPED, because a wrong mapping here is a health risk and is worse
-- than admitting we cannot express the requirement:
--   貝 / 貝類 / あさり / 牡蠣  molluscs. 'shellfish' is this schema's CRUSTACEAN tag (甲殻類;
--        see allergenLabel() in copy.ts), and a venue that has confirmed itself
--        shellfish_free has said nothing whatsoever about oysters. Folding molluscs in would
--        silently record a weaker requirement than the participant stated.
--   グルテン  belongs to the dietary vocabulary as 'gluten_free'. Rewriting it to 'wheat'
--        would answer a coeliac requirement with a 特定原材料 label that does not cover
--        barley or rye.
--   大豆 / ナッツ / 魚 / マンゴー … real allergens with no member and no venue tag. They are
--        never approximated and never dropped in silence: llm-assist keeps the participant's
--        own wording in semantic_remainder and forces needs_clarification, and the backfill in
--        section C does the same for a row written before this file existed.
-- A values-list lookup rather than a chain of `when`s so the table reads as data, and `limit 1`
-- so a duplicated alias can never turn this into a set-returning surprise.
create or replace function public.fn_allergen_canonical(p_raw text)
returns text language sql immutable security definer set search_path = '' as $$
  select m.canonical
  from (values
    ('shellfish', 'shellfish'),
    ('えび', 'shellfish'), ('エビ', 'shellfish'), ('海老', 'shellfish'),
    ('かに', 'shellfish'), ('カニ', 'shellfish'), ('蟹', 'shellfish'),
    ('甲殻類', 'shellfish'), ('甲殻', 'shellfish'),
    ('shrimp', 'shellfish'), ('prawn', 'shellfish'), ('crab', 'shellfish'),
    ('crustacean', 'shellfish'), ('crustaceans', 'shellfish'),
    ('egg', 'egg'), ('eggs', 'egg'),
    ('卵', 'egg'), ('たまご', 'egg'), ('タマゴ', 'egg'), ('玉子', 'egg'), ('鶏卵', 'egg'),
    ('milk', 'milk'), ('dairy', 'milk'),
    ('乳', 'milk'), ('牛乳', 'milk'), ('ミルク', 'milk'), ('乳製品', 'milk'),
    ('乳成分', 'milk'), ('チーズ', 'milk'), ('バター', 'milk'),
    ('peanut', 'peanut'), ('peanuts', 'peanut'),
    ('落花生', 'peanut'), ('ピーナッツ', 'peanut'), ('ピーナツ', 'peanut'),
    ('wheat', 'wheat'),
    ('小麦', 'wheat'), ('こむぎ', 'wheat'), ('コムギ', 'wheat'), ('小麦粉', 'wheat'),
    ('buckwheat', 'buckwheat'), ('soba', 'buckwheat'),
    ('そば', 'buckwheat'), ('蕎麦', 'buckwheat'), ('ソバ', 'buckwheat'), ('そば粉', 'buckwheat')
  ) as m(alias, canonical)
  where m.alias = pg_catalog.regexp_replace(
    coalesce(public.fn_taxonomy_token(p_raw), ''), '_?free$', '')
  limit 1;
$$;

-- One dietary word -> one vocabulary member, or NULL. Same rule: every alias names the same
-- pattern as its member (菜食 IS vegetarian; ハラール IS halal; グルテンフリー IS gluten_free).
-- Nothing about an ingredient is mapped here — 'egg-free' and 'dairy-free', which the live model
-- produced for 「卵と乳製品がだめです」, are ALLERGENS wearing a dietary shape and have no member
-- in this list. They are dropped and flagged rather than guessed at, and llm-assist's prompt now
-- routes ingredient-level exclusions to `allergy` where they belong.
create or replace function public.fn_dietary_canonical(p_raw text)
returns text language sql immutable security definer set search_path = '' as $$
  select m.canonical
  from (values
    ('vegan', 'vegan'),
    ('ヴィーガン', 'vegan'), ('ビーガン', 'vegan'), ('完全菜食', 'vegan'),
    ('vegetarian', 'vegetarian'), ('veggie', 'vegetarian'),
    ('ベジタリアン', 'vegetarian'), ('菜食', 'vegetarian'), ('菜食主義', 'vegetarian'),
    ('halal', 'halal'),
    ('ハラル', 'halal'), ('ハラール', 'halal'),
    ('gluten_free', 'gluten_free'), ('glutenfree', 'gluten_free'),
    ('グルテンフリー', 'gluten_free'), ('グルテン', 'gluten_free')
  ) as m(alias, canonical)
  where m.alias = public.fn_taxonomy_token(p_raw)
  limit 1;
$$;

-- Canonicalises a whole allergen list: maps what it can, DROPS what it cannot, dedupes, sorts.
-- Dropping is never silent — see the note in fn_allergen_canonical and section C — but it is
-- the only safe thing to do to the stored value: feasibility is exact array containment and an
-- allergy MUST is never relaxable, so one unmatchable member means zero candidates forever with
-- no way out, which is bug A.
create or replace function public.fn_allergen_canonical_allergens(p_allergens text[])
returns text[] language sql immutable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.canonical order by m.canonical), '{}'::text[])
  from (
    select public.fn_allergen_canonical(a.raw) as canonical
    from pg_catalog.unnest(coalesce(p_allergens, '{}'::text[])) as a(raw)
  ) m
  where m.canonical is not null;
$$;

create or replace function public.fn_dietary_canonical_tags(p_tags text[])
returns text[] language sql immutable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.canonical order by m.canonical), '{}'::text[])
  from (
    select public.fn_dietary_canonical(t.raw) as canonical
    from pg_catalog.unnest(coalesce(p_tags, '{}'::text[])) as t(raw)
  ) m
  where m.canonical is not null;
$$;

-- The same operation on a constraint's normalized_value. A missing or non-array key yields an
-- empty array, which the callers below read as "the taxonomy expresses none of this" — exactly
-- how fn_accessibility_canonical_needs treats an unreadable `needs`.
create or replace function public.fn_allergen_canonical_value(p_value jsonb)
returns text[] language sql immutable security definer set search_path = '' as $$
  select public.fn_allergen_canonical_allergens(
    case when jsonb_typeof(p_value->'allergens') = 'array'
      then array(select jsonb_array_elements_text(p_value->'allergens'))
      else '{}'::text[] end);
$$;

create or replace function public.fn_dietary_canonical_value(p_value jsonb)
returns text[] language sql immutable security definer set search_path = '' as $$
  select public.fn_dietary_canonical_tags(
    case when jsonb_typeof(p_value->'tags') = 'array'
      then array(select jsonb_array_elements_text(p_value->'tags'))
      else '{}'::text[] end);
$$;

-- ---------------------------------------------------------------------------
-- A3. The allergen vocabulary, enforced on the venue side
-- ---------------------------------------------------------------------------

-- The venue side speaks the same vocabulary with a suffix: restaurant_features.allergy_safe_tags
-- holds '<allergen>_free', a POSITIVE claim that this kitchen can serve a guest without that
-- ingredient. Derived from fn_allergen_vocabulary() rather than written out again, so the two
-- sides cannot drift by one member.
--
-- Note what the suffix means, because the coverage count in section E depends on it: nothing in
-- this schema can ever record that a venue DOES serve an allergen. A missing member therefore
-- means UNCONFIRMED and never confirmed-present — which is why the honest word for a venue that
-- fails an allergy MUST is *unverified*, and why phoning it is a real remedy.
create or replace function public.fn_allergen_safe_tag_vocabulary()
returns text[] language sql immutable security definer set search_path = '' as $$
  select array(
    select a || '_free'
    from pg_catalog.unnest(public.fn_allergen_vocabulary()) as a
    order by 1);
$$;

-- Canonicalises recorded venue tags onto that language: 'えび_free' becomes 'shellfish_free',
-- 'shellfish_free' is untouched, and anything unmappable ('barrier_free', 'vegan', 貝_free) is
-- dropped. Dropping a venue tag is the FAIL-CLOSED direction — the venue simply stops claiming
-- something we cannot interpret — which is the opposite of dropping a participant's allergen and
-- is why this one needs no clarification flow.
create or replace function public.fn_allergen_canonical_safe_tags(p_tags text[])
returns text[] language sql immutable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct m.canonical || '_free' order by m.canonical || '_free'),
                  '{}'::text[])
  from (
    select public.fn_allergen_canonical(t.tag) as canonical
    from pg_catalog.unnest(coalesce(p_tags, '{}'::text[])) as t(tag)
  ) m
  where m.canonical is not null;
$$;

-- Existing rows first, so the constraint is validated against data that already satisfies it.
-- In this repo that is seed.sql's four 'shellfish_free' rows (already canonical, so a no-op),
-- but a live project can hold hand-written tags — this column has never had a provider writer.
update public.restaurant_features rf
   set allergy_safe_tags = public.fn_allergen_canonical_safe_tags(rf.allergy_safe_tags)
 where rf.allergy_safe_tags is distinct from
       public.fn_allergen_canonical_safe_tags(rf.allergy_safe_tags);

-- drop-then-add keeps this re-runnable, matching 0016/0021/0022's guard rails. The member list
-- is written out rather than read from fn_allergen_safe_tag_vocabulary() for the reason 0022
-- gives: a CHECK that calls a function is restored before that function exists by
-- pg_dump/pg_restore, and it would silently stop validating if the function were ever replaced.
-- tests/backend_tests.sql asserts the two agree by inserting the function's own output.
--
-- WHY THIS CAN BE CONSTRAINED WHEN dietary_tags CANNOT. '<allergen>_free' is this repo's own
-- invention: no provider emits it (section B above — none has allergen data at all), and
-- restaurant-search hard-codes `allergy_safe_tags: []` for every candidate, which 0017's
-- upsert then skips because an empty incoming array never overwrites. So the only writer this
-- column has ever had is a human, and a CHECK here can only ever catch a typo. dietary_tags is
-- the opposite: 0017 forwards whatever the pipeline sends, the test suite uses scratch tags as
-- per-event pool gates, and a venue-side dietary label space cannot be enumerated with
-- confidence — constraining it would abort an entire restaurant search over one unexpected
-- string, which is a worse failure than the one it would prevent.
--
-- `<@` is array containment, so '{}' (no data recorded — every live venue) passes, and a NULL
-- element fails.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_allergen_safe_tag_vocabulary;
alter table public.restaurant_features
  add constraint restaurant_features_allergen_safe_tag_vocabulary
  check (allergy_safe_tags is null or allergy_safe_tags <@ array[
    'buckwheat_free',
    'egg_free',
    'milk_free',
    'peanut_free',
    'shellfish_free',
    'wheat_free'
  ]::text[]);

-- ---------------------------------------------------------------------------
-- C. The vocabularies, applied to rows written before they existed
-- ---------------------------------------------------------------------------

-- A live event can hold {"allergens":["えび","かに"]} or {"tags":["egg-free"]} — the two live
-- probes at the top of this file. Left alone they are bug A for exactly the participants this
-- file protects: no recorded tag can ever match them and neither MUST is relaxable. They are
-- canonicalised here, once, the way 0012 canonicalised the pre-taxonomy shapes and 0022
-- canonicalised `needs`.
--
--   * members that map onto the vocabulary are rewritten to it;
--   * members that do not are dropped from the value and NOT forgotten: the row keeps the
--     participant's own raw_text in semantic_remainder (0018 created that column for exactly
--     this, and P1 semantic matching reads it);
--   * a row where NOTHING survives keeps normalized_type = 'allergy' (or 'dietary') and an
--     empty list.
--
-- THE ASYMMETRY WITH 0022, STATED EXPLICITLY BECAUSE IT LOOKS LIKE AN INCONSISTENCY. 0022's
-- backfill re-typed an accessibility row it could not express to `other`, a non-gating note:
-- for 「エレベーターがある店」 the engine genuinely cannot check anything, and a human 幹事 acting
-- on a note is more honest than a MUST that excludes all of Tokyo. That reasoning MUST NOT be
-- copied here. Turning 「マンゴーアレルギー」 into a note would drop a medical requirement out of
-- the gate entirely and let the group be recommended a venue nobody has checked — the worst
-- possible failure in this dimension. So an allergy row stays an allergy row: gating,
-- highly_sensitive, verification_requirement 'required', fail-closed. What changes is that the
-- resulting zero is no longer silent — section E counts those candidates as *unverified*, which
-- is exactly what they are, and the participant's own word survives in semantic_remainder for
-- the phone call that is the real remedy. dietary is treated identically: it is on the same
-- safety list, for the same reason.
--
-- Re-running is a no-op: canonical rows produce an identical value. Classifying old rows is
-- bookkeeping, not a participant edit, so the user triggers are held down exactly as in 0018's
-- and 0022's backfills — it must not bump updated_at and must not broadcast
-- `constraint_updated` to a group that changed nothing.
alter table public.participant_constraints disable trigger user;
with canonical as (
  select pc.id,
         pc.semantic_remainder,
         pc.raw_text,
         pc.normalized_value as before_value,
         case pc.normalized_type
           when 'allergy' then jsonb_build_object('allergens',
             to_jsonb(public.fn_allergen_canonical_value(pc.normalized_value)))
           when 'dietary' then jsonb_build_object('tags',
             to_jsonb(public.fn_dietary_canonical_value(pc.normalized_value)))
           else pc.normalized_value
         end as after_value
  from public.participant_constraints pc
  where pc.normalized_type in ('allergy', 'dietary')
)
update public.participant_constraints pc
   set normalized_value = c.after_value,
       semantic_remainder =
         coalesce(c.semantic_remainder, nullif(pg_catalog.btrim(c.raw_text), ''))
  from canonical c
 where pc.id = c.id
   and c.after_value is distinct from c.before_value;
alter table public.participant_constraints enable trigger user;

-- ---------------------------------------------------------------------------
-- D. Feasibility, factored so "why was this venue excluded?" is answerable
-- ---------------------------------------------------------------------------

-- The allergy predicate, in one place, mirroring what 0022 did for accessibility: the gate and
-- the coverage count read the same rule, so they cannot disagree about what "unmet" means.
--
-- Unchanged from 0009/0016/0021/0022 in every respect — this is that expression moved, not
-- edited. `allergens` must be a non-empty array (a MUST whose own value cannot be read is not
-- one we may certify as met), the venue must have tags recorded, and those tags must CONTAIN
-- '<allergen>_free' for every allergen. No tags recorded means UNKNOWN, and unknown is not safe.
create or replace function public.fn_allergy_allergens_met(
  p_venue_tags text[], p_value jsonb
) returns boolean language sql immutable security definer set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_value->'allergens') = 'array'
    and coalesce(jsonb_array_length(p_value->'allergens'), 0) > 0
    and coalesce(array_length(p_venue_tags, 1), 0) > 0
    and p_venue_tags @> array(
      select allergen || '_free'
      from jsonb_array_elements_text(p_value->'allergens') as allergen),
    false);
$$;

-- Which MUST TYPES stand between this event and this venue — '{}' meaning "feasible".
--
-- Re-declared from 0022 with ONE change: the allergy branch now calls
-- fn_allergy_allergens_met instead of inlining the same expression. Every other branch,
-- including the ordering of the if/elsif chain and the dedupe/sort of the result, is 0022's
-- text verbatim. Nothing is relaxed, widened or made more permissive anywhere in this file.
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
    -- normalized_value is {"tags": string[]} drawn from fn_dietary_vocabulary() since 0026.
    -- Fail-closed and never relaxable, exactly as before.
    elsif v_must.normalized_type = 'dietary' then
      if jsonb_typeof(v_value->'tags') is distinct from 'array'
        or coalesce(jsonb_array_length(v_value->'tags'), 0) = 0
        or coalesce(array_length(v_candidate.dietary_tags, 1), 0) = 0
        or not (v_candidate.dietary_tags @> array(
          select jsonb_array_elements_text(v_value->'tags')))
      then v_blocked := v_blocked || 'dietary'::text; end if;
    -- normalized_value is {"allergens": string[]} drawn from fn_allergen_vocabulary(), which
    -- llm-assist states in its prompt and enforces on the model's answer. Never relaxable and
    -- never granted an accept_unknown flag: 0021 may ask a group to accept an unconfirmed
    -- smoking policy, but nobody may be asked to accept an unverified allergen claim. The only
    -- way a venue passes is recorded '<allergen>_free' data that covers every allergen; section
    -- E reports how many candidates fail for the lack of it.
    elsif v_must.normalized_type = 'allergy' then
      if not public.fn_allergy_allergens_met(v_candidate.allergy_safe_tags, v_value)
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

-- ---------------------------------------------------------------------------
-- E. Allergy coverage in the recompute payload
-- ---------------------------------------------------------------------------

-- Re-declared from 0022 with ONE new key, `allergy_unverified_count`, and one more branch in
-- the loop that produces it. Every existing key — run_id, feasible_count,
-- accessibility_unverified_count — keeps its name and its exact meaning: the web and Swift
-- clients decode this payload, so adding a key is the only backwards-compatible way to say
-- something new. The recommendation_runs insert, the scoring call and 0018's lifecycle refresh
-- are unchanged.
--
-- allergy_unverified_count is the number of candidates whose ONLY unmet MUSTs are allergy ones:
-- venues that would be on the shortlist if somebody could confirm what they serve. It is the
-- honest, actionable number behind 「N件はアレルギー対応が確認できませんでした（お店に確認できま
-- す）」, and it is the reason a participant with a shellfish allergy is not simply shown 「0件」.
--
-- WHY "UNVERIFIED" IS THE ACCURATE WORD, not a euphemism for "unsuitable". allergy_safe_tags
-- only ever records POSITIVE claims ('<allergen>_free'); no column anywhere in this schema can
-- say that a venue DOES serve an allergen. So an unmet allergy MUST is always missing evidence
-- and never a contradicted fact — the data is absent, not opposed — which is precisely what
-- makes a phone call a real remedy, and it is the same argument 0022 makes for accessibility.
-- Section B is why absence is the normal case rather than an edge one: no provider on earth
-- supplies restaurant allergen data, so every live candidate arrives with '{}'.
--
-- Like 0022's count it is deliberately NOT "every venue that fails an allergy MUST": a venue
-- that also breaks somebody's budget would not become available by a phone call, so counting it
-- would invite a false conclusion. And it is 0 unless somebody stated an allergy MUST, so
-- nothing changes for events that did not — including the five-persona demo, where Emma's
-- shellfish MUST is met by every seeded venue and the 0-then-3 invariant is untouched.
--
-- One case worth naming, because it is the whole point of counting rather than dropping: a MUST
-- this file could not express — 「マンゴーアレルギー」, canonicalised to {"allergens":[]} in
-- section C — fails every venue, so every candidate is reported here. That reads as 「どのお店も
-- アレルギー対応を確認できていません」, which for a mango allergy is simply TRUE: no dataset in
-- the world has that flag, and every venue must be asked. The alternative, which this file
-- refuses, is the silent 「0件」 the participant used to get.
create or replace function public.fn_recompute_feasibility(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run_id uuid; v_feasible_count int := 0; v_unverified_count int := 0;
  v_allergy_unverified_count int := 0;
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
    elsif v_blocked = array['allergy']::text[] then
      v_allergy_unverified_count := v_allergy_unverified_count + 1;
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
    'accessibility_unverified_count', v_unverified_count,
    'allergy_unverified_count', v_allergy_unverified_count);
end; $$;

-- ---------------------------------------------------------------------------
-- F. Privileges
-- ---------------------------------------------------------------------------

-- Same rule as 0009/0016/0021/0022: these are implementation details of the guarded RPCs. A
-- client that can call fn_candidate_blocking_types gets a cross-event feasibility oracle, and
-- one that can call the vocabulary helpers learns nothing it needs. `create or replace` keeps
-- existing grants, so only the new functions strictly need this — fn_candidate_blocking_types
-- is restated so the privilege story lives next to the definition.
revoke execute on function public.fn_allergen_vocabulary() from public, anon, authenticated;
revoke execute on function public.fn_dietary_vocabulary() from public, anon, authenticated;
revoke execute on function public.fn_taxonomy_token(text) from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical(text) from public, anon, authenticated;
revoke execute on function public.fn_dietary_canonical(text) from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_allergens(text[])
  from public, anon, authenticated;
revoke execute on function public.fn_dietary_canonical_tags(text[])
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_value(jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_dietary_canonical_value(jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_safe_tag_vocabulary()
  from public, anon, authenticated;
revoke execute on function public.fn_allergen_canonical_safe_tags(text[])
  from public, anon, authenticated;
revoke execute on function public.fn_allergy_allergens_met(text[], jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_candidate_blocking_types(uuid, text, uuid, jsonb)
  from public, anon, authenticated;

grant execute on function public.fn_allergen_vocabulary() to service_role;
grant execute on function public.fn_dietary_vocabulary() to service_role;
grant execute on function public.fn_taxonomy_token(text) to service_role;
grant execute on function public.fn_allergen_canonical(text) to service_role;
grant execute on function public.fn_dietary_canonical(text) to service_role;
grant execute on function public.fn_allergen_canonical_allergens(text[]) to service_role;
grant execute on function public.fn_dietary_canonical_tags(text[]) to service_role;
grant execute on function public.fn_allergen_canonical_value(jsonb) to service_role;
grant execute on function public.fn_dietary_canonical_value(jsonb) to service_role;
grant execute on function public.fn_allergen_safe_tag_vocabulary() to service_role;
grant execute on function public.fn_allergen_canonical_safe_tags(text[]) to service_role;
grant execute on function public.fn_allergy_allergens_met(text[], jsonb) to service_role;
grant execute on function public.fn_candidate_blocking_types(uuid, text, uuid, jsonb)
  to service_role;

-- fn_recompute_feasibility stays a client RPC: it is guarded by the membership check above.
revoke execute on function public.fn_recompute_feasibility(uuid) from public, anon;
grant execute on function public.fn_recompute_feasibility(uuid) to authenticated, service_role;
