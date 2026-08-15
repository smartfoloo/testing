-- 0028_provider_display_fields_and_quality_percentiles.sql
-- Two more fields off pages we already fetch, and the change 0027 said it was deferring:
-- Tabelog finally counts toward quality, without either provider's scale being mistaken for
-- the other's.
--
-- ============================================================================================
-- THE TABELOG POSITION IS UNCHANGED AND STILL APPLIES IN FULL.
--
--   * TABELOG HAS NO PUBLIC API. Kakaku.com (カカクコム) publishes none, so the writer of the
--     tabelog_* columns is an HTML SCRAPER (functions/restaurant-search/index.ts,
--     tabelogResolve).
--   * TABELOG'S TERMS OF USE PROHIBIT REPRODUCING ITS CONTENT WITHOUT PRIOR WRITTEN CONSENT
--     and bar commercial use. We do not have that consent. This exists for a NON-COMMERCIAL
--     HACKATHON DEMO and for nothing else.
--   * THE WRITE PATH IS FEATURE-FLAGGED (TABELOG_ENRICHMENT_ENABLED), and the flag now
--     DEFAULTS TO ON: only the exact string "false" disables it. That default was flipped
--     deliberately — a demo that collects this data should use it — and it means a live search
--     fills these columns without anybody opting in.
--   * NO REVIEW TEXT IS TAKEN, EVER. There is still no column for it, no page fetched that
--     carries only reviews, and the cache row is still an extracted-scalar object.
--   * THE LEGITIMATE ROUTE IS A PARTNER AGREEMENT WITH KAKAKU.COM.
--
-- THE ONE THING THAT CHANGES: the dinner budget band comes off THE VENUE PAGE WE ALREADY
-- DOWNLOAD, in the same parse, for ZERO additional requests. Every politeness limit in
-- restaurant-search/index.ts is untouched — same five-venue cap, same >=2 s gap, same 15-request
-- ceiling, same 24 h cache — because this migration adds a field to a page, not a page.
-- ============================================================================================
--
-- What this migration adds, in order:
--
--   A  restaurant_features.tabelog_budget_yen — the UPPER bound of Tabelog's DINNER budget
--      band, stored beside Google/Hot Pepper's price_yen_estimate and never merged into it.
--   B  restaurant_features.photo_url — Hot Pepper's photo.pc.m thumbnail, a sanctioned API
--      field on Recruit's own image host, constrained so it can hold nothing else.
--   C  fn_record_tabelog_enrichment gains budget_yen, on 0027's exact present/absent contract.
--   D  fn_record_provider_photo, the photo_url writer, modelled on 0023's two writers.
--   E  Quality scoring: Tabelog now counts, as a PERCENTILE WITHIN ITS OWN PROVIDER'S
--      CANDIDATE POOL rather than as a number averaged with Google's. This is the change
--      0027's header named and deferred.
--   F  privileges.
--
-- WHAT THIS MIGRATION STILL DOES NOT DO, and 0027's reasoning for it is unchanged:
--   * NOTHING TABELOG SUPPLIES GATES ANYTHING. fn_candidate_blocking_types /
--     fn_candidate_is_feasible (0022/0016) are not touched by this file. In particular
--     tabelog_budget_yen is NOT read by the budget MUST branch and is NOT read by
--     fn_cost_burden: price_yen_estimate is Google's priceRange or Hot Pepper's 予算 band, both
--     of which we hold under terms that permit it, and a MUST somebody's wallet depends on
--     must not start being decided by a scraped figure. tabelog_budget_yen is display data with
--     a documented provenance, exactly as tabelog_rating was before this file.
--   * TABELOG NEVER TOUCHES GOOGLE'S COLUMNS. `rating` / `user_rating_count` remain Google's;
--     the blend below reads the two providers' columns SEPARATELY and never writes either.
--
-- Everything is additive and re-runnable: columns are `add column if not exists`, constraints
-- are drop-then-add (0016/0021/0022/0023/0027's guard rails), every function is
-- create-or-replace, and grants/revokes are absolute rather than additive.

-- ---------------------------------------------------------------------------
-- A. Tabelog's dinner budget band
-- ---------------------------------------------------------------------------

-- WHY DINNER, AND ONLY DINNER. A Tabelog venue page publishes two budget bands, 昼 and 夜, and
-- this app plans 飲み会 — the group eats dinner. A lunch band is a number about a meal nobody
-- in this product is having, so reading it would be storing a figure no decision here can use,
-- and mixing the two would silently answer a dinner question with a lunch price (they differ by
-- a factor of three on the venues sampled). The parser therefore anchors on
-- `c-rating-v3__time--dinner` and refuses to cross into the `--lunch` block.
--
-- WHY THE UPPER BOUND. The band is a range (￥8,000～￥9,999) and a budget MUST asks 「max_yen」,
-- so the only honest reduction of a range to one number is its TOP: for a venue observed at
-- ￥8,000～￥9,999 the answer to 「is it under ￥9,000?」 is NO. This is the same rule
-- placesPriceYen already applies to Google's `priceRange` and hotPepperBudgetYen to Hot
-- Pepper's 「3001〜4000円」 — rounding toward the cheaper end would quietly promise somebody a
-- bill they never agreed to.
--
-- WHY NULL AND NEVER 0. Tabelog prints 「-」 for a venue with no dinner band at all (a
-- lunch-only ramen shop, one of the five venues the selector was validated against). NULL is
-- "we do not know what dinner costs here", which 0021 already handles — a NULL price fails a
-- budget MUST closed and is reported as coverage. A 0 would say the venue is FREE, which is the
-- one reading that is both wrong and flattering.
alter table public.restaurant_features
  add column if not exists tabelog_budget_yen int;

-- Guard rail in 0016's shape (its `rating` / `user_rating_count` CHECKs, and 0027's on the
-- Tabelog score). A yen figure of 0 or below is not a cheap venue, it is a parser that matched
-- something that was not a price — 「-」, a review count, a page furniture number — and it must
-- not reach a card. drop-then-add keeps this re-runnable.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_tabelog_budget_yen_positive;
alter table public.restaurant_features
  add constraint restaurant_features_tabelog_budget_yen_positive
  check (tabelog_budget_yen is null or tabelog_budget_yen > 0);

