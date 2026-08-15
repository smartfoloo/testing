-- 0027_tabelog_enrichment.sql
-- Tabelog (食べログ) as a THIRD enrichment provider beside Google Places and Hot Pepper — and
-- the only one of the three that has no API at all.
--
-- ============================================================================================
-- READ THIS BEFORE YOU SWITCH ANYTHING HERE ON.
--
--   * TABELOG HAS NO PUBLIC API. Kakaku.com (カカクコム) publishes none, so the writer of these
--     columns is an HTML SCRAPER (functions/restaurant-search/index.ts, tabelogResolve).
--   * TABELOG'S TERMS OF USE PROHIBIT REPRODUCING ITS CONTENT WITHOUT PRIOR WRITTEN CONSENT and
--     bar commercial use. We do not have that consent. This exists for a NON-COMMERCIAL
--     HACKATHON DEMO and for nothing else.
--   * THE WRITE PATH IS FEATURE-FLAGGED, AND SINCE 0028's DEMO DECISION THE FLAG DEFAULTS TO
--     ON. The Edge Function makes no request to tabelog.com when the secret
--     TABELOG_ENRICHMENT_ENABLED is exactly the string "false"; any other value, including
--     unset, enables it. These columns therefore fill in by default on a live search — which
--     is what the owner wanted for the demo, and is worth knowing before this repository is
--     run anywhere that is not one.
--   * THE LEGITIMATE ROUTE IS A PARTNER AGREEMENT WITH KAKAKU.COM. If this feature is ever
--     wanted in a product, that is the change to make — not a wider scraper.
--   * NO REVIEW TEXT IS TAKEN, EVER. Review text is the content Tabelog's terms protect most
--     explicitly (they name a per-review penalty) and reviewer pages are robots.txt-disallowed.
--     Nothing in this migration can hold review text: there is no column for it, the scraper
--     never fetches a review page, and the cache row it writes (section A) is an extracted
--     six-field object, never a raw page.
-- ============================================================================================
--
-- What this migration adds, and nothing else:
--
--   A  'tabelog' becomes a legal `restaurant_source_records.provider`, so one resolution
--      attempt per venue can be cached and a repeat search costs zero requests.
--   B  restaurant_features gains THREE columns of its own — tabelog_id, tabelog_rating,
--      tabelog_review_count — beside Google's `rating` / `user_rating_count`, never merged into
--      them.
--   C  fn_record_tabelog_enrichment, the service_role-only write path, modelled line for line
--      on 0023's fn_record_provider_smoking_policy / fn_record_provider_attributions: same
--      `security definer` + `search_path = ''`, same request-context guard, same
--      null-means-learned-nothing contract.
--   D  privileges, because 0024's lesson is that nothing is reachable by accident: a client role
--      gets no EXECUTE on the writer, and the new columns are readable only through the
--      table-level grant restaurant_features already carries.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO: it does not touch scoring.
-- fn_quality_signal and fn_score_feasible_candidates (0016) still read `rating` /
-- `user_rating_count` and only those. A Tabelog 3.71 and a Google 4.0 are drawn from
-- distributions that do not resemble each other — Tabelog's mass sits between 3.0 and 3.6 and a
-- 4.2 is a national-award venue, while Google's sits near 4.0 — so averaging them would move
-- every candidate's quality score without measuring anything. Blending them properly means
-- percentile-relative scores within each provider's own candidate set, which is a separate
-- change with its own tests. This migration stores the data honestly and stops there; nothing
-- reads the three columns except a client that wants to display them.
--
-- Everything is additive and re-runnable: columns are `add column if not exists`, constraints
-- are drop-then-add (0016/0021/0022/0023's guard rails), the function is create-or-replace, and
-- grants/revokes are absolute rather than additive.

-- ---------------------------------------------------------------------------
-- A. 'tabelog' as a cacheable provider
-- ---------------------------------------------------------------------------

-- 0017 constrained `restaurant_source_records.provider` to the three providers that existed
-- then. Without this, the cache row below fails its CHECK and every search re-scrapes the same
-- five venues — the exact behaviour a site with no API and no consent must never see from us.
alter table public.restaurant_source_records
  drop constraint if exists restaurant_source_records_provider_check;
alter table public.restaurant_source_records
  add constraint restaurant_source_records_provider_check
  check (provider in ('google_places', 'google_routes', 'hotpepper', 'tabelog'));

-- WHAT A 'tabelog' ROW HOLDS, AND WHY IT IS NOT A RAW PAYLOAD. Every other provider's row in
-- this table is the payload as it arrived (0017: "raw provider payloads … the evidence is
-- here"). A Tabelog row is NOT, and that is the one deliberate deviation in this file: a
-- Tabelog venue page carries the venue's whole review stream, both as visible markup and inside
-- its schema.org `review` array, and its search-results page carries review excerpts. Storing
-- the page would therefore store exactly the content we have decided never to hold. The row
-- holds the extracted fields and a verdict — {resolved, tabelog_id, name, rating, review_count,
-- matched_by, phone_match, source_url} — and no HTML at all.
--
-- source_id is the constant 'resolution', not the Tabelog id. The unique key
-- (place_id, provider, source_id) needs a third component, and an UNRESOLVED attempt has no
-- Tabelog id to offer: keying by the id would make "we asked and learned nothing" unrepresentable,
-- and that is precisely the state that has to be remembered, because otherwise every search
-- re-asks about the venues that will never resolve. One row per place is also what a cache
-- wants — this is a refreshable cache with a ceiling (fn_purge_stale_provider_cache), not a
-- history table.
--
-- The row stays client-unreadable, like every other row in this table: 0017 gives it no client
-- select policy and revokes the client roles' privileges, and 0024 kept it that way. Provider
-- content under provider terms is server-side only, and that argument is stronger here than
-- anywhere else in the schema.

-- ---------------------------------------------------------------------------
-- B. Tabelog's own columns
-- ---------------------------------------------------------------------------

-- THREE COLUMNS, NOT A MERGE. `rating` and `user_rating_count` (0016) are GOOGLE'S numbers and
-- fn_quality_signal reads them as Google's. Writing a Tabelog score into them would make the
-- stored quality signal a claim about a scale it was never calibrated for, and would make the
-- two providers indistinguishable at exactly the moment they disagree — which is the moment the
-- disagreement is the most interesting thing we know about a venue. Provenance is the point:
-- three providers must not be squashed into one pseudo-authoritative record.
--
-- Assume NULL, and assume NULL far more often than for Google: nothing is written unless the
-- flag is on AND the venue is one of at most five shortlisted per search AND its identity was
-- confirmed by an exact phone match. A NULL here means "we did not confirm which Tabelog page
-- this is", which is the honest answer and the only one we are willing to give.
alter table public.restaurant_features
  add column if not exists tabelog_id text;
alter table public.restaurant_features
  add column if not exists tabelog_rating numeric;
alter table public.restaurant_features
  add column if not exists tabelog_review_count int;

-- Guard rails on provider writes, in the shape 0016 used for `rating` / `user_rating_count`: a
-- score outside the 0–5 scale Tabelog publishes on, or a negative review count, is a parser bug
-- rather than a fact, and it must not reach a card. drop-then-add keeps this re-runnable.
--
-- Tabelog's scale tops out at 5.00 and in practice a venue's score sits between 3.00 and 4.9
-- (the site's own averages cluster near 3.3), so 0–5 is deliberately looser than the observed
-- range: the constraint is here to catch a selector that started matching something else, not
-- to encode today's distribution.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_tabelog_rating_range;
alter table public.restaurant_features
  add constraint restaurant_features_tabelog_rating_range
  check (tabelog_rating is null or (tabelog_rating >= 0 and tabelog_rating <= 5));

alter table public.restaurant_features
  drop constraint if exists restaurant_features_tabelog_review_count_sane;
alter table public.restaurant_features
  add constraint restaurant_features_tabelog_review_count_sane
  check (tabelog_review_count is null or tabelog_review_count >= 0);

-- The id is the digits Tabelog puts in the last path segment of a venue URL
-- (…/tokyo/A1304/A130401/13184186/ -> '13184186'). Constrained to digits because the failure
-- mode of a scraper is not a wrong number, it is a URL, an HTML fragment or an empty string
-- landing in a column something later joins on.
alter table public.restaurant_features
  drop constraint if exists restaurant_features_tabelog_id_shape;
alter table public.restaurant_features
  add constraint restaurant_features_tabelog_id_shape
  check (tabelog_id is null or tabelog_id ~ '^[0-9]{6,10}$');

-- Re-stated, not fixed: 0024 already grants SELECT on this table to `authenticated` and to
-- `service_role`, and a table-level grant covers columns added afterwards, so the three columns
-- above are readable the moment they exist. It is written out because 0024's own lesson is that
-- a new column reachable by a client should say so where it is defined rather than leave it to
-- whichever default ACL the database happens to carry.
grant select on table public.restaurant_features to authenticated;

-- ---------------------------------------------------------------------------
-- C. The provider write path
-- ---------------------------------------------------------------------------

-- Shape of each element: {"place_id": text, "tabelog": {"tabelog_id": text, "rating": number,
-- "review_count": int}}.
--
-- ADDITIVE OR AUTHORITATIVE? Both, along the same axis as 0023's two writers, and the KEY'S
-- PRESENCE is the whole contract:
--
--   * `tabelog` key ABSENT → nothing learned, nothing written. This is the COMMON case and the
--     reason the distinction exists. It covers every one of: the flag is off; the venue was not
--     in the five-venue shortlist; it has no telephone number for us to match on; Tabelog's
--     search found nothing; the page we opened printed a different number; the request budget
--     ran out. All of those mean "we did not confirm which Tabelog page this is", and none of
--     them may erase an identity an earlier run DID confirm by exact phone match. An
--     unresolved candidate is left NULL rather than guessed, and a resolved one is not
--     retracted because a later search flaked.
--   * `tabelog` key PRESENT → the identity was confirmed against the venue page's own telephone
--     number, and the score and review count are Tabelog's CURRENT figures for it, so they
--     REPLACE what is stored — including with NULL when the page publishes no score at all (a
--     newly listed venue shows 「-」 rather than a number). This is a refreshable cache of a
--     live figure: continuing to display a score Tabelog no longer shows would be a false claim
--     about where today's number came from, which is the argument 0023 made for attributions.
--
-- Nothing outside section B's three CHECKs can be written: the id must be digits, the score is
-- only cast when it is a plain number inside 0–5, and the count only when it is a plain
-- non-negative integer. Anything else records NULL for that field rather than failing the whole
-- search on a constraint violation — a provider anomaly must degrade the enrichment, not the
-- event.
--
-- The columns belong to this migration, so the information_schema probe below is only about
-- ordering robustness — the same dynamic-execute shape 0022 and 0023 used, kept so the function
-- body never hard-depends on a column another deployment might not have yet.
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
  v_rows int;
  v_count int := 0;
  v_has_column boolean;
begin
  -- Same request-context shape as 0017/0022/0023: the service_role Edge Function client and
  -- direct SQL sessions (no JWT claims) are the admin/definer path. An API caller must never
  -- write provider data, and least of all this provider's — a client that could call this could
  -- attribute any Tabelog page, and any score, to any venue.
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

  select exists (
    select 1 from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'restaurant_features'
      and c.column_name = 'tabelog_id'
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

    -- Absent, or present as anything other than a JSON object: this venue was not resolved on
    -- this run, so nothing is recorded and nothing is erased.
    v_tabelog := v_candidate->'tabelog';
    if jsonb_typeof(v_tabelog) is distinct from 'object' then
      continue;
    end if;

    -- The id IS the resolution. Without a well-formed one there is no identity to attach a
    -- score to, and a score attached to the wrong venue is the single failure this whole design
    -- exists to prevent, so an unusable id discards the element entirely rather than writing
    -- the numbers on their own.
    v_tabelog_id := nullif(v_tabelog->>'tabelog_id', '');
    if v_tabelog_id is null or v_tabelog_id !~ '^[0-9]{6,10}$' then
      continue;
    end if;

    -- Cast only what is unambiguously a number in range; everything else is NULL, which is
    -- "Tabelog published no score", not "the score is zero". The regexes also mean section B's
    -- CHECKs can never be violated from here, so a parser that starts matching the wrong
    -- element cannot fail the search.
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

    execute 'update public.restaurant_features rf
                set tabelog_id = $2::text,
                    tabelog_rating = $3::numeric,
                    tabelog_review_count = $4::int
              where rf.place_id = $1'
      using v_place_id, v_tabelog_id, v_rating, v_review_count;
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;

  return v_count;
end; $$;

-- ---------------------------------------------------------------------------
-- D. Privileges
-- ---------------------------------------------------------------------------

-- Same rule as 0009/0015/0016/0021/0022/0023: this is an implementation detail of the provider
-- pipeline, which runs as service_role and is its only caller.
revoke execute on function public.fn_record_tabelog_enrichment(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.fn_record_tabelog_enrichment(uuid, jsonb) to service_role;