-- ---------------------------------------------------------------------------
-- B. Hot Pepper's photograph
-- ---------------------------------------------------------------------------

-- WHERE IT COMES FROM AND WHY IT COSTS NOTHING. Recruit's Gourmet Search response already
-- carries `photo.pc.{l,m,s}` for every matched shop — the request sets no `lite` parameter, so
-- the full shop object arrives, exactly as `non_smoking` did before 0023 declared it. `pc.m`
-- (168x168, ~40 KB) is the one stored: `l` is 238x238 and `s` is a 58x58 avatar, and a
-- shortlist card shows a thumbnail.
--
-- WHY THIS IS NOT A NEW OBLIGATION. This is a sanctioned API field supplied for display by a
-- provider we already credit (0023 records provider_attributions and the shortlist prints
-- Recruit's credit), and the image stays on Recruit's own host — we store a URL, never a copy.
--
-- WHAT MAY NOT GO IN THIS COLUMN, enforced rather than promised:
--   * NOT a Google Places photo. Places photos are a separate paid SKU with their own
--     per-image attribution requirements, and we do not request the `photos` field at all.
--   * NEVER a Tabelog image. Tabelog's photo pages are on the scraper's OWN disallow list
--     (TABELOG_SELF_DISALLOW: dtlphotolst), the images are user-submitted and not Tabelog's to
--     license, and its terms forbid reproducing its content. A Tabelog image URL in a client's
--     <img src> would be exactly the reproduction we have decided never to perform.
-- The CHECK below is what makes those three sentences true no matter what any future writer
-- believes: only https, only Recruit's own image host (imgfp.hotp.jp today, hence the
-- subdomain wildcard), no whitespace, and a length a URL cannot honestly exceed. A
-- googleusercontent.com or a tabelog.com URL cannot be stored here at all.
alter table public.restaurant_features
  add column if not exists photo_url text;

alter table public.restaurant_features
  drop constraint if exists restaurant_features_photo_url_recruit_https;
alter table public.restaurant_features
  add constraint restaurant_features_photo_url_recruit_https
  check (
    photo_url is null
    or (photo_url ~ '^https://([a-z0-9-]+\.)*hotp\.jp/[^[:space:]]*$'
        and char_length(photo_url) <= 500)
  );

-- Re-stated, not fixed, for the same reason 0027 restated it: 0024 already grants SELECT on
-- this table to `authenticated` and a table-level grant covers columns added afterwards, so
-- both columns above are readable the moment they exist. photo_url in particular is read by a
-- client (web/src/backend/supabase.ts selects it), so the grant is written where the column is
-- defined rather than left to whichever default ACL the database happens to carry.
grant select on table public.restaurant_features to authenticated;

-- ---------------------------------------------------------------------------
-- C. The Tabelog write path, plus the budget
-- ---------------------------------------------------------------------------

-- Redeclared from 0027 with ONE addition: `budget_yen` inside the `tabelog` object. Element
-- shape is now {"place_id": text, "tabelog": {"tabelog_id": text, "rating": number,
-- "review_count": int, "budget_yen": int}}.
--
-- 0027's CONTRACT IS UNCHANGED, and the budget follows it exactly:
--   * `tabelog` key ABSENT (the common case: flag off, not shortlisted, no telephone number,
--     search found nothing, page printed a different number, budget spent) → nothing written,
--     nothing erased.
--   * `tabelog` key PRESENT → the identity was confirmed by an exact telephone match and every
--     figure in it is Tabelog's CURRENT answer, so all four columns are REPLACED — including
--     with NULL. For the budget that means a page now printing 「-」 clears a band we stored
--     last week, which is the whole point of a refreshable cache of a live figure: continuing
--     to show a price band the venue no longer publishes is a false claim about where today's
--     number came from.
-- A missing or unparseable `budget_yen` inside a PRESENT `tabelog` object therefore records
-- NULL, not "keep the old one": the band is read from the same page, in the same parse, as the
-- score, so if we resolved the venue we either know its dinner band or know it has none.
--
-- The regex is the CHECK in section A restated, so this path can never violate it: a value that
-- is not a plain positive integer of at most nine digits records NULL rather than failing the
-- whole search. Full-width digits are deliberately NOT accepted — 0027's tests already
-- established that 「４.２」 is not guessed at, and the same holds for 「８０００」.
create or replace function public.fn_record_tabelog_enrichment(
  p_event_id uuid,
  p_candidates jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_candidate jsonb;
  v_tabelog jsonb;
  v_place_id text;
  v_tabelog_id text;
  v_rating_text text;
  v_rating numeric;
  v_count_text text;
  v_review_count int;
  v_budget_text text;
  v_budget_yen int;
  v_rows int;
  v_count int := 0;
  v_has_column boolean;
begin
  -- Same request-context shape as 0017/0022/0023/0027: the service_role Edge Function client
  -- and direct SQL sessions (no JWT claims) are the admin/definer path. An API caller must
  -- never write provider data, and least of all this provider's — a client that could call
  -- this could attribute any Tabelog page, any score and any price band to any venue.
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record Tabelog enrichment';
  end if;

  if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' then
    return 0;
  end if;

  if not exists (select 1 from public.events e where e.id = p_event_id) then
    raise exception 'event % not found', p_event_id;
  end if;

  -- Both columns are probed, not just 0027's: the UPDATE below is a dynamic string naming all
  -- four, so the function must not claim to be able to run on a deployment that has only
  -- three. Same ordering-robustness shape 0022/0023/0027 used.
  select count(*) = 2 into v_has_column
    from information_schema.columns c
   where c.table_schema = 'public'
     and c.table_name = 'restaurant_features'
     and c.column_name in ('tabelog_id', 'tabelog_budget_yen');
  if not v_has_column then
    return 0;
  end if;

  for v_candidate in select value from jsonb_array_elements(p_candidates)
  loop
    v_place_id := nullif(v_candidate->>'place_id', '');
    if v_place_id is null then
      continue;
    end if;

    -- Absent, or present as anything other than a JSON object: this venue was not resolved on
    -- this run, so nothing is recorded and nothing is erased.
    v_tabelog := v_candidate->'tabelog';
    if jsonb_typeof(v_tabelog) is distinct from 'object' then
      continue;
    end if;

    -- The id IS the resolution. Without a well-formed one there is no identity to attach a
    -- score or a price band to, and a price band attached to the wrong venue is the same
    -- failure a wrong score is, so an unusable id discards the element entirely rather than
    -- writing the numbers on their own.
    v_tabelog_id := nullif(v_tabelog->>'tabelog_id', '');
    if v_tabelog_id is null or v_tabelog_id !~ '^[0-9]{6,10}$' then
      continue;
    end if;

    -- Cast only what is unambiguously a number in range; everything else is NULL, which is
    -- "Tabelog published no score", not "the score is zero". The regexes also mean sections A
    -- and 0027's B CHECKs can never be violated from here, so a parser that starts matching
    -- the wrong element cannot fail the search.
    v_rating_text := v_tabelog->>'rating';
    if v_rating_text ~ '^[0-9]+(\.[0-9]+)?$'
       and v_rating_text::numeric >= 0 and v_rating_text::numeric <= 5
    then
      v_rating := v_rating_text::numeric;
    else
      v_rating := null;
    end if;

    v_count_text := v_tabelog->>'review_count';
    if v_count_text ~ '^[0-9]{1,9}$' then
      v_review_count := v_count_text::int;
    else
      v_review_count := null;
    end if;

    -- The dinner band's upper bound. 0 is not a legal value here (section A's CHECK), and a
    -- band that parsed to 0 would be a parser fault reported as a free restaurant, so it is
    -- dropped exactly like an off-scale score.
    v_budget_text := v_tabelog->>'budget_yen';
    if v_budget_text ~ '^[0-9]{1,9}$' and v_budget_text::int > 0 then
      v_budget_yen := v_budget_text::int;
    else
      v_budget_yen := null;
    end if;

    execute 'update public.restaurant_features rf
                set tabelog_id = $2::text,
                    tabelog_rating = $3::numeric,
                    tabelog_review_count = $4::int,
                    tabelog_budget_yen = $5::int
              where rf.place_id = $1'
      using v_place_id, v_tabelog_id, v_rating, v_review_count, v_budget_yen;
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end; $$;

-- ---------------------------------------------------------------------------
-- D. The photo write path
-- ---------------------------------------------------------------------------

-- Element shape: {"place_id": text, "photo_url": text|null}. Modelled line for line on 0023's
-- fn_record_provider_smoking_policy: same `security definer` + `search_path = ''`, same
-- request-context guard, same present/absent contract, same information_schema probe so the
-- body never hard-depends on a column another deployment might not have yet.
--
-- WHY A SEPARATE WRITER RATHER THAN 0017's fn_record_provider_candidates. Exactly 0022's and
-- 0023's reason: 0017 is a shipped migration whose writer promises never to touch columns it
-- does not name, so a new column gets a new writer beside it rather than a rewrite of the old
-- one. 0017's writer ignores the `photo_url` key entirely.
--
-- ADDITIVE OR AUTHORITATIVE? Authoritative when the key is PRESENT, additive when it is
-- ABSENT, and the Edge Function sends the key if and only if the candidate was MATCHED to a
-- Hot Pepper shop on this run:
--   * key ABSENT → this candidate has no Hot Pepper shop (~40% of live venues resolve to none,
--     because the join is an exact telephone match and nothing weaker), or the API call failed.
--     Nothing is learned and nothing is erased — 0017's non-destructive rule.
--   * key PRESENT, a usable URL → Recruit's current image for this shop; it replaces whatever
--     is stored.
--   * key PRESENT and null, or present as an unusable value → the matched shop has no photo we
--     may store, and that RETRACTS a stale URL. A shop can remove its photograph, and Recruit
--     can stop serving a URL; keeping one we know is no longer offered would leave a card
--     pointing at somebody else's host for an image they have withdrawn. Only Hot Pepper
--     speaks to this field, so there is no other provider's enrichment to protect (0022's and
--     0023's argument).
-- The regex is section B's CHECK restated, so nothing this function writes can violate it and
-- a provider anomaly degrades one card's photograph rather than failing a whole search.
create or replace function public.fn_record_provider_photo(
  p_event_id uuid,
  p_candidates jsonb
)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_candidate jsonb;
  v_place_id text;
  v_photo_url text;
  v_rows int;
  v_count int := 0;
  v_has_column boolean;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and nullif(current_setting('request.jwt.claims', true), '') is not null
  then
    raise exception 'only the provider pipeline may record a venue photograph';
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
      and c.column_name = 'photo_url'
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
    -- The KEY's presence is the contract, so this is a `?` test and not a null test: an
    -- explicit null IS an answer ("this matched shop has no photograph") and must be able to
    -- clear a stale URL, while an absent key must not.
    if not (v_candidate ? 'photo_url') then
      continue;
    end if;

    v_photo_url := v_candidate->>'photo_url';
    if v_photo_url is null
       or v_photo_url !~ '^https://([a-z0-9-]+\.)*hotp\.jp/[^[:space:]]*$'
       or char_length(v_photo_url) > 500
    then
      -- Anything that is not https on Recruit's own image host is not stored at all, not even
      -- to be filtered later: a Google or Tabelog image URL is not ours to hand to an <img>,
      -- and "we were sent something we will not display" records as no photograph.
      v_photo_url := null;
    end if;

    execute 'update public.restaurant_features rf
                set photo_url = $2::text
              where rf.place_id = $1'
      using v_place_id, v_photo_url;
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end; $$;

-- ---------------------------------------------------------------------------
-- E. Quality scoring: Tabelog counts, as a rank and not as a number
-- ---------------------------------------------------------------------------

-- THE MEASUREMENT THAT DECIDES THE DESIGN. Over the same twenty Shinjuku izakaya:
--
--            min    p25   median   p75    max    span
--   Tabelog  3.07   3.09   3.22    3.39   3.53   0.46
--   Google   3.90   4.20   4.40    4.50   4.90   1.00
--
-- So a RAW MEAN of the two is wrong twice over. It is off by ~1.16 in level, which means the
-- blended score of a venue would be dominated by WHETHER WE MANAGED TO RESOLVE IT ON TABELOG
-- rather than by anything about the restaurant — resolution runs at ~60% and is capped at five
-- venues per search, so that is a coin-flip nobody voted for deciding the ranking. And a fixed
-- rescale is wrong too: Tabelog's span is half Google's, so any single multiplier that lines
-- the medians up misweights the spread, and a Tabelog 3.53 (the best venue in the sample)
-- would land level with a Google 4.4 (the median one).
--
-- WHAT IS DONE INSTEAD: RELATIVE RANK WITHIN EACH PROVIDER'S OWN POOL.
--
--   1. Per provider, per venue, a volume-adjusted score (fn_provider_quality_shrunk): the same
--      Bayesian shrinkage 0016 already applies to Google, with each provider's OWN prior. This
--      is what keeps 「volume beats a small perfect score」 true INSIDE a provider — a Tabelog
--      3.53 from two reviews must not outrank a 3.50 from four hundred, which is the exact bug
--      0016 fixed for Google.
--   2. Per provider, that venue's PERCENTILE among the feasible candidates that have a score
--      FROM THAT PROVIDER (fn_provider_quality_percentile's definition, computed in
--      fn_score_feasible_candidates because it needs the whole pool).
--   3. quality = the MEAN of the percentiles that exist, over one provider or two.
--
-- A median-for-Tabelog venue and a median-for-Google venue both land at 0.5. That is the
-- property a raw mean destroys and the reason this is a rank and not a number.
--
-- PRESENCE IS NEITHER A BONUS NOR A PENALTY. A venue with no Tabelog score keeps its
-- Google-only percentile unchanged — it is not averaged against 0, and it is not averaged
-- against 0.5 either, because a provider that said nothing contributes no term to the mean.
-- The `method` key records which providers spoke, so a client never has to infer it.
--
-- AND THE 0.2 BAND IS KEPT. 0016's structural rule is that scores derived from COMPLETE data
-- live in [0.2, 1.0] and anything with a gap is squeezed into [0, 0.2), which is how "missing
-- data must never win" is enforced by arithmetic rather than by hope. A bare percentile would
-- break it: the lowest-ranked venue in a pool of twenty scores 0.025, which is BELOW the
-- atmosphere-tag proxy's ceiling of 0.2 — so a venue nobody has rated would have outranked a
-- venue with a real, if poor, provider score, which is the same "ranked by what we happened to
-- collect" failure in the opposite direction. The blended percentile is therefore passed
-- through fn_banded_score(1.0, …) exactly as travel fairness and access already are: complete
-- data, so it occupies [0.2, 1.0], and the tag proxy keeps [0, 0.2) to itself.

-- The Bayesian prior each provider is shrunk toward, in one place so the two implementations
-- (this file and web/src/backend/engine.ts) cannot hold different opinions.
--
--   google   3.9 — 0016's number, unchanged: "an average Tokyo izakaya with 50 reviews".
--   tabelog  3.3 — Tabelog's own averages cluster there (0027's header says so) and the sample
--                  above puts its median at 3.22. Reusing Google's 3.9 would be a prior ABOVE
--                  the maximum observed Tabelog score, so every low-volume Tabelog venue would
--                  be shrunk UP past every high-volume one and the ranking would inverted by a
--                  constant borrowed from another scale — the same category error as averaging
--                  the raw scores, moved one step earlier.
--
-- An unrecognised provider yields NULL, which fn_provider_quality_shrunk turns into "no
-- signal": a caller that invents a provider gets no score rather than Google's by default.
create or replace function public.fn_quality_prior_rating(p_provider text)
returns numeric language sql immutable security definer set search_path = '' as $$
  select case p_provider when 'google' then 3.9 when 'tabelog' then 3.3 end;
$$;

-- One provider's volume-adjusted score for one venue on that provider's own 1-5 scale, or NULL
-- when the provider gave us nothing usable. shrink(r, n) = (50 * prior + r * n) / (50 + n),
-- which is 0016's fn_quality_signal arithmetic with the prior made a parameter and WITHOUT the
-- /5 rescale — the value is only ever compared against other venues' values from the SAME
-- provider, so the scale it lives on does not matter and dividing by 5 would only lose digits.
--
-- The NULL rules are 0016's, restated per provider because they matter twice as much now:
-- `rating <= 0` or a zero review count is "no signal", never "terrible". Both providers omit
-- the score entirely for an unrated venue (Google's field is absent, Tabelog prints 「-」), and
-- both scales start above 0, so a 0 is always an absence rather than a verdict. A venue with a
-- score but no review count is also "no signal": there is nothing to shrink it by, and the
-- honest answer is the same one we give when we did not resolve the venue at all.
--
-- Rounded to 4 decimals like every other stored number in this engine, which also means two
-- venues whose adjusted scores differ by less than 0.0001 TIE rather than being ordered by
-- float noise — see the percentile definition below for what a tie does.
create or replace function public.fn_provider_quality_shrunk(
  p_rating numeric, p_review_count int, p_prior_rating numeric
) returns numeric language sql immutable security definer set search_path = '' as $$
  select case
    when p_prior_rating is not null
     and p_rating is not null and p_rating > 0
     and coalesce(p_review_count, 0) > 0
    -- least/greatest are grammar constructs rather than schema-qualifiable functions, so they
    -- are written bare here exactly as 0016 writes them under the same `search_path = ''`.
    then round((50 * p_prior_rating
                + least(5.0, greatest(1.0, p_rating)) * p_review_count)
               / (50 + p_review_count), 4)
  end;
$$;

-- THE PERCENTILE, DEFINED ONCE, IN WORDS, because the SQL below and the TypeScript port have
-- to agree to the last digit and `verify:engine` compares them against the same hand-derived
-- numbers.
--
-- For a provider p, let S be the FEASIBLE candidates of this event that have a non-NULL
-- fn_provider_quality_shrunk value for p, let n = |S|, and for a venue v in S let
--   less  = how many members of S score strictly BELOW v
--   equal = how many members of S score exactly the same as v (v itself included, so >= 1)
-- then
--   percentile(v) = round( (less + equal/2) / n , 4 )
--
-- WHY THIS FORM AND NOT SQL's percent_rank() OR cume_dist():
--   * percent_rank() is (rank-1)/(n-1) and gives the WORST venue 0 and a single venue 0. Zero
--     is a penalty, and "we resolved exactly one venue on Tabelog" must not push that venue to
--     the bottom of the quality dimension.
--   * cume_dist() is (less+equal)/n and gives the BEST venue, and a single venue, 1.0. That is
--     the same mistake with the sign flipped: a bonus for having been scraped.
--   * (less + equal/2)/n — the mid-rank — is symmetric: the median of an odd-sized pool is
--     EXACTLY 0.5, reflecting the pool maps x to 1-x, and a pool of ONE lands on 0.5, which is
--     the honest reading of "there is nobody to be ranked against". That neutral 0.5 is why
--     resolving a single venue neither rewards nor punishes it in absolute terms.
--
-- TIES SHARE ONE VALUE, and that is deliberate rather than a tie-break omission: two venues
-- with the same adjusted score are the same venue as far as this dimension knows, and ordering
-- them against each other would be inventing a distinction. `equal/2` gives both of them the
-- midpoint of the range they jointly occupy, so the pool's percentiles still sum to n/2
-- whatever the tie structure. Determinism of the RESULT is unaffected — there is no arbitrary
-- choice to make — and the place_id tie-break the engine uses elsewhere still decides the
-- SHORTLIST's order (`order by objective_score desc, place_id`, unchanged below) and the label
-- loop's co-leader, exactly as before.
--
-- HOW IT IS ROUNDED, so the two implementations cannot drift: the quantity is a ratio of
-- INTEGERS, (2*less + equal) / (2*n), and both sides round that ratio to four decimals with
-- half away from zero. Postgres does it in exact numeric; the port multiplies the numerator by
-- 10000 first (an exact integer in a double) and rounds the single division, so an exact .5
-- boundary is representable and rounds the same way in both.

-- Restaurant quality, blended. Takes each provider's raw figures plus the percentile its pool
-- produced, and returns the same jsonb object 0016's fn_quality_signal returned, with EVERY
-- EXISTING KEY UNCHANGED IN NAME AND MEANING (clients decode it) and the new provenance keys
-- added beside them:
--
--   score                      0..1, higher is better — banded as described above
--   method                     google_only | google_and_tabelog | tabelog_only |
--                              atmosphere_tag_proxy
--   rating, user_rating_count  GOOGLE's, exactly as before
--   prior_rating, prior_reviews  Google's prior, exactly as before
--   atmosphere_tags            unchanged
--   google_shrunk, google_percentile, google_ranked_candidates
--   tabelog_rating, tabelog_review_count, tabelog_prior_rating,
--   tabelog_shrunk, tabelog_percentile, tabelog_ranked_candidates
--   blended_percentile         the mean of the percentiles that exist, or NULL
--
-- `method` REPLACES the value 'rating_bayesian_shrunk': a Google-only venue is now
-- 'google_only', because the shrinkage is a step inside the blend rather than the method. The
-- fourth member, 'atmosphere_tag_proxy', is 0016's and keeps its exact meaning and its exact
-- score — clients already branch on that one string to say 「口コミ評価が取れていない」, and
-- that branch must keep working.
--
-- The tag-proxy fallback is not reimplemented here: it is fn_quality_signal's, called with no
-- rating so it can only take that branch, and only its `score` is used. One implementation of
-- the proxy, in the migration that introduced it.
create or replace function public.fn_quality_signal_blended(
  p_rating numeric,
  p_user_rating_count int,
  p_google_percentile numeric,
  p_google_ranked int,
  p_tabelog_rating numeric,
  p_tabelog_review_count int,
  p_tabelog_percentile numeric,
  p_tabelog_ranked int,
  p_atmosphere_tags text[]
) returns jsonb language plpgsql immutable security definer set search_path = '' as $$
declare
  v_base jsonb := public.fn_quality_signal(p_rating, p_user_rating_count, p_atmosphere_tags);
  v_proxy jsonb := public.fn_quality_signal(null, null, p_atmosphere_tags);
  v_google numeric := public.fn_provider_quality_shrunk(
    p_rating, p_user_rating_count, public.fn_quality_prior_rating('google'));
  v_tabelog numeric := public.fn_provider_quality_shrunk(
    p_tabelog_rating, p_tabelog_review_count, public.fn_quality_prior_rating('tabelog'));
  v_google_pct numeric;
  v_tabelog_pct numeric;
  v_blend numeric;
  v_method text;
begin
  -- A percentile counts only when this venue actually HAS that provider's adjusted score. The
  -- two conditions are checked separately on purpose: the pool is ranked by the caller, so
  -- requiring the score as well means a caller that ranked the wrong pool cannot smuggle in a
  -- percentile for a venue the provider never scored.
  if v_google is not null then v_google_pct := p_google_percentile; end if;
  if v_tabelog is not null then v_tabelog_pct := p_tabelog_percentile; end if;

  if v_google_pct is not null and v_tabelog_pct is not null then
    -- The MEAN of two 4-decimal values is a multiple of 0.00005, so it lands exactly on a
    -- rounding boundary half the time — the one place where "round to 4 decimals" could
    -- genuinely differ between exact numeric here and a double in the TypeScript port. So it is
    -- rounded as an INTEGER ratio on both sides: scale both percentiles up by 10000 (exact),
    -- halve, round half away from zero, scale back. The outer round(…, 4) only fixes the scale.
    v_blend := round(
      round((v_google_pct * 10000 + v_tabelog_pct * 10000) / 2, 0) / 10000, 4);
    v_method := 'google_and_tabelog';
  elsif v_google_pct is not null then
    v_blend := v_google_pct;
    v_method := 'google_only';
  elsif v_tabelog_pct is not null then
    v_blend := v_tabelog_pct;
    v_method := 'tabelog_only';
  end if;

  return v_base || jsonb_build_object(
    -- Complete data, so fn_banded_score puts it in [0.2, 1.0]; with no provider percentile at
    -- all the tag proxy keeps [0, 0.2) and an unrated venue still cannot outscore a rated one.
    'score', case when v_blend is null then (v_proxy->>'score')::numeric
                  else public.fn_banded_score(1.0, v_blend) end,
    'method', coalesce(v_method, 'atmosphere_tag_proxy'),
    'google_shrunk', v_google,
    'google_percentile', v_google_pct,
    'google_ranked_candidates', coalesce(p_google_ranked, 0),
    'tabelog_rating', p_tabelog_rating,
    'tabelog_review_count', p_tabelog_review_count,
    'tabelog_prior_rating', public.fn_quality_prior_rating('tabelog'),
    'tabelog_shrunk', v_tabelog,
    'tabelog_percentile', v_tabelog_pct,
    'tabelog_ranked_candidates', coalesce(p_tabelog_ranked, 0),
    'blended_percentile', v_blend);
end; $$;

-- Redeclared from 0016 with exactly one change: the quality dimension is the blend above
-- instead of a per-row call to fn_quality_signal. Everything else — the WANT match, the travel
-- profile, cost and accessibility burden, the objective weights, the composite, the stored
-- breakdown, the five-card limit, the `order by objective_score desc nulls last, place_id`, and
-- the honest-label loop — is 0016's code moved, not edited.
--
-- The quality dimension could not stay a per-row function call because a percentile is a
-- statement about a POOL: it needs every feasible candidate's provider scores before any one
-- venue's quality is known. Hence the two ranking CTEs, each over only the rows where its own
-- provider spoke — which is what makes `count(*) over ()` the size of THAT provider's pool
-- rather than of the candidate set, and what keeps a venue with no Tabelog score out of the
-- Tabelog ranking instead of last in it.
--
-- The pool is the FEASIBLE set, not the five cards: the limit is applied after ordering, and
-- the ordering depends on quality, so ranking inside the five would be circular. It is also
-- the right set on its own terms — a venue that broke somebody's MUST is not a peer.
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
      rf.rating, rf.user_rating_count, rf.atmosphere_tags,
      rf.tabelog_rating, rf.tabelog_review_count,
      -- The two providers are read from their OWN columns, side by side, and neither is ever
      -- written here. This is the whole of what "Tabelog counts" means.
      public.fn_provider_quality_shrunk(rf.rating, rf.user_rating_count,
        public.fn_quality_prior_rating('google')) as google_value,
      public.fn_provider_quality_shrunk(rf.tabelog_rating, rf.tabelog_review_count,
        public.fn_quality_prior_rating('tabelog')) as tabelog_value,
      public.fn_cost_burden(p_event_id, rf.price_yen_estimate) as cost,
      public.fn_accessibility_burden(p_event_id, rf.accessibility_tags) as accessibility
    from public.restaurants r
    join public.restaurant_features rf on rf.place_id = r.place_id
    where public.fn_candidate_is_feasible(p_event_id, r.place_id)
  ), google_rank as (
    -- (less + equal/2) / n, as a ratio of integers rounded once. `rank() - 1` is `less`,
    -- `count(*) over (partition by value)` is `equal`, `count(*) over ()` is n — and n is the
    -- size of THIS provider's pool because the WHERE clause runs before the windows do.
    select c.place_id,
      round((2 * (rank() over (order by c.google_value) - 1)
             + count(*) over (partition by c.google_value))::numeric
            / (2 * count(*) over ()), 4) as percentile,
      (count(*) over ())::int as ranked
    from cand c where c.google_value is not null
  ), tabelog_rank as (
    select c.place_id,
      round((2 * (rank() over (order by c.tabelog_value) - 1)
             + count(*) over (partition by c.tabelog_value))::numeric
            / (2 * count(*) over ()), 4) as percentile,
      (count(*) over ())::int as ranked
    from cand c where c.tabelog_value is not null
  ), comp as (
    select c.place_id, c.travel, c.cost, c.accessibility,
      public.fn_quality_signal_blended(
        c.rating, c.user_rating_count, g.percentile, coalesce(g.ranked, 0),
        c.tabelog_rating, c.tabelog_review_count, t.percentile, coalesce(t.ranked, 0),
        c.atmosphere_tags) as quality,
      (c.travel->>'fairness')::numeric as travel_fairness,
      (c.travel->>'access')::numeric as travel_access,
      case when v_want_count = 0 then 1.0
        else round(c.wants_matched::numeric / v_want_count, 4) end as satisfaction,
      -- The columns store burden (higher is worse); the components are its complement so
      -- the objective can stay a plain weighted sum of "higher is better" numbers.
      round(1 - (c.cost->>'burden')::numeric, 4) as cost_fit,
      round(1 - (c.accessibility->>'burden')::numeric, 4) as accessibility_fit
    from cand c
    left join google_rank g on g.place_id = c.place_id
    left join tabelog_rank t on t.place_id = c.place_id
  ), graded as (
    select comp.*, (comp.quality->>'score')::numeric as quality_score from comp
  ), scored as (
    select graded.*,
      round((v_weights->>'travel_fairness')::numeric * graded.travel_fairness, 4) as c_fairness,
      round((v_weights->>'travel_access')::numeric * graded.travel_access, 4) as c_access,
      round((v_weights->>'satisfaction')::numeric * graded.satisfaction, 4) as c_satisfaction,
      round((v_weights->>'quality')::numeric * graded.quality_score, 4) as c_quality,
      round((v_weights->>'cost_fit')::numeric * graded.cost_fit, 4) as c_cost,
      round((v_weights->>'accessibility_fit')::numeric * graded.accessibility_fit, 4)
        as c_access_fit,
      round((v_weights->>'travel_fairness')::numeric * graded.travel_fairness
          + (v_weights->>'travel_access')::numeric * graded.travel_access
          + (v_weights->>'satisfaction')::numeric * graded.satisfaction
          + (v_weights->>'quality')::numeric * graded.quality_score
          + (v_weights->>'cost_fit')::numeric * graded.cost_fit
          + (v_weights->>'accessibility_fit')::numeric * graded.accessibility_fit, 4)
        as objective_score
    from graded
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
  -- 3-5 differentiated options, and the one line the objective actually changes: it decides
  -- both which five feasible venues become cards and the order they are written in. place_id
  -- breaks a tie, here as everywhere else in the engine.
  order by s.objective_score desc nulls last, s.place_id
  limit 5;

  -- 0016's honest-label loop, unchanged. Per label, in this fixed order:
  --   * a row with no value for the metric can never lead it;
  --   * if every row shares the best value the metric separates nothing, so the badge is
  --     dropped — there is no "most X" to claim (leaders < total);
  --   * ties are legitimate co-leaders and the first by place_id that is still unlabelled
  --     takes it;
  --   * if every genuine leader already carries a badge the label goes UNUSED rather than
  --     being handed to a row that does not deserve it.
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

-- ---------------------------------------------------------------------------
-- F. Privileges
-- ---------------------------------------------------------------------------

-- Same rule as 0009/0015/0016/0021/0022/0023/0027. The two writers are implementation details
-- of the provider pipeline, which runs as service_role and is their only caller. The three
-- scoring helpers are implementation details of the guarded fn_recompute_feasibility RPC:
-- fn_quality_signal_blended would otherwise let a client score any figures it liked and read
-- the method back, and fn_score_feasible_candidates writes rows for any run_id it is handed.
revoke execute on function public.fn_record_tabelog_enrichment(uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_record_provider_photo(uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.fn_quality_prior_rating(text)
  from public, anon, authenticated;
revoke execute on function public.fn_provider_quality_shrunk(numeric, int, numeric)
  from public, anon, authenticated;
revoke execute on function public.fn_quality_signal_blended(
  numeric, int, numeric, int, numeric, int, numeric, int, text[])
  from public, anon, authenticated;
revoke execute on function public.fn_score_feasible_candidates(uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.fn_record_tabelog_enrichment(uuid, jsonb) to service_role;
grant execute on function public.fn_record_provider_photo(uuid, jsonb) to service_role;
grant execute on function public.fn_quality_prior_rating(text) to service_role;
grant execute on function public.fn_provider_quality_shrunk(numeric, int, numeric)
  to service_role;
grant execute on function public.fn_quality_signal_blended(
  numeric, int, numeric, int, numeric, int, numeric, int, text[]) to service_role;
grant execute on function public.fn_score_feasible_candidates(uuid, uuid) to service_role;
