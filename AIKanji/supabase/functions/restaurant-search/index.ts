// POST /restaurant-search — gathers candidate restaurants for an event.
//
// All provider keys (Google Places, Google Routes, Hot Pepper) live only in
// Edge Function secrets; the iOS client only ever calls this function.
// Places FieldMasks are deliberately minimal: an unrequested field such as
// `rating` silently upgrades the call to a pricier billing tier.
// Places content other than place_id is short-lived by policy, so
// restaurant_features is a refreshable cache (fetched_at), not a warehouse.
//
// This function is read-through cached and event-scoped:
//   * candidates belong to an event (event_restaurant_candidates), so a venue
//     discovered for an unrelated event across Tokyo is not silently a candidate
//     here;
//   * travel times belong to an (event, participant, place) triple
//     (travel_matrix_cache), so one event can no longer overwrite another
//     event's commute times — the bug that took an event from 3 feasible venues
//     to 0 with no error;
//   * discovery re-runs only when the cache is stale or the meeting zones moved,
//     and Routes is asked only for the legs we are actually missing;
//   * a resolved origin is required only by the work that needs one — the
//     meeting zones discovery searches around, and the legs Routes has to fetch.
//     A fully cached event therefore succeeds with zero resolved origins, and a
//     partially resolved one searches around the origins it has instead of
//     failing; only a run that must call the providers with nowhere to search is
//     an error (422, naming the participants it could not place);
//   * raw provider payloads land in restaurant_source_records and provider
//     failures land in provider_incidents instead of vanishing into a `return
//     []`;
//   * `accessibilityOptions` is requested and recorded (migration 0022). Nothing
//     had ever written restaurant_features.accessibility_tags, so an accessibility
//     MUST — which fails closed on an empty tag list, and is never relaxable —
//     could not be met by any venue in Tokyo. Only Places' four confirmed
//     booleans become tags; an absent or null boolean stays UNKNOWN.
//   * Hot Pepper's `non_smoking` (禁煙席) is recorded as restaurant_features
//     .smoking_policy (migration 0023). It was already in the response — no `lite`
//     parameter is sent, so the full shop object comes back — and was discarded
//     because HotPepperShop never declared it, which left 0021's smoking_policy
//     with no writer at all and every 禁煙 MUST needing a negotiation round before
//     any venue could qualify. The provider's text is forwarded VERBATIM and mapped
//     in SQL by fn_hotpepper_smoking_policy, so 一部禁煙 / 分煙 / anything
//     unrecognised is recorded as NULL (unconfirmed) rather than guessed.
//     `barrier_free` is declared beside it and deliberately never mapped: see
//     hotPepperNonSmokingText and section B of migration 0023.
//   * `attributions` is requested and recorded as restaurant_features
//     .provider_attributions (migration 0023). Showing Places content without a
//     Google map requires Google Maps attribution AND requires that the per-place
//     third-party attributions the API returns are retrieved and displayed; neither
//     field mask asked for them, so the data was not held anywhere a client could
//     read it. Elements are stored exactly as the provider sent them.
//   * Hot Pepper's `photo.pc.m` is recorded as restaurant_features.photo_url
//     (migration 0028). Same story as `non_smoking` before 0023: it was already on
//     the wire — no `lite` parameter is sent, so the full shop object arrives — and
//     was discarded because HotPepperShop never declared it. It is a sanctioned API
//     field supplied for display by a provider we already credit, and the image
//     stays on Recruit's own host, so we store a URL and never a copy. Only an
//     https URL on that host is accepted (hotPepperPhotoUrl); a Google Places photo
//     is a separate paid SKU with its own per-image attribution and is never
//     requested, and a Tabelog image is never taken at all — see hotPepperPhotoUrl.
//
// ============================================================================
// TABELOG (食べログ) IS A THIRD ENRICHMENT PROVIDER, AND THE ONLY ONE WITH NO API.
// READ THIS BEFORE TOUCHING OR ENABLING ANY OF IT (see tabelogResolve below).
//
//   * THERE IS NO TABELOG API. Kakaku.com (カカクコム) publishes none. Everything
//     under "--- Tabelog ---" below is HTML SCRAPING of pages meant for a browser.
//   * TABELOG'S TERMS OF USE FORBID REPRODUCING ITS CONTENT WITHOUT PRIOR WRITTEN
//     CONSENT, and bar commercial use. We do not have that consent. This code
//     exists for a NON-COMMERCIAL HACKATHON DEMO and for nothing else.
//   * IT IS OFF BY DEFAULT. Set the secret TABELOG_ENRICHMENT_ENABLED to exactly
//     "true" to opt in; every other value, including unset, leaves it OFF. A fresh
//     clone therefore makes no request to tabelog.com unless an operator has made
//     that explicit choice.
//   * THE LEGITIMATE ROUTE IS A PARTNER AGREEMENT WITH KAKAKU.COM. If a product
//     ever wants this data, that is the change to make — not a bigger scraper.
//   * NO REVIEW TEXT IS EVER TAKEN OR STORED. Review text is the content those
//     terms protect most explicitly (they name a per-review penalty) and reviewer
//     pages are robots.txt-disallowed. We fetch no review page, we keep no review
//     field, and the cache row we write holds extracted scalars — never a page.
//   * robots.txt IS HONOURED BY A GUARD IN CODE, not by convention:
//     tabelogUrlAllowed() below carries Tabelog's current `User-agent: *`
//     Disallow list and every request goes through it, including after redirects.
//   * THE DINNER BUDGET BAND (migration 0028) COSTS NO ADDITIONAL REQUEST. It is
//     read out of the venue page tabelogResolve already downloads, in the same
//     parse as the score — see tabelogDinnerBudgetYen. Every limit above is
//     therefore untouched: same five-venue cap, same >=2 s gap, same 15-request
//     ceiling, same 24 h cache. A new FIELD off a page we already have is not a
//     new page, and nothing in this file may ever be changed to make it one.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { canonicalCuisineTags } from "../_shared/cuisine.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const GOOGLE_PLACES_API_KEY = Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "";
const GOOGLE_ROUTES_API_KEY = Deno.env.get("GOOGLE_ROUTES_API_KEY") ??
  GOOGLE_PLACES_API_KEY;
const HOTPEPPER_API_KEY = Deno.env.get("HOTPEPPER_API_KEY") ?? "";
/**
 * The Tabelog scraper's switch. OFF unless the value is exactly "true".
 *
 * Read once at module load — the edge runtime only sees what config.toml's
 * [edge_runtime.secrets] declares, so changing it is a config change plus a stack restart,
 * never a request header.
 */
const TABELOG_ENRICHMENT_ENABLED =
  Deno.env.get("TABELOG_ENRICHMENT_ENABLED") === "true";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// --- Cache policy ------------------------------------------------------------

// Discovery (Places text search + Hot Pepper) is the expensive half and its
// answer barely moves inside one evening's planning session, so a hit inside
// this window skips both providers completely. Most participant edits then
// rerun only the local filtering/ranking (PRD §10).
const DISCOVERY_TTL_MINUTES = 6 * 60;
// Scheduled transit durations move even less than the venue list, and a
// (event, participant, place) leg is only invalidated by that participant
// changing their travel reference — which moves the meeting zones and forces a
// rediscovery anyway.
const TRAVEL_TTL_MINUTES = 24 * 60;
// The one thing that must re-run external discovery is the search space itself
// shifting or expanding (PRD §12). A meeting zone that moved further than this
// from the zone we last searched is a material shift; ~0.01° of latitude is
// roughly 1.1 km, comfortably more than the 0.003° dedupe used when the zones
// are built and comfortably less than a different neighbourhood.
const ZONE_SHIFT_TOLERANCE_DEG = 0.01;

// computeRouteMatrix bills and caps per element (origins × destinations). The
// documented cap is 625 elements for most modes but only 100 for TRANSIT, and
// 3 zones × 10 places × N participants blows past that without batching, so the
// batcher always uses the TRANSIT number rather than the driving headroom.
const ROUTES_MAX_ELEMENTS_PER_REQUEST = 100;
const ROUTES_MAX_ORIGINS_PER_REQUEST = 50;

// Bound what a failing provider can write into a row or a response body.
const INCIDENT_MESSAGE_MAX_CHARS = 400;
const INCIDENT_SUMMARY_MAX = 10;

// Ceiling on the per-place attribution credits recorded for one venue. Places is
// documented to return a handful, so this is far above any plausible real value and
// exists only so a pathological payload cannot bloat a row we upsert on every
// search. Nothing is ever TRUNCATED to fit — an edited credit is a misattribution —
// so tripping this cap drops whole entries, which would under-credit a provider we
// are obliged to credit. That is a compliance problem, not a rounding error, so it
// is recorded as a provider incident rather than handled silently.
const ATTRIBUTIONS_MAX_PER_PLACE = 25;

/** Telephone lookups issued at once. Hot Pepper's rate limit is undocumented, so this is
 * deliberately modest: the cost of being throttled is the whole shortlist losing its 個室 /
 * 禁煙 / budget data, which is exactly what this enrichment exists to supply. */
const HOTPEPPER_LOOKUP_BATCH = 4;

// --- Tabelog politeness limits (all non-negotiable) --------------------------
//
// These are not performance tuning. Tabelog has no API and has not agreed to be read by a
// program at all, so the only defensible request volume is one small enough that a human
// browsing the same five venues would generate more traffic. Every number below is a
// ceiling, they compose, and the whole thing sits behind TABELOG_ENRICHMENT_ENABLED.

/** Venues enriched per search, ever. The shortlist is taken AFTER feasibility filtering, so
 * these are five venues the group could actually be shown — not five of the ~30 discovered.
 * This is the single most important limit here: it is what keeps the request volume in the
 * same order of magnitude as one person opening a few tabs. */
const TABELOG_MAX_VENUES = 5;
/** Requests per search, across every venue and every strategy. Worst case per venue is three
 * (phone search, name search, one venue page), so this is the exact worst case for five
 * venues and nothing can exceed it — a parser that started looping cannot turn into a crawl. */
const TABELOG_MAX_REQUESTS = 15;
/** Minimum gap between two requests, enforced in tabelogFetchHtml. Requests are also strictly
 * SEQUENTIAL — never Promise.all, unlike the Hot Pepper batch above — so this is a genuine
 * floor on the request rate rather than a per-connection delay. Tabelog's robots.txt sets no
 * Crawl-delay for `User-agent: *`; it gives named crawlers 5-10s, and 2s for a five-venue
 * shortlist is in that neighbourhood. */
const TABELOG_MIN_DELAY_MS = 2_000;
/** One retry, and only for a 429 or a 5xx — i.e. only when the site itself said "not now" or
 * broke. A 404 or a parse failure is an answer, and asking again would be asking the same
 * question twice for nothing. */
const TABELOG_MAX_RETRIES = 1;
/** Per-request ceiling. A venue page is ~400 KB of HTML, so this is generous; it exists so a
 * hanging connection cannot hold the whole search open. */
const TABELOG_REQUEST_TIMEOUT_MS = 10_000;
/** Hard total ceiling on the enrichment phase. Once it is spent the remaining venues are left
 * UNRESOLVED (NULL) rather than hurried: enrichment is optional data, the search is not. */
const TABELOG_TOTAL_BUDGET_MS = 60_000;
/** Refuse to read a body larger than this. Purely defensive — the pages we ask for are a
 * fraction of it — so a redirect to something enormous cannot be buffered into memory. */
const TABELOG_MAX_BODY_BYTES = 4_000_000;
/** How long a resolution (or a failure to resolve) is trusted, following the TTL pattern the
 * cache above uses. A Tabelog score moves by hundredths over weeks and an identity does not
 * move at all, so a day is short; the reason it is not longer is that 0017's cache is purged
 * at 30 days, and the reason it is not shorter is that every expiry is another request at a
 * site we have no permission to poll. A hit inside this window costs zero requests, which is
 * the whole point: a repeat search re-fetches nothing. */
const TABELOG_TTL_MINUTES = 24 * 60;
/** Sent verbatim. A browser-like User-Agent is not a disguise: it says we are fetching pages
 * built for a browser, exactly as a browser would, and it deliberately does NOT claim to be
 * any crawler Tabelog's robots.txt names — least of all GPTBot or Google-Extended, both of
 * which that file bans outright. tabelogUrlAllowed() applies the `User-agent: *` rules, which
 * are the strictest ones that could apply to us. */
const TABELOG_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

interface LatLng {
  lat: number;
  lng: number;
}

interface ParticipantRow {
  id: string;
  travel_reference: string | null;
  travel_reference_place_id: string | null;
}

interface ParticipantOriginRow {
  participant_id: string;
  latitude: number;
  longitude: number;
}

interface Candidate {
  place_id: string;
  name: string | null;
  hotpepper_id: string | null;
  price_yen_estimate: number | null;
  room_type: "private" | "semi_private" | "open" | null;
  cuisine_tags: string[];
  dietary_tags: string[];
  allergy_safe_tags: string[];
  atmosphere_tags: string[];
  rating: number | null;
  user_rating_count: number | null;
  /**
   * The accessibility vocabulary members Places CONFIRMED, or null when it returned no
   * `accessibilityOptions` object at all. The distinction is load-bearing: null means "we
   * learned nothing this run" and leaves whatever is recorded alone, while an empty array is
   * Places' current answer ("nothing confirmed") and is allowed to retract a stale tag. See
   * fn_record_provider_accessibility in migration 0022.
   */
  accessibility_tags: string[] | null;
  /**
   * Hot Pepper's `non_smoking` (禁煙席) text EXACTLY as it arrived, or null when this candidate
   * was never matched in Hot Pepper (Places has no smoking field at all) or the field was not a
   * usable string. Nothing is interpreted here: fn_hotpepper_smoking_policy (migration 0023) is
   * the single place that decides which values may become 'non_smoking' / 'smoking_ok' and which
   * stay NULL, so the function and the database cannot hold two opinions about 一部禁煙. null
   * means "we learned nothing this run" and leaves whatever is recorded alone.
   */
  hotpepper_non_smoking: string | null;
  /**
   * The per-place third-party attributions Places returned, element for element as given, or
   * null when the response carried no `attributions` array at all. Same load-bearing
   * distinction as accessibility_tags: null is "nothing learned, change nothing", while an empty
   * array is Places' current answer ("this place needs no third-party credit") and is allowed to
   * clear a stale credit. See fn_record_provider_attributions in migration 0023.
   */
  attributions: unknown[] | null;
  /**
   * Hot Pepper's `photo.pc.m` (168x168, ~40 KB) for this venue, or null when no Hot Pepper
   * shop was matched to it or the field held nothing we are willing to display. See
   * hotPepperPhotoUrl for why the host is checked and why no other provider's image is
   * eligible.
   *
   * The load-bearing distinction is NOT null-vs-non-null on this field but whether the
   * candidate was matched at all, which `hotpepper_id` already records: the write payload
   * carries the `photo_url` key if and only if `hotpepper_id` is set, so a matched shop that
   * no longer offers a photograph RETRACTS a stale URL, while an unmatched candidate leaves
   * whatever is stored alone. See fn_record_provider_photo in migration 0028.
   */
  photo_url: string | null;
  location: LatLng | null;
  /**
   * `places.nationalPhoneNumber`, as Google formats it (`03-1234-5678`). Held only to resolve
   * this venue to a provider record — a Hot Pepper shop id, and (behind the flag) a Tabelog
   * venue page. It is never stored and never shown. Normalised to digits at the point of use,
   * because Hot Pepper's telephone search is an exact match and Tabelog's identity check is an
   * exact digit comparison; the formatted form is also what Tabelog's own search box matches,
   * so both spellings are used and neither is persisted.
   */
  phone: string | null;
}

type Provider = "google_places" | "google_routes" | "hotpepper" | "tabelog";

interface ProviderIncident {
  provider: Provider;
  operation: string;
  status_code: number | null;
  message: string;
}

interface SourceRecord {
  place_id: string;
  provider: Provider;
  source_id: string;
  payload: unknown;
}

interface Origin {
  participantId: string;
  location: LatLng;
}

// --- Provider failures -------------------------------------------------------

// A dead provider must never break the event, but it must not be invisible
// either: every non-ok response and every thrown fetch becomes one of these.
function recordIncident(
  incidents: ProviderIncident[],
  provider: Provider,
  operation: string,
  statusCode: number | null,
  message: string,
): void {
  incidents.push({
    provider,
    operation,
    status_code: statusCode,
    message: scrubSecrets(message),
  });
}

// Provider keys are request-scoped secrets. Hot Pepper takes its key in the
// query string, so an error body or an exception message can echo it back.
function scrubSecrets(text: string): string {
  let out = text;
  for (
    const secret of [
      GOOGLE_PLACES_API_KEY,
      GOOGLE_ROUTES_API_KEY,
      HOTPEPPER_API_KEY,
    ]
  ) {
    if (secret.length > 0) out = out.split(secret).join("[redacted]");
  }
  return out.slice(0, INCIDENT_MESSAGE_MAX_CHARS);
}

async function bodyText(res: Response): Promise<string> {
  try {
    return await res.text();
  } catch {
    return "";
  }
}

// --- Google Places ---------------------------------------------------------

async function placeLocation(
  placeId: string,
  incidents: ProviderIncident[],
): Promise<LatLng | null> {
  try {
    const res = await fetch(
      `https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`,
      {
        headers: {
          "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
          "X-Goog-FieldMask": "location",
        },
      },
    );
    if (!res.ok) {
      recordIncident(
        incidents,
        "google_places",
        "places.get",
        res.status,
        await bodyText(res),
      );
      return null;
    }
    const data = await res.json();
    const loc = data?.location;
    if (typeof loc?.latitude !== "number") return null;
    return { lat: loc.latitude, lng: loc.longitude };
  } catch (err) {
    recordIncident(incidents, "google_places", "places.get", null, String(err));
    return null;
  }
}

async function searchRestaurants(
  area: LatLng,
  cuisineTags: string[],
  incidents: ProviderIncident[],
): Promise<{ candidate: Candidate; raw: unknown }[]> {
  const query = cuisineTags.length > 0
    ? `${cuisineTags.join(" ")} restaurant`
    : "restaurant izakaya";
  let data: { places?: Record<string, unknown>[] };
  try {
    const res = await fetch(
      "https://places.googleapis.com/v1/places:searchText",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
          // Only what we use: anything extra (photos, editorial summaries…)
          // raises the SKU. `rating` / `userRatingCount` do move this call into
          // a pricier Places tier — accepted deliberately because the scoring
          // engine needs a quality signal it is not allowed to invent, and they
          // are two fields on a call we already make once per meeting zone.
          // `places.accessibilityOptions` is a **Pro**-tier field, while
          // `places.rating`, `places.userRatingCount` and `places.priceLevel`
          // above are **Enterprise** — and Places bills the whole call at the
          // highest tier any requested field belongs to, so adding it costs
          // nothing extra on this request. It is the only structured
          // accessibility data any provider of ours has, and without it an
          // accessibility MUST cannot be met by any venue at all (migration
          // 0022): accessibility_tags had no writer, and an empty tag list
          // fails closed by design.
          // `places.attributions` is an **Essentials (IDs Only)** field for Text
          // Search — confirmed against the Place Data Fields table, which lists
          // it beside `places.id`, i.e. the cheapest tier there is. (Note it is
          // Pro on Nearby Search; the tier is per endpoint.) So it cannot change
          // what this call is billed: the request already carries Enterprise
          // fields (`rating`, `userRatingCount`, `priceLevel`) and Places bills
          // the whole call at the highest tier requested. It is requested
          // because policy requires it: Places
          // content displayed without a Google map needs Google Maps
          // attribution AND the per-place third-party attributions returned by
          // the API must be retrieved and displayed, and an unrequested field is
          // one we cannot display (migration 0023).
          "X-Goog-FieldMask":
            // nationalPhoneNumber and priceRange are both Text Search **Enterprise** fields,
            // the tier this request is already in via `rating` / `userRatingCount` — Places
            // bills the whole call at the highest tier requested, so neither changes the
            // price of the call. `priceLevel` is still requested because it remains a usable
            // coarse RANKING signal; it is simply no longer converted into a yen figure.
            // nationalPhoneNumber is the join key onto Hot Pepper: matching by coordinates
            // resolved 0 of 10 real venues, and by exact phone 46 of 76.
            "places.id,places.displayName,places.priceLevel,places.priceRange,places.nationalPhoneNumber,places.primaryType,places.location,places.rating,places.userRatingCount,places.accessibilityOptions,places.attributions",
        },
        body: JSON.stringify({
          textQuery: query,
          pageSize: 10,
          languageCode: "ja",
          locationBias: {
            circle: {
              center: { latitude: area.lat, longitude: area.lng },
              radius: 1200,
            },
          },
        }),
      },
    );
    if (!res.ok) {
      recordIncident(
        incidents,
        "google_places",
        "places.searchText",
        res.status,
        await bodyText(res),
      );
      return [];
    }
    data = await res.json();
  } catch (err) {
    recordIncident(
      incidents,
      "google_places",
      "places.searchText",
      null,
      String(err),
    );
    return [];
  }
  const places: Record<string, unknown>[] = data?.places ?? [];
  return places
    .filter((p) => typeof p.id === "string")
    .map((p) => ({
      candidate: {
        place_id: p.id as string,
        name: typeof (p.displayName as { text?: unknown } | undefined)?.text ===
            "string"
          ? (p.displayName as { text: string }).text
          : null,
        hotpepper_id: null,
        price_yen_estimate: placesPriceYen(p),
        room_type: null,
        // Google's primaryType is its own identifier ("japanese_izakaya_restaurant"), not one of
        // ours. Stored raw it never matched a parsed cuisine preference, because
        // fn_score_feasible_candidates compares the two arrays with `&&`. A type we cannot place
        // maps to nothing rather than to a guess.
        cuisine_tags: canonicalCuisineTags([p.primaryType]),
        dietary_tags: [],
        allergy_safe_tags: [],
        atmosphere_tags: [],
        rating: placesRating(p.rating),
        user_rating_count: placesRatingCount(p.userRatingCount),
        accessibility_tags: placesAccessibilityTags(p.accessibilityOptions),
        // Hot Pepper is the only provider with a smoking field; a candidate that
        // is never matched below keeps null, which records nothing.
        hotpepper_non_smoking: null,
        // Likewise the photograph: Places has one, but only behind a separate paid SKU with
        // its own per-image attribution, and we do not request it. A candidate never matched
        // in Hot Pepper therefore has no photo and its key is omitted from the write.
        photo_url: null,
        phone: typeof p.nationalPhoneNumber === "string"
          ? p.nationalPhoneNumber
          : null,
        attributions: placesAttributions(
          p.attributions,
          p.id as string,
          incidents,
        ),
        location: (p.location as { latitude?: number; longitude?: number })
            ?.latitude != null
          ? {
            lat: (p.location as { latitude: number }).latitude,
            lng: (p.location as { longitude: number }).longitude,
          }
          : null,
      } satisfies Candidate,
      raw: p,
    }));
}

// The four nullable booleans Google Places API (New) returns inside
// `accessibilityOptions`, and the vocabulary member each one maps onto. The
// mapping is 1:1 and involves no inference whatsoever: a tag is recorded if and
// only if its boolean came back exactly `true`.
//
// These four strings ARE the accessibility vocabulary: migration 0022 defines
// them once (fn_accessibility_vocabulary) and constrains
// restaurant_features.accessibility_tags to them, llm-assist states them in its
// prompt and enforces them on the model's answer, and web/src/backend/engine.ts
// mirrors them. Nothing else may ever be recorded, because nothing else can be
// matched.
const ACCESSIBILITY_TAG_BY_PLACES_FIELD: Record<string, string> = {
  wheelchairAccessibleEntrance: "wheelchair_accessible_entrance",
  wheelchairAccessibleParking: "wheelchair_accessible_parking",
  wheelchairAccessibleRestroom: "wheelchair_accessible_restroom",
  wheelchairAccessibleSeating: "wheelchair_accessible_seating",
};

// ASSUMPTIONS ABOUT THE RESPONSE SHAPE (no key is available here to observe it,
// so the parsing is deliberately defensive):
//   * `accessibilityOptions` is OMITTED ENTIRELY for most venues — proto3 JSON
//     omits an unset message — and may also be omitted when the field mask was
//     rejected or the SKU downgraded. Absent, or present as anything other than
//     an object, therefore yields null: "we learned nothing this run", which the
//     write path reads as "change nothing".
//   * each member is a NULLABLE boolean, so `false` and `null` are both
//     UNKNOWN-or-worse and neither ever becomes a tag. Only `true` does, and the
//     comparison is strict so a stringly-typed "true" is not trusted either.
//   * an object with nothing confirmed yields [] — Places' current answer,
//     honestly recorded as "unconfirmed" rather than as a downgrade.
// Sorted so the recorded array matches fn_accessibility_canonical_tags' output.
function placesAccessibilityTags(value: unknown): string[] | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  const options = value as Record<string, unknown>;
  return Object.entries(ACCESSIBILITY_TAG_BY_PLACES_FIELD)
    .filter(([field]) => options[field] === true)
    .map(([, tag]) => tag)
    .sort();
}

// The per-place third-party credits Places says must be displayed alongside this
// place's content, passed through UNCHANGED. This function deliberately does not
// parse, escape, reformat or join them: an attribution is a credit line whose exact
// wording and markup belong to its provider, so rewriting one is a misattribution
// and the display side is the only place allowed to decide how to render it.
//
// ASSUMPTIONS ABOUT THE RESPONSE SHAPE (no key is available here to observe it, so
// the parsing is deliberately defensive):
//   * `attributions` is OMITTED ENTIRELY for most places — proto3 JSON omits an
//     empty repeated field — and may also be omitted if the field mask was rejected.
//     Absent, or present as anything other than an array, therefore yields null:
//     "we learned nothing this run", which the write path reads as "change nothing".
//     An array that IS present, even empty, is Places' current answer and may clear
//     a credit that no longer applies.
//   * each element is EITHER an object (Places (New) documents a provider name plus
//     a provider URI) OR an HTML-ish string (the shape this concept has historically
//     arrived in). Both are kept verbatim; the storage column is jsonb precisely so
//     neither has to be flattened into the other.
//   * a number, a boolean, a JSON null or a nested array cannot be a credit and
//     would reach the UI as junk, so those elements are dropped. Dropping is never a
//     guess: nothing is invented in their place.
// A place id is taken only so the incident below can name the row it is about.
function placesAttributions(
  value: unknown,
  placeId: string,
  incidents: ProviderIncident[],
): unknown[] | null {
  if (!Array.isArray(value)) return null;
  const usable = value.filter((entry) =>
    typeof entry === "string" ||
    (typeof entry === "object" && entry !== null && !Array.isArray(entry))
  );
  if (usable.length > ATTRIBUTIONS_MAX_PER_PLACE) {
    recordIncident(
      incidents,
      "google_places",
      "places.searchText.attributions",
      null,
      `${usable.length} attributions for ${placeId} exceeds the ` +
        `${ATTRIBUTIONS_MAX_PER_PLACE} recorded per place; the rest are not stored ` +
        `and therefore cannot be displayed`,
    );
    return usable.slice(0, ATTRIBUTIONS_MAX_PER_PLACE);
  }
  return usable;
}

// `restaurant_features` constrains rating to 0..5 and the review count to >= 0
// (0016). A provider anomaly must degrade the quality signal, not blow up the
// whole search with a constraint violation, so anything off-scale is dropped
// here and the scoring engine falls back to its no-rating path.
function placesRating(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  if (value < 0 || value > 5) return null;
  return value;
}

function placesRatingCount(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  if (value < 0) return null;
  return Math.round(value);
}

/**
 * The yen figure Google can actually justify, or null.
 *
 * `priceLevel` is DELIBERATELY NOT converted to yen any more. It used to be
 * (MODERATE -> 4000), and that was fake precision of the worst kind: measured against live
 * Shinjuku data, every one of ten discovered venues came back MODERATE and was therefore
 * recorded as exactly 4000 yen, so a budget MUST could not distinguish between any of them —
 * while the `priceRange` Google returned for the same venues said things like 2000-3000. A
 * number nobody observed, identical across the whole shortlist, is worse than no number: the
 * engine cannot tell it is a guess, and 0021 already has the machinery for not knowing (a
 * NULL price fails a budget MUST closed and is reported as coverage). Unknown is a legitimate
 * state in a product whose entire subject is negotiating ambiguity.
 *
 * `priceRange` IS used, because it is an observed range rather than a bucket. The UPPER bound
 * is taken: a budget MUST asks 「max_yen」, so for a venue observed at 2000-3000 the honest
 * answer to 「is it under 2500?」 is no. Rounding toward the cheaper end would quietly promise
 * somebody a bill they did not agree to.
 */
function placesPriceYen(place: Record<string, unknown>): number | null {
  const range = place.priceRange as
    | { startPrice?: { units?: string }; endPrice?: { units?: string } }
    | undefined;
  const upper = range?.endPrice?.units ?? range?.startPrice?.units;
  if (typeof upper === "string" && /^\d+$/.test(upper)) {
    const yen = Number(upper);
    if (Number.isFinite(yen) && yen > 0) return Math.round(yen);
  }
  return null;
}

// --- Hot Pepper -------------------------------------------------------------

// The subset of Recruit's Gourmet Search `shop` object this function reads. The
// request sets no `lite` parameter, so the FULL object arrives and every field below
// was already on the wire — `non_smoking` and `barrier_free` were simply not
// declared, which is how a column with no writer (0021's smoking_policy) sat next to
// a provider that answers the question.
// Every value is free-text Japanese chosen by the shop, not an enum, and is treated
// as `unknown` at the point of use rather than trusted because it is typed here.
interface HotPepperShop {
  id: string;
  name: string;
  budget?: { average?: string };
  private_room?: string; // "あり" | "なし"
  genre?: { name?: string };
  // 禁煙席. Free text: the API reference's own example is 「一部禁煙」. Forwarded
  // verbatim and mapped in SQL — see hotPepperNonSmokingText below.
  non_smoking?: string;
  // バリアフリー. Free text, documented example 「なし」. DECLARED AND NEVER READ, on
  // purpose: see hotPepperNonSmokingText's second comment block and section B of
  // migration 0023 for why it cannot honestly justify any accessibility tag.
  barrier_free?: string;
  // 店舗写真. Three sizes on Recruit's own image host: pc.l is 238x238, pc.m is 168x168
  // (~40 KB) and pc.s is a 58x58 avatar. `m` is the one taken — see hotPepperPhotoUrl.
  // `mobile` is not declared because we have no mobile-specific surface to serve it to.
  photo?: { pc?: { l?: string; m?: string; s?: string } };
  lat?: string;
  lng?: string;
}

/** Longest photo URL we will store. Recruit's are ~70 characters, so this is generous; it
 * exists so a pathological value cannot be written into a column a client puts in an
 * `<img src>`, and it is the same ceiling migration 0028's CHECK enforces. */
const HOTPEPPER_PHOTO_URL_MAX_CHARS = 500;

/**
 * The shape a stored photo URL must have, character for character the CHECK constraint
 * `restaurant_features_photo_url_recruit_https` in migration 0028. Restating it here rather
 * than trusting the database is the same discipline 0027 applies to `tabelog_id`: a value this
 * function accepts can never violate the column's constraint, so a provider anomaly degrades
 * one card's photograph instead of failing the whole search on a check violation.
 *
 * `hotp.jp` with an optional subdomain is Recruit's own image host (`imgfp.hotp.jp` today).
 */
const RECRUIT_PHOTO_URL_SHAPE = /^https:\/\/([a-z0-9-]+\.)*hotp\.jp\/\S*$/;

/**
 * Hot Pepper's 168x168 shop photograph, or null.
 *
 * WHY THIS FIELD IS FREE, AND WHY IT CREATES NO NEW OBLIGATION. It is already in the
 * `gourmet/v1` response for every shop we matched — the request sets no `lite` parameter, so
 * the full shop object arrives — so no extra call is made. It is a field Recruit supplies FOR
 * DISPLAY, from a provider whose credit the shortlist already shows (migration 0023 records
 * provider_attributions precisely so that credit is displayable), and the image is served from
 * Recruit's own host: we store a URL, never a copy.
 *
 * `pc.m` and not `pc.l` or `pc.s`: a card shows a thumbnail, 238x238 is more bytes than a
 * thumbnail needs, and 58x58 is an avatar.
 *
 * WHY THE HOST IS CHECKED RATHER THAN TRUSTED, AND WHY NO OTHER PROVIDER'S IMAGE IS ELIGIBLE:
 *   * A GOOGLE PLACES PHOTO IS NOT TAKEN. Places photos are a separate, separately billed SKU
 *     whose media URLs carry their own per-photo attribution requirements, and this function's
 *     field mask never asks for `photos` at all — so there is nothing here to take even by
 *     accident.
 *   * A TABELOG IMAGE IS NEVER TAKEN. Tabelog's photo pages are on this file's OWN stricter
 *     disallow list (TABELOG_SELF_DISALLOW contains `dtlphotolst`), the photographs are
 *     user-submitted and are not Tabelog's to license onward, and its terms forbid reproducing
 *     its content without prior written consent we do not have. Putting a tabelog.com image
 *     URL in a client's `<img src>` would be exactly that reproduction, performed by the
 *     reader's browser on our instruction.
 *   * So the only host this can ever be is Recruit's, and that is enforced by a pattern rather
 *     than asserted in a comment — here and again by a CHECK in the database.
 * Anything else — an http URL, another host, whitespace, an over-long value, a non-string —
 * records null, which is "this venue has no photograph we may show", not an error.
 */
function hotPepperPhotoUrl(shop: HotPepperShop): string | null {
  const raw = shop.photo?.pc?.m;
  if (typeof raw !== "string") return null;
  const value = raw.trim();
  if (value.length === 0 || value.length > HOTPEPPER_PHOTO_URL_MAX_CHARS) {
    return null;
  }
  return RECRUIT_PHOTO_URL_SHAPE.test(value) ? value : null;
}

/**
 * The Hot Pepper shop id for one telephone number, or null.
 *
 * WHY THE JOIN IS A PHONE NUMBER. Until now the two providers were joined by COORDINATE
 * PROXIMITY (nearest shop within ~100 m). Measured against live Shinjuku data that resolved
 * **0 of 10** venues: the nearest Hot Pepper shop to each discovered venue was 147-466 m away,
 * because the two providers return different venue sets and the same shop carries different
 * coordinates in each. Every JP-specific attribute the engine gates on — 個室, 禁煙, budget —
 * was therefore silently absent on every real venue, while the seeded demo fixture hand-authors
 * all three and looked fine.
 *
 * Name matching does not rescue it either: Google serves romanised or aliased names for many
 * Japanese venues, so 「味斗 新宿店」 arrives as "IZAKAYA AJITO" and 「けむり 新宿」 as "Shinjuku
 * no kemuri yakitori". Telephone is the one identifier both providers state exactly — Hot
 * Pepper documents this search as an exact match — and on the same live sample it resolved
 * **46 of 76** venues (60%), with 76 of 77 carrying a phone number at all.
 *
 * The 40% that do not resolve keep NULL for those attributes, which is the honest answer and
 * the state 0021/0022 already handle: unknown, reported as coverage, never guessed. There is
 * deliberately NO name or distance fallback — a MEDIUM-confidence match would attribute one
 * restaurant's smoking policy or private-room availability to another, and being wrong about
 * those is worse than not knowing.
 */
async function hotPepperIdByPhone(
  phone: string,
  incidents: ProviderIncident[],
): Promise<string | null> {
  if (!HOTPEPPER_API_KEY) return null;
  const digits = phone.replace(/\D/g, "");
  // Japanese numbers are 10 or 11 digits; anything else cannot be an exact match and is not
  // worth a request.
  if (digits.length < 10 || digits.length > 11) return null;
  const url = new URL("https://webservice.recruit.co.jp/hotpepper/shop/v1/");
  url.searchParams.set("key", HOTPEPPER_API_KEY);
  url.searchParams.set("tel", digits);
  url.searchParams.set("format", "json");
  try {
    const res = await fetch(url);
    if (!res.ok) {
      recordIncident(
        incidents,
        "hotpepper",
        "shop.tel",
        res.status,
        await bodyText(res),
      );
      return null;
    }
    const data = await res.json();
    const shops = data?.results?.shop ?? [];
    // Exactly one hit is a match. Two would mean the number is not the identifier Hot Pepper
    // documents it to be, so nothing is chosen rather than the first.
    if (shops.length !== 1) return null;
    const id = shops[0]?.id;
    return typeof id === "string" && id.length > 0 ? id : null;
  } catch (err) {
    recordIncident(incidents, "hotpepper", "shop.tel", null, String(err));
    return null;
  }
}

/**
 * Full details for shops already identified by id. `gourmet/v1` accepts a comma-separated
 * `id` list, so the whole shortlist costs ONE request rather than one per venue — verified
 * against the live API.
 */
async function hotPepperShopsByIds(
  ids: string[],
  incidents: ProviderIncident[],
): Promise<HotPepperShop[]> {
  if (!HOTPEPPER_API_KEY || ids.length === 0) return [];
  const url = new URL(
    "https://webservice.recruit.co.jp/hotpepper/gourmet/v1/",
  );
  url.searchParams.set("key", HOTPEPPER_API_KEY);
  url.searchParams.set("id", ids.join(","));
  url.searchParams.set("count", String(Math.min(ids.length, 100)));
  url.searchParams.set("format", "json");
  try {
    const res = await fetch(url);
    if (!res.ok) {
      recordIncident(
        incidents,
        "hotpepper",
        "gourmet.byId",
        res.status,
        await bodyText(res),
      );
      return [];
    }
    const data = await res.json();
    return data?.results?.shop ?? [];
  } catch (err) {
    recordIncident(incidents, "hotpepper", "gourmet.byId", null, String(err));
    return [];
  }
}

// `private_room: "あり"` only means the shop HAS private rooms, not that our
// group gets one — it is availability, not a reservation. Reporting that as
// room_type='private' satisfied a "private room" MUST on a promise nobody made,
// so it is downgraded to semi_private: honest about being separated-ish, and it
// only clears the MUST once the group has actually relaxed it. Only a confirmed
// private-room booking may ever write 'private'.
function hotPepperRoomType(shop: HotPepperShop): "semi_private" | null {
  if (shop.private_room && shop.private_room.includes("あり")) {
    return "semi_private";
  }
  return null;
}

// Hot Pepper's 禁煙席 text, on its way to the database UNINTERPRETED. This function
// answers exactly one question — "did the provider give us a value at all?" — and
// deliberately does not decide what the value means.
//
// WHY THE MAPPING IS NOT HERE. smoking_policy has exactly two legal values by design
// (0021), the provider field is free-text Japanese with no published value list, and
// the same judgement has to hold in three places: the write path, the feasibility
// engine and the test suite. fn_hotpepper_smoking_policy (migration 0023) owns it,
// so there is one implementation, backend_tests.sql can assert it value by value, and
// a mapping fix is a migration instead of a redeploy. In summary, and asserted there:
// only an unambiguous whole-venue value (全席禁煙 / 全面禁煙 / 完全禁煙, or the
// 喫煙可 equivalents) is recorded; 一部禁煙, 分煙, 禁煙席あり, 未確認 and everything
// unrecognised record NULL = unconfirmed, because provider text cannot tell us which
// side of a partition a group of five will be seated on.
//
// WHY `barrier_free` IS NOT MAPPED ONTO accessibility_tags. 0022's vocabulary is a
// closed set of four members, each named after one Google Places `accessibilityOptions`
// boolean so the mapping needs no inference. 「なし」 means there are no barrier-free
// facilities, whose honest recording is no tag at all (which correctly fails the MUST
// closed), and a vague 「あり」 does not say that it is the ENTRANCE that is step-free,
// or that the restroom is usable, or that a wheelchair user can be seated — the only
// things the vocabulary can express. Accessibility is never relaxable, so a wrong tag
// cannot be walked back by a question: it puts someone in front of a step they were
// told was not there. A missing tag is visible instead — it fails closed and is
// counted in fn_recompute_feasibility's accessibility_unverified_count, so the 幹事
// can phone the venue. The field stays declared in HotPepperShop so the decision is
// legible here rather than looking like an oversight.
function hotPepperNonSmokingText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  // An empty field is absent data, not an answer. Hot Pepper spells "we do not know"
  // as 未確認, which IS an answer and is mapped (to NULL) rather than skipped.
  return text.length > 0 ? text : null;
}

// Budget is a hard MUST gate, so the estimate has to be the UPPER bound:
// "3001〜4000円" is 4000, never the 3001 the old first-number regex returned,
// which let a venue pass a budget MUST it should have failed. "5001円以上" has
// no upper bound at all, so it stays unknown rather than being reported as its
// floor price.
function hotPepperBudgetYen(shop: HotPepperShop): number | null {
  const avg = (shop.budget?.average ?? "").replace(/[,，]/g, "");
  if (/以上|超/.test(avg)) return null;
  const numbers = [...avg.matchAll(/(\d{3,6})/g)]
    .map((m) => Number(m[1]))
    .filter((n) => Number.isFinite(n));
  if (numbers.length === 0) return null;
  return Math.max(...numbers);
}

// --- Tabelog ----------------------------------------------------------------
//
// Everything from here to the end of this section is behind TABELOG_ENRICHMENT_ENABLED and
// under the terms stated at the top of this file: no API exists, this is scraping, Tabelog's
// terms forbid reproducing its content without prior written consent and bar commercial use,
// the flag is what stops it shipping by accident, and the legitimate route is a Kakaku.com
// partner agreement.
//
// WHAT IS TAKEN, EXHAUSTIVELY: the Tabelog id, the venue name, its score, its review COUNT,
// the upper bound of its DINNER budget band, and its telephone number (used for the identity
// check and never persisted). Nothing else.
// No review text — not one character, not in a column, not in the raw-payload cache, not in a
// log line. No menus, no courses, no reservation URLs, no photographs: each was considered and
// deliberately left out, because every extra field is more of somebody else's content held
// without their consent for no additional decision this app actually makes.
//
// The dinner budget (migration 0028) was added to that list on exactly those terms and no
// others: it is on the venue page this code ALREADY downloads, it is read in the SAME parse, it
// costs NO additional request, and it answers a question the app genuinely asks — what a 飲み会
// at this venue costs per head. The lunch band on the same page is NOT read, because nobody
// here is having lunch.
//
// The URL patterns below were cross-checked against narumiruna/gurume (MIT,
// github.com/narumiruna/gurume), which is the same site read from Python. Only the URL shapes
// and the schema.org selector ideas are borrowed; none of its code is, this is a plain
// `fetch` (Tabelog needs no browser-TLS impersonation, so gurume's curl_cffi dependency has
// no counterpart here), and its review/menu/course parsing is deliberately not reproduced.

/**
 * Tabelog's robots.txt `User-agent: *` Disallow list, verbatim, re-read from
 * https://tabelog.com/robots.txt while writing this.
 *
 * We match the `*` group deliberately: the file also names Baiduspider, bingbot, Googlebot,
 * GPTBot (Disallow: /) and others, and the anonymous group is the one that applies to a client
 * claiming to be none of them. Two of the entries are wildcarded — the reviewer-visit subtree
 * and the "_disallow_bot" suffix — so a plain prefix test is not enough and each pattern below
 * is compiled with `*` meaning "any characters".
 *
 * Restaurant LIST pages (/rstLst/, /<pref>/<area>/<subarea>/rstLst/) and venue DETAIL pages
 * (/<pref>/<area>/<subarea>/<id>/) are NOT disallowed by any of these, which is why those are
 * the only two page types this code knows how to ask for.
 */
const TABELOG_ROBOTS_DISALLOW = [
  "/ad_mobile/",
  "/rvwr/*/visitdtl/",
  "/yoyaku/tabelog_booking/",
  "/blog/to_blog",
  "/btb/",
  "/*_disallow_bot",
  "/*_disallow_bot.js",
];

/**
 * Our OWN additional refusals, stricter than robots.txt, so "we do not read reviews" is
 * structural rather than a promise in a comment. Nothing here is disallowed by Tabelog; we
 * simply will not fetch it.
 *   dtlrvwlst / dtlrvwlst/B… — a venue's review list and a single review
 *   /rvwr/                   — reviewer profiles (whose visitdtl/ subtree robots.txt bans)
 *   dtlmenu / dtlratings…    — menus, courses, photo and score breakdowns: out of scope, and
 *                              a page we never request cannot accidentally be parsed
 */
const TABELOG_SELF_DISALLOW = [
  "dtlrvwlst",
  "/rvwr/",
  "dtlmenu",
  "dtlratings",
  "dtlphotolst",
  "dtlmap",
];

/**
 * Is this URL one we are allowed to ask for? Applied to every request AND to the final URL
 * after redirects, because a 301 into a disallowed subtree is still a fetch of a disallowed
 * path. Anything that is not plain https on tabelog.com's own host is refused outright, so a
 * mangled `data-detail-url` cannot send this code somewhere else entirely.
 */
function tabelogUrlAllowed(rawUrl: string): boolean {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    return false;
  }
  if (url.protocol !== "https:") return false;
  if (url.hostname !== "tabelog.com") return false;
  const path = url.pathname;
  for (const pattern of TABELOG_ROBOTS_DISALLOW) {
    // robots.txt patterns are anchored at the path start; `*` is any run of characters and
    // every other character is literal.
    const escaped = pattern
      .split("*")
      .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      .join("[\\s\\S]*");
    if (new RegExp(`^${escaped}`).test(path)) return false;
  }
  return !TABELOG_SELF_DISALLOW.some((fragment) => path.includes(fragment));
}

/** The politeness state for ONE search. Passed explicitly rather than kept in a module-level
 * variable so two concurrent invocations cannot share (and therefore quietly double) a
 * budget. */
interface TabelogBudget {
  requests: number;
  lastRequestAtMs: number;
  deadlineMs: number;
}

function tabelogBudget(): TabelogBudget {
  return {
    requests: 0,
    lastRequestAtMs: 0,
    deadlineMs: Date.now() + TABELOG_TOTAL_BUDGET_MS,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * One page of Tabelog HTML, or null. THE ONLY PLACE IN THIS FILE THAT TALKS TO tabelog.com.
 *
 * Every limit lives here so none of them can be bypassed by a future caller: the flag, the
 * robots/self-disallow guard (before the request and again on the final URL), the request
 * ceiling, the total deadline, the ≥2 s gap, the single retry and the body-size cap. A caller
 * that gets null cannot tell which limit stopped it, and does not need to: null always means
 * "we did not learn anything, leave the venue unresolved".
 */
async function tabelogFetchHtml(
  url: string,
  operation: string,
  budget: TabelogBudget,
  incidents: ProviderIncident[],
): Promise<string | null> {
  // Belt and braces. The callers are already gated, but this is the function that would make
  // the request, so this is where the flag has to be unbypassable.
  if (!TABELOG_ENRICHMENT_ENABLED) return null;
  if (!tabelogUrlAllowed(url)) {
    recordIncident(
      incidents,
      "tabelog",
      `${operation}.refused_by_robots`,
      null,
      `refusing to fetch ${url}: disallowed by tabelog.com/robots.txt or by our own ` +
        `stricter no-reviews rule`,
    );
    return null;
  }
  for (let attempt = 0; attempt <= TABELOG_MAX_RETRIES; attempt++) {
    if (budget.requests >= TABELOG_MAX_REQUESTS) return null;
    if (Date.now() >= budget.deadlineMs) return null;
    // Sequential and spaced. The gap is measured from the last request THIS search made, so
    // it holds across venues and across strategies, not just between retries.
    const sinceLast = Date.now() - budget.lastRequestAtMs;
    if (budget.lastRequestAtMs > 0 && sinceLast < TABELOG_MIN_DELAY_MS) {
      await sleep(TABELOG_MIN_DELAY_MS - sinceLast);
    }
    budget.requests++;
    budget.lastRequestAtMs = Date.now();
    try {
      const res = await fetch(url, {
        headers: {
          "User-Agent": TABELOG_USER_AGENT,
          "Accept": "text/html",
          "Accept-Language": "ja",
        },
        redirect: "follow",
        signal: AbortSignal.timeout(TABELOG_REQUEST_TIMEOUT_MS),
      });
      // A redirect may land somewhere we would never have asked for. Area list pages DO
      // redirect (…/A130401/rstLst/ -> …/A130401/), so this is a normal path, not an edge case.
      if (!tabelogUrlAllowed(res.url)) {
        await res.body?.cancel();
        recordIncident(
          incidents,
          "tabelog",
          `${operation}.redirected_to_disallowed`,
          res.status,
          `${url} redirected to ${res.url}, which robots.txt or our own rules disallow`,
        );
        return null;
      }
      const length = Number(res.headers.get("content-length") ?? "0");
      if (Number.isFinite(length) && length > TABELOG_MAX_BODY_BYTES) {
        await res.body?.cancel();
        recordIncident(
          incidents,
          "tabelog",
          `${operation}.body_too_large`,
          res.status,
          `${length} bytes exceeds the ${TABELOG_MAX_BODY_BYTES} we will buffer`,
        );
        return null;
      }
      if (res.status === 429 || res.status >= 500) {
        // The site said "not now" or broke. This is the ONLY retryable case, and the retry
        // still pays the ≥2 s gap at the top of the loop.
        await bodyText(res);
        recordIncident(
          incidents,
          "tabelog",
          operation,
          res.status,
          `attempt ${attempt + 1} of ${TABELOG_MAX_RETRIES + 1}`,
        );
        continue;
      }
      if (!res.ok) {
        recordIncident(
          incidents,
          "tabelog",
          operation,
          res.status,
          await bodyText(res),
        );
        return null;
      }
      const html = await res.text();
      if (html.length > TABELOG_MAX_BODY_BYTES) {
        recordIncident(
          incidents,
          "tabelog",
          `${operation}.body_too_large`,
          res.status,
          `${html.length} characters exceeds the ${TABELOG_MAX_BODY_BYTES} we will parse`,
        );
        return null;
      }
      return html;
    } catch (err) {
      // A timeout or a transport error. Retryable on the same terms as a 5xx.
      recordIncident(incidents, "tabelog", operation, null, String(err));
    }
  }
  return null;
}

/** Japanese telephone numbers as bare digits, or null when the input cannot be one. Ten or
 * eleven digits: anything else cannot be an exact match, and this comparison is the ONLY
 * evidence we accept that two providers are describing the same restaurant. */
function tabelogPhoneDigits(value: string | null): string | null {
  if (!value) return null;
  const digits = value.replace(/\D/g, "");
  return digits.length >= 10 && digits.length <= 11 ? digits : null;
}

/** One hit on a Tabelog list page: the venue id and the page that describes it. */
interface TabelogHit {
  id: string;
  url: string;
}

/**
 * The venue cassettes on a Tabelog list page, in the order the page listed them and
 * de-duplicated (a promoted venue appears twice).
 *
 * Only the `<div class="list-rst …>` opening tags are read, and only their two data
 * attributes. That is deliberately far narrower than "find links to venue pages": the same
 * page carries review excerpts, reviewer links and neighbouring-venue blocks, and a looser
 * pattern would start collecting them. The detail URL is then re-validated against the strict
 * shape Tabelog uses for a venue page AND against the id in the same tag, so a rewritten
 * attribute cannot point this code at another host or another venue.
 */
function tabelogListHits(html: string): TabelogHit[] {
  const hits: TabelogHit[] = [];
  const seen = new Set<string>();
  for (const tag of html.match(/<div class="list-rst[^>]*>/g) ?? []) {
    const id = tag.match(/data-rst-id="(\d{6,10})"/)?.[1];
    const url = tag.match(/data-detail-url="([^"]+)"/)?.[1];
    if (!id || !url || seen.has(id)) continue;
    // https://tabelog.com/<pref>/A1304/A130401/13184186/ — and the trailing id must be the
    // one this cassette declares.
    const shape = url.match(
      /^https:\/\/tabelog\.com\/[a-z0-9-]+\/[A-Z]\d+\/[A-Z]\d+\/(\d{6,10})\/$/,
    );
    if (!shape || shape[1] !== id) continue;
    if (!tabelogUrlAllowed(url)) continue;
    seen.add(id);
    hits.push({ id, url });
  }
  return hits;
}

/**
 * Tabelog's free-text search, for one keyword.
 *
 * `https://tabelog.com/rstLst/?sw=<keyword>` is the STRICT search: it returns the venues the
 * keyword actually matches, or an explicit 「該当するお店は見つかりませんでした」 page. That
 * matters, because the sibling parameter `sk` alone is a LOOSE search that ignores an
 * unmatched keyword and answers with a generic recommended list — measured while writing this,
 * six different phone numbers all produced the same twenty unrelated venues. Reading that as
 * twenty candidate matches is how a scraper starts attributing one restaurant's rating to
 * another, so `sw` is used and `sk` is not.
 */
async function tabelogSearch(
  keyword: string,
  operation: string,
  budget: TabelogBudget,
  incidents: ProviderIncident[],
): Promise<TabelogHit[]> {
  const trimmed = keyword.trim();
  if (trimmed.length < 2 || trimmed.length > 60) return [];
  const html = await tabelogFetchHtml(
    `https://tabelog.com/rstLst/?sw=${encodeURIComponent(trimmed)}`,
    operation,
    budget,
    incidents,
  );
  return html === null ? [] : tabelogListHits(html);
}

/** What one Tabelog venue page tells us, and the complete list of what we read from it. */
interface TabelogVenue {
  tabelog_id: string;
  name: string | null;
  /** Read for the identity check only. Never persisted, never returned to a client. */
  phone: string | null;
  rating: number | null;
  review_count: number | null;
  /**
   * The upper bound of the DINNER budget band, in yen, or null (`-`, absent, unparseable, or
   * open-ended at the top). Read off THIS page, in THIS parse, so it costs no request — see
   * tabelogDinnerBudgetBand and tabelogBudgetYen. Lunch is deliberately never read.
   */
  budget_yen: number | null;
  source_url: string;
}

/**
 * One venue page, reduced to six scalars.
 *
 * WHERE THE NUMBERS COME FROM, AND HOW THE SELECTOR WAS VALIDATED. Each page carries a
 * schema.org `Restaurant` object in a `<script type="application/ld+json">` block, and the
 * same figures again in the page header markup. BOTH are read and compared:
 *
 *   score         ld+json `aggregateRating.ratingValue`
 *                 <span class="rdheader-rating__score-val-dtl">4.24</span>
 *   review count  ld+json `aggregateRating.ratingCount`   (note: NOT `reviewCount`, which
 *                 Tabelog does not emit)
 *                 <i>口コミ</i><em class="num">360</em>人
 *   dinner budget c-rating-v3__time--dinner -> <span class="c-rating-v3__val">￥8,000～￥9,999
 *                 There is no schema.org counterpart to cross-check it against — the ld+json
 *                 block carries no price band — so this one has a single source, and the
 *                 selector is narrowly anchored on the DINNER marker for that reason. See
 *                 tabelogDinnerBudgetBand for the five venues it was validated against and
 *                 tabelogBudgetYen for why the top of the band is the figure taken.
 *
 * They were checked against each other on six live venues spanning 3.08 to 4.24 (Shinjuku
 * A1304/A130401 plus the venue in the earlier session's notes) and agreed exactly on all six,
 * score and count alike — so the schema.org value IS the score Tabelog displays, and the
 * suspicion that it might be some other rating does not hold. Where they DO disagree the
 * DISPLAYED value wins and a provider incident records the disagreement, because the displayed
 * number is the one a human would read off the page and quote back at us.
 *
 * The one figure that was genuinely wrong in the earlier notes is the review count: 1304 for
 * this venue, where both the ld+json and the page say 360. 1304 is the area code out of the
 * URL (…/A1304/…), which is what a loose 「\d{3,4}」 regex catches first. Hence the two
 * narrowly anchored patterns above and the cross-check.
 *
 * The telephone number is taken ONLY from the ld+json `telephone` field. A regex over the page
 * cannot be used: Tabelog prints its own 050 booking-proxy numbers above the venue's real one
 * (three distinct 050 numbers on the pages sampled), so "the first phone number on the page"
 * is frequently not the restaurant's — and this number is the entire basis of the identity
 * match.
 *
 * The parsed ld+json object also contains the venue's review stream. It is read for exactly
 * four scalars — name, telephone, ratingValue, ratingCount — and dropped; nothing derived from
 * `review` is kept, returned, stored or logged, and TabelogVenue has nowhere to put it.
 */
function tabelogParseVenue(
  html: string,
  expectedId: string,
  sourceUrl: string,
  incidents: ProviderIncident[],
): TabelogVenue | null {
  let name: string | null = null;
  let phone: string | null = null;
  let schemaRating: number | null = null;
  let schemaCount: number | null = null;
  for (
    const block of html.matchAll(
      /<script[^>]+type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g,
    )
  ) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(block[1]);
    } catch {
      continue;
    }
    const doc = parsed as Record<string, unknown> | null;
    if (!doc || typeof doc !== "object" || doc["@type"] !== "Restaurant") {
      continue;
    }
    name = typeof doc.name === "string" && doc.name.trim().length > 0
      ? doc.name.trim()
      : null;
    phone = typeof doc.telephone === "string" ? doc.telephone : null;
    const aggregate = doc.aggregateRating as
      | Record<string, unknown>
      | undefined;
    if (aggregate && typeof aggregate === "object") {
      schemaRating = tabelogRating(aggregate.ratingValue);
      schemaCount = tabelogReviewCount(
        aggregate.ratingCount ?? aggregate.reviewCount,
      );
    }
    break;
  }
  // No schema.org Restaurant object means no telephone number we are willing to trust, and
  // therefore no identity check. Unresolved is the honest outcome.
  if (phone === null) {
    recordIncident(
      incidents,
      "tabelog",
      "tabelog.venue.no_schema_telephone",
      null,
      `${sourceUrl} carries no schema.org Restaurant telephone; leaving the venue unresolved`,
    );
    return null;
  }
  const displayedRating = tabelogRating(
    html.match(
      /<span class="rdheader-rating__score-val-dtl">\s*([\d.]+)\s*<\/span>/,
    )?.[1],
  );
  const displayedCount = tabelogReviewCount(
    html.match(/<i>口コミ<\/i>\s*<em class="num">\s*([\d,]+)\s*<\/em>/)?.[1],
  );
  return {
    tabelog_id: expectedId,
    name,
    phone,
    rating: tabelogCrossCheck(
      displayedRating,
      schemaRating,
      "rating",
      sourceUrl,
      incidents,
    ),
    review_count: tabelogCrossCheck(
      displayedCount,
      schemaCount,
      "review_count",
      sourceUrl,
      incidents,
    ),
    budget_yen: tabelogBudgetYen(tabelogDinnerBudgetBand(html)),
    source_url: sourceUrl,
  };
}

/** The displayed figure, the schema.org one as a fallback, and an incident when the two
 * disagree. Displayed wins on purpose: it is the number on the page a person would read. */
function tabelogCrossCheck(
  displayed: number | null,
  schema: number | null,
  field: string,
  sourceUrl: string,
  incidents: ProviderIncident[],
): number | null {
  if (displayed !== null && schema !== null && displayed !== schema) {
    recordIncident(
      incidents,
      "tabelog",
      `tabelog.venue.${field}_disagreement`,
      null,
      `${sourceUrl}: displayed ${displayed} vs schema.org ${schema}; recording the ` +
        `displayed value`,
    );
  }
  return displayed ?? schema;
}

/** Tabelog publishes on a 0–5 scale and migration 0027 constrains the column to it, so
 * anything off-scale is a parser fault and is dropped rather than recorded. Mirrors
 * placesRating's reasoning for Google's identical range. */
function tabelogRating(value: unknown): number | null {
  const num = typeof value === "number" ? value : Number(
    typeof value === "string" ? value.replace(/,/g, "") : NaN,
  );
  if (!Number.isFinite(num) || num < 0 || num > 5) return null;
  return num;
}

function tabelogReviewCount(value: unknown): number | null {
  const num = typeof value === "number" ? value : Number(
    typeof value === "string" ? value.replace(/,/g, "") : NaN,
  );
  if (!Number.isFinite(num) || num < 0) return null;
  return Math.round(num);
}

/**
 * How far past a dinner marker we will look for a band value, in characters. Measured against
 * the live markup below, the whole dinner block is ~300 characters and the LUNCH marker follows
 * it about 430 characters later — so the real bound is the lunch marker and this is only a
 * backstop for a page that has no lunch band at all. It exists so a dinner block with no value
 * cannot fall through and pick up the lunch block's, which would answer a dinner question with
 * a lunch price; on the venues sampled the two differ by a factor of three.
 */
const TABELOG_BUDGET_SEARCH_WINDOW_CHARS = 600;

/**
 * The DINNER budget band's text as Tabelog prints it (`￥8,000～￥9,999`, or `-`), or null.
 *
 * THE SELECTOR IS c-rating-v3__time--dinner -> <span class="c-rating-v3__val">, and this is the
 * markup it has to survive, copied from a live venue page:
 *
 *   <p class="c-rating-v3 c-rating-v3--s rdheader-budget__icon">
 *     <i class="c-rating-v3__time c-rating-v3__time--dinner" aria-label="Dinner" role="img"></i>
 *     <span class="c-rating-v3__val">
 *       <a href="…/dtlratings/#price-range" class="rdheader-budget__price-target"
 *          >￥6,000～￥7,999</a>
 *     </span>
 *   <p class="c-rating-v3 c-rating-v3--s rdheader-budget__icon">
 *     <i class="c-rating-v3__time c-rating-v3__time--lunch" …></i>
 *     <span class="c-rating-v3__val"><a …>-</a></span>
 *
 * TWO THINGS THAT ARE EASY TO GET WRONG AND WERE:
 *   * the figure is NESTED IN AN <a>, not a text node of the span, so the span's content is
 *     taken whole and its tags stripped. A `[^<]*` capture matches the empty string here and
 *     silently records "no band" for every venue on earth;
 *   * `c-rating-v3__time--dinner` occurs FIVE times on a typical page. Once in the header
 *     budget (this one), once in the 予算 table further down, and once per pickup review card —
 *     and a review card's marker is followed by a star icon, never a `__val` span. So every
 *     occurrence is tried in document order and the first one that yields a non-empty value
 *     wins, rather than trusting the header to stay first.
 *
 * DINNER ONLY, deliberately. This app plans 飲み会: the group eats dinner, so a lunch figure is
 * a number about a meal nobody here is having. Each window is cut at the next `--lunch` marker
 * so the lunch band cannot be reached even by accident.
 *
 * THE SAME FIGURE APPEARS AGAIN in the 予算（口コミ集計） table row as
 * `rstinfo-table__budget-item` + `<em>￥6,000～￥7,999</em>`, and is deliberately NOT read as a
 * cross-check. The score's cross-check (tabelogCrossCheck) is worth having because ld+json is
 * an independent REPRESENTATION produced by a different code path; two renderings of the same
 * template field are not independent evidence, and a second selector is a second thing to
 * break.
 *
 * NO ADDITIONAL REQUEST IS MADE. This runs on the HTML tabelogParseVenue already holds.
 */
function tabelogDinnerBudgetBand(html: string): string | null {
  for (const marker of html.matchAll(/c-rating-v3__time--dinner/g)) {
    const from = marker.index ?? 0;
    const lunch = html.indexOf("c-rating-v3__time--lunch", from);
    const end = Math.min(
      lunch < 0 ? html.length : lunch,
      from + TABELOG_BUDGET_SEARCH_WINDOW_CHARS,
    );
    const value = html.slice(from, end).match(
      /<span class="c-rating-v3__val">([\s\S]*?)<\/span>/,
    )?.[1];
    if (value === undefined) continue;
    const text = value.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
    if (text.length > 0) return text;
  }
  return null;
}

/**
 * The upper bound of a Tabelog budget band, in yen, or null.
 *
 * THE UPPER BOUND, for the same reason placesPriceYen takes Google's `endPrice` and
 * hotPepperBudgetYen takes the top of 「3001〜4000円」: a budget MUST asks 「max_yen」, so the
 * only honest reduction of ￥8,000～￥9,999 to one number is 9999 — the answer to
 * 「is it under ￥9,000?」 has to be NO. Reporting the floor would quietly promise somebody a
 * bill they never agreed to.
 *
 * NULL, NEVER 0, for `-` / absent / unparseable. Tabelog prints 「-」 when a venue publishes no
 * dinner band, and NULL is 「we do not know what dinner costs here」 — a state 0021 already
 * handles (a NULL price fails a budget MUST closed and is reported as coverage). A 0 would say
 * the venue is free, which is both wrong and flattering.
 *
 * WHAT IS STRIPPED, and nothing else: the currency mark, thousands separators, and the
 * full-width tilde Tabelog uses as its range separator (U+FF5E; the visually identical wave
 * dash U+301C is accepted too, because which of the two a page carries depends on the encoder,
 * not on the venue). FULL-WIDTH DIGITS ARE NOT ACCEPTED: the test is ASCII `[0-9]+` only, so
 * 「￥８,０００」 records NULL rather than a guess — the same line 0027's tests already drew
 * when they established that 「４.２」 is not read as 4.2.
 *
 * An open-ended TOP (`￥50,000～`) has no upper bound to take, so it is NULL — hotPepperBudgetYen
 * makes the same call about 「5001円以上」. An open-ended BOTTOM (`～￥999`) does have one, and 999
 * is a perfectly good answer, so that form is read.
 */
function tabelogBudgetYen(band: string | null): number | null {
  if (band === null) return null;
  const text = band.trim();
  if (text.length === 0) return null;
  // Tabelog's "no band" mark, in the four dashes a page might carry it as.
  if (/^[-−–—－]$/.test(text)) return null;
  const parts = text.replace(/[￥¥,，]/g, "").split(/[～〜~]/);
  if (parts.length > 2) return null;
  const upper = parts[parts.length - 1].trim();
  if (!/^[0-9]+$/.test(upper)) return null;
  // A lower bound that is present but unreadable means we do not understand the band at all,
  // so we do not get to keep the half of it we liked.
  if (parts.length === 2) {
    const lower = parts[0].trim();
    if (lower.length > 0 && !/^[0-9]+$/.test(lower)) return null;
  }
  const yen = Number(upper);
  if (!Number.isFinite(yen) || yen <= 0) return null;
  return Math.round(yen);
}

/** A yen figure read back out of the resolution CACHE, where it is already a number. Mirrors
 * tabelogReviewCount's job for the count: a cached payload is ours, but it is still parsed
 * rather than trusted, because it may have been written by an older version of this file. 0 is
 * not a legal value (migration 0028's CHECK), so it is refused here too. */
function tabelogStoredYen(value: unknown): number | null {
  const num = typeof value === "number" ? value : Number(
    typeof value === "string" ? value : NaN,
  );
  if (!Number.isFinite(num) || num <= 0) return null;
  return Math.round(num);
}

/** The subset of a shortlisted candidate tabelogResolve needs. Cached candidates are not
 * `Candidate` objects, so this is the shape both paths can produce. */
interface TabelogCandidate {
  place_id: string;
  name: string | null;
  phone: string | null;
}

/** A confirmed Tabelog identity. `matched_by` records which search found the page; the match
 * itself was an exact telephone comparison either way. */
interface TabelogResolution {
  tabelog_id: string;
  rating: number | null;
  review_count: number | null;
  /** The dinner band's upper bound in yen, or null. Same page, same parse, no extra request. */
  budget_yen: number | null;
  name: string | null;
  matched_by: "phone_search" | "name_search";
  source_url: string;
}

/**
 * The Tabelog page for one shortlisted candidate, or null.
 *
 * ENTITY RESOLUTION IS AN EXACT TELEPHONE MATCH AND NOTHING ELSE. We hold
 * `places.nationalPhoneNumber` for each candidate; a Tabelog venue page states its own number
 * in its schema.org block; the match is accepted if and only if the two normalise to the same
 * digits. There is deliberately NO name-similarity fallback and NO coordinate fallback, for
 * exactly the reason hotPepperIdByPhone gives above: joining these providers on coordinates
 * resolved 0 of 10 real Shinjuku venues (the nearest shop was 147-466 m away), Google serves
 * romanised or aliased names for many Japanese venues (「味斗 新宿店」 arrives as "IZAKAYA
 * AJITO"), and a MEDIUM-confidence match here would attribute one restaurant's rating and
 * review count to another. Unresolved returns null, which is the honest answer and the state
 * migration 0027 records as NULL rather than as a guess.
 *
 * A keyword search is used only to FIND candidate pages; it never decides identity. Two
 * searches are tried, in this order, and both cost one request:
 *
 *   1. the telephone number as Google formats it (`03-5361-1851`). Tabelog's search box does
 *      match a hyphenated number — measured on six live venues, it found the right venue for
 *      three of them and nothing at all for the other three, i.e. it is precise but far from
 *      complete. Bare digits (`0353611851`) match nothing, so the formatted spelling is the
 *      one sent. More than one hit means the number is not behaving as an identifier, so
 *      nothing is chosen rather than the first — the same rule hotPepperIdByPhone applies —
 *      and the name search below is not tried either: a telephone number that matches two
 *      venues is a reason to stop asking about this candidate, not a reason to ask differently.
 *   2. the venue name, only when the phone search found NOTHING, and only when the search
 *      returns a small enough result set (≤ 3) for the name to be acting as an identifier
 *      rather than as a category. Only the top hit is opened: the ranking is Tabelog's opinion
 *      and we are not going to shop around inside it for a venue whose phone number agrees.
 *
 * Either way exactly one venue page is opened, and its telephone number is the only thing that
 * can turn a hit into a resolution. Worst case per candidate: three requests.
 */
async function tabelogResolve(
  candidate: TabelogCandidate,
  budget: TabelogBudget,
  incidents: ProviderIncident[],
): Promise<TabelogResolution | null> {
  if (!TABELOG_ENRICHMENT_ENABLED) return null;
  const digits = tabelogPhoneDigits(candidate.phone);
  // No telephone number means no identity check is possible, so there is nothing to look for
  // and no request is made. Roughly one Places venue in a hundred is in this state.
  if (!digits || !candidate.phone) return null;

  const attempts: {
    matchedBy: TabelogResolution["matched_by"];
    hits: TabelogHit[];
  }[] = [];
  const byPhone = await tabelogSearch(
    candidate.phone,
    "tabelog.search.tel",
    budget,
    incidents,
  );
  if (byPhone.length === 1) {
    attempts.push({ matchedBy: "phone_search", hits: byPhone });
  } else if (byPhone.length === 0 && candidate.name) {
    const byName = await tabelogSearch(
      candidate.name,
      "tabelog.search.name",
      budget,
      incidents,
    );
    if (byName.length >= 1 && byName.length <= 3) {
      attempts.push({ matchedBy: "name_search", hits: byName.slice(0, 1) });
    }
  }

  for (const attempt of attempts) {
    const hit = attempt.hits[0];
    const html = await tabelogFetchHtml(
      hit.url,
      "tabelog.venue",
      budget,
      incidents,
    );
    if (html === null) return null;
    const venue = tabelogParseVenue(html, hit.id, hit.url, incidents);
    if (!venue) return null;
    // THE match. Not "close enough", not "same name": the same digits.
    if (tabelogPhoneDigits(venue.phone) !== digits) return null;
    return {
      tabelog_id: venue.tabelog_id,
      rating: venue.rating,
      review_count: venue.review_count,
      budget_yen: venue.budget_yen,
      name: venue.name,
      matched_by: attempt.matchedBy,
      source_url: venue.source_url,
    };
  }
  return null;
}

// --- Google Routes ----------------------------------------------------------

interface TravelMatrixResult {
  // placeId -> participantId -> minutes
  minutes: Map<string, Record<string, number>>;
  // placeId -> the raw elements that produced it. The element's originIndex is
  // only meaningful against the request that returned it, so the participant it
  // resolved to travels with it.
  raw: Map<string, { participant_id: string; element: unknown }[]>;
}

type RouteMatrixRow = {
  originIndex?: number;
  destinationIndex?: number;
  duration?: string;
  condition?: string;
};

async function travelMatrix(
  origins: Origin[],
  destinations: { placeId: string; location: LatLng }[],
  incidents: ProviderIncident[],
): Promise<TravelMatrixResult> {
  const result: TravelMatrixResult = { minutes: new Map(), raw: new Map() };
  if (origins.length === 0 || destinations.length === 0) return result;

  const waypoint = (location: LatLng) => ({
    waypoint: {
      location: { latLng: { latitude: location.lat, longitude: location.lng } },
    },
  });

  const fetchRows = async (
    originChunk: Origin[],
    chunk: { placeId: string; location: LatLng }[],
    travelMode: "TRANSIT" | "WALK",
  ): Promise<RouteMatrixRow[] | null> => {
    try {
      const res = await fetch(
        "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Goog-Api-Key": GOOGLE_ROUTES_API_KEY,
            "X-Goog-FieldMask":
              "originIndex,destinationIndex,duration,condition",
          },
          body: JSON.stringify({
            origins: originChunk.map((o) => waypoint(o.location)),
            destinations: chunk.map((d) => waypoint(d.location)),
            travelMode,
          }),
        },
      );
      if (!res.ok) {
        recordIncident(
          incidents,
          "google_routes",
          "routes.computeRouteMatrix",
          res.status,
          await bodyText(res),
        );
        return null;
      }
      const rows = await res.json();
      return Array.isArray(rows) ? rows : [];
    } catch (err) {
      recordIncident(
        incidents,
        "google_routes",
        "routes.computeRouteMatrix",
        null,
        String(err),
      );
      return null;
    }
  };

  const merge = (
    rows: RouteMatrixRow[],
    originChunk: Origin[],
    chunk: { placeId: string; location: LatLng }[],
    travelMode: "TRANSIT" | "WALK",
    onlyIfAbsent: boolean,
  ) => {
    for (const row of rows) {
      // We ask for `condition` in the FieldMask, so an element that does not
      // say ROUTE_EXISTS has no usable route (ROUTE_NOT_FOUND still carries a
      // duration). Proto3 JSON omits enums only at their zero value, which is
      // UNSPECIFIED — never ROUTE_EXISTS — so a missing condition is not a
      // promise and is ignored too.
      if (row.condition !== "ROUTE_EXISTS") continue;
      if (typeof row.duration !== "string") continue;
      // Proto3 JSON also omits int fields at their default, so index 0 simply
      // is not there: treating absent as 0 stops the first origin and the
      // first destination from being silently dropped.
      const originIndex = row.originIndex ?? 0;
      const destinationIndex = row.destinationIndex ?? 0;
      const seconds = Number(row.duration.replace(/s$/, ""));
      if (!Number.isFinite(seconds)) continue;
      const dest = chunk[destinationIndex];
      const origin = originChunk[originIndex];
      if (!dest || !origin) continue;
      const entry = result.minutes.get(dest.placeId) ?? {};
      // A WALK fill must never overwrite a real TRANSIT leg.
      if (onlyIfAbsent && entry[origin.participantId] !== undefined) continue;
      entry[origin.participantId] = Math.round(seconds / 60);
      result.minutes.set(dest.placeId, entry);
      const rawRows = result.raw.get(dest.placeId) ?? [];
      rawRows.push({
        participant_id: origin.participantId,
        element: { ...row, travelMode },
      });
      result.raw.set(dest.placeId, rawRows);
    }
  };

  // Batch to the TRANSIT element cap: chunk the origins first, then give each
  // origin chunk as many destinations as the remaining element budget allows.
  for (
    let oOffset = 0;
    oOffset < origins.length;
    oOffset += ROUTES_MAX_ORIGINS_PER_REQUEST
  ) {
    const originChunk = origins.slice(
      oOffset,
      oOffset + ROUTES_MAX_ORIGINS_PER_REQUEST,
    );
    const destinationsPerRequest = Math.max(
      1,
      Math.floor(ROUTES_MAX_ELEMENTS_PER_REQUEST / originChunk.length),
    );
    for (
      let dOffset = 0;
      dOffset < destinations.length;
      dOffset += destinationsPerRequest
    ) {
      const chunk = destinations.slice(
        dOffset,
        dOffset + destinationsPerRequest,
      );
      const transitRows = await fetchRows(originChunk, chunk, "TRANSIT");
      if (transitRows) merge(transitRows, originChunk, chunk, "TRANSIT", false);

      // TRANSIT-only routing has a blind spot exactly where discovery looks hardest.
      // Candidates are found AROUND the participants' stations, and for a hop of a few
      // hundred metres there is no train — Routes answers ROUTE_NOT_FOUND (measured:
      // 池袋駅 to a venue 400m away). Without a fallback the leg stays unknown, the
      // travel-time MUST fails closed, and the venues nearest the group are excluded
      // BECAUSE they are near. So the pairs TRANSIT could not route are retried on
      // foot, which is how a person actually covers that distance; a WALK answer for a
      // genuinely far pair is an honest large number, which the MUST then judges
      // honestly. The retry re-sends the whole rectangle (a missing-pairs subset is
      // not rectangular) and merges absent legs only, so no TRANSIT leg is replaced.
      const unfilled = chunk.some((d) => {
        const entry = result.minutes.get(d.placeId) ?? {};
        return originChunk.some((o) => entry[o.participantId] === undefined);
      });
      if (!unfilled) continue;
      const walkRows = await fetchRows(originChunk, chunk, "WALK");
      if (walkRows) merge(walkRows, originChunk, chunk, "WALK", true);
    }
  }
  return result;
}

// --- Meeting areas -----------------------------------------------------------

// Not the pure geographic midpoint: weight toward reducing the worst
// individual commute by pulling candidates toward the farthest participant.
function meetingAreas(points: LatLng[]): LatLng[] {
  if (points.length === 0) return [];
  const centroid = {
    lat: points.reduce((s, p) => s + p.lat, 0) / points.length,
    lng: points.reduce((s, p) => s + p.lng, 0) / points.length,
  };
  let farthest = points[0];
  let maxD = -1;
  for (const p of points) {
    const d = (p.lat - centroid.lat) ** 2 + (p.lng - centroid.lng) ** 2;
    if (d > maxD) {
      maxD = d;
      farthest = p;
    }
  }
  const pulled = {
    lat: centroid.lat + (farthest.lat - centroid.lat) * 0.35,
    lng: centroid.lng + (farthest.lng - centroid.lng) * 0.35,
  };
  const midToFarthest = {
    lat: (centroid.lat + farthest.lat) / 2,
    lng: (centroid.lng + farthest.lng) / 2,
  };
  const areas = [pulled, centroid, midToFarthest];
  const unique: LatLng[] = [];
  for (const a of areas) {
    if (
      !unique.some((u) =>
        Math.abs(u.lat - a.lat) < 0.003 && Math.abs(u.lng - a.lng) < 0.003
      )
    ) unique.push(a);
  }
  return unique.slice(0, 3);
}

// Did the search space materially shift? Every zone we are about to search has
// to be close to a zone we already searched; a brand new zone (someone joined,
// someone changed their travel reference) means the cached candidate set was
// drawn around the wrong place.
// No zone to search at all (nobody's travel reference resolved to a place) is
// not a shift: there is no new search space to compare against, so claiming one
// moved would be an invention — and it would force a rediscovery that has
// nowhere to search.
function zonesShifted(
  areas: LatLng[],
  stored: { lat: number; lng: number }[],
): boolean {
  if (areas.length === 0) return false;
  if (stored.length === 0) return true;
  return areas.some((a) =>
    !stored.some((s) =>
      Math.abs(s.lat - a.lat) <= ZONE_SHIFT_TOLERANCE_DEG &&
      Math.abs(s.lng - a.lng) <= ZONE_SHIFT_TOLERANCE_DEG
    )
  );
}

function minutesAgoMs(minutes: number): number {
  return Date.now() - minutes * 60_000;
}

function freshAt(timestamp: string | null, cutoffMs: number): boolean {
  if (!timestamp) return false;
  const parsed = Date.parse(timestamp);
  return Number.isFinite(parsed) && parsed > cutoffMs;
}

// --- Handler -----------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: "server misconfigured" }, 500);
  }
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const eventId = (body as { event_id?: unknown })?.event_id;
  if (typeof eventId !== "string") {
    return json({ error: "event_id (uuid) is required" }, 400);
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: participants, error: pErr } = await supabase
    .from("participants")
    .select("id, travel_reference, travel_reference_place_id")
    .eq("event_id", eventId);
  if (pErr) return json({ error: pErr.message }, 500);
  if (!participants || participants.length === 0) {
    return json({ error: "event has no participants" }, 404);
  }

  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: {
      headers: { Authorization: req.headers.get("Authorization") ?? "" },
    },
  });
  const { data: membership, error: membershipError } = await caller
    .from("participants")
    .select("id")
    .eq("event_id", eventId)
    .limit(1);
  if (membershipError || !membership || membership.length === 0) {
    return json({ error: "not a participant of this event" }, 403);
  }

  const { data: participantOrigins, error: originErr } = await supabase
    .from("participant_origins")
    .select("participant_id, latitude, longitude")
    .in("participant_id", participants.map((participant) => participant.id));
  if (originErr) return json({ error: originErr.message }, 500);

  // The Places key is NOT checked here. It used to be, and that made a fully cached
  // event fail for want of something it never uses: the read-through cache below can
  // answer with no provider call at all, which is exactly what the seeded demo relies
  // on. The check moved down to the one branch that actually calls Places.

  const { data: wants, error: wErr } = await supabase
    .from("participant_constraints")
    .select("normalized_type, normalized_value")
    .eq("event_id", eventId)
    .eq("kind", "WANT");
  if (wErr) return json({ error: wErr.message }, 500);

  const cuisineTags = (wants ?? [])
    .filter((w) => w.normalized_type === "cuisine")
    .flatMap((w) => {
      const value = w.normalized_value as { include?: unknown };
      return Array.isArray(value.include)
        ? value.include.filter((c): c is string => typeof c === "string")
        : [];
    });

  const incidents: ProviderIncident[] = [];

  // What the Tabelog phase did, reported on every response so the flag's state is observable
  // from the outside rather than inferred from whether any column got populated. With the flag
  // off these numbers stay exactly as initialised, which is itself the assertion that no
  // request was made: `requests` is incremented in tabelogFetchHtml, the only function in this
  // file that talks to tabelog.com.
  const tabelogSummary = {
    enabled: TABELOG_ENRICHMENT_ENABLED,
    shortlist_size: 0,
    resolved: 0,
    resolved_from_cache: 0,
    unresolved: 0,
    not_attempted: 0,
    requests: 0,
  };

  // Never fatal: losing a raw payload or an incident row must not fail a search
  // that otherwise worked, so both of these log and move on. They close over the
  // service-role client rather than taking it as a parameter, which keeps the
  // generated PostgREST types on the client itself.
  const persistSourceRecords = async (records: SourceRecord[]) => {
    if (records.length === 0) return;
    const fetchedAt = new Date().toISOString();
    const { error } = await supabase.from("restaurant_source_records").upsert(
      records.map((r) => ({ ...r, fetched_at: fetchedAt })),
      { onConflict: "place_id,provider,source_id" },
    );
    if (error) {
      console.error("restaurant_source_records upsert failed", error.message);
    }
  };

  const persistIncidents = async () => {
    if (incidents.length === 0) return;
    const occurredAt = new Date().toISOString();
    const { error } = await supabase.from("provider_incidents").insert(
      incidents.map((i) => ({
        event_id: eventId,
        provider: i.provider,
        operation: i.operation,
        status_code: i.status_code,
        message: i.message,
        occurred_at: occurredAt,
      })),
    );
    if (error) {
      console.error("provider_incidents insert failed", error.message);
    }
  };

  // 1. Resolve each participant's travel reference to a location.
  //
  // The canonical travel_reference/place-id pair is tried first. The private coordinate
  // supplement is a fallback when no place id was supplied or Places cannot resolve it; it
  // never overrides the canonical fields. `doesnt_matter` opts out before either source is
  // considered, even if a coordinate row still exists.
  const origins: Origin[] = [];
  const unresolved: { participant_id: string; reason: string }[] = [];
  const unconstrained: string[] = [];
  const locationByPlaceId = new Map<string, LatLng | null>();
  const coordinateByParticipant = new Map<string, LatLng>();
  for (const row of (participantOrigins ?? []) as ParticipantOriginRow[]) {
    if (!Number.isFinite(row.latitude) || !Number.isFinite(row.longitude)) {
      continue;
    }
    coordinateByParticipant.set(row.participant_id, {
      lat: row.latitude,
      lng: row.longitude,
    });
  }
  for (const p of participants as ParticipantRow[]) {
    if (p.travel_reference === "doesnt_matter") {
      // No travel constraint by definition: they are not an origin, and their
      // absence must not stop the event.
      unconstrained.push(p.id);
      continue;
    }
    const referencePlaceId = p.travel_reference_place_id;
    if (referencePlaceId) {
      // Colleagues share an office: one Places lookup per distinct place id.
      if (!locationByPlaceId.has(referencePlaceId)) {
        locationByPlaceId.set(
          referencePlaceId,
          await placeLocation(referencePlaceId, incidents),
        );
      }
      const canonicalLocation = locationByPlaceId.get(referencePlaceId) ?? null;
      if (canonicalLocation) {
        origins.push({ participantId: p.id, location: canonicalLocation });
        continue;
      }
    }

    const coordinateFallback = coordinateByParticipant.get(p.id);
    if (coordinateFallback) {
      origins.push({ participantId: p.id, location: coordinateFallback });
      continue;
    }

    unresolved.push({
      participant_id: p.id,
      reason: referencePlaceId
        ? "travel_reference_place_lookup_failed"
        : "travel_reference_place_id_missing",
    });
  }
  // Deliberately NO blanket origin precondition here. An origin buys exactly two
  // things — the meeting areas provider discovery searches around, and the travel
  // legs Routes has not already cached — so demanding one up front failed
  // searches that never needed it: budget, dietary, allergy, room and smoking
  // MUSTs are decided server-side from data we already hold, and a fully cached
  // event needs no provider call whatsoever. The requirement is asserted in
  // step 4, once the cache has told us whether discovery has to run at all.

  // 2. Candidate meeting areas, and the zones we searched last time. With no
  // resolved origin there is no new search space at all, which zonesShifted()
  // reads as "not shifted" rather than as a move.
  const areas = meetingAreas(origins.map((o) => o.location));
  const { data: storedZones } = await supabase
    .from("meeting_zones")
    .select("lat, lng")
    .eq("event_id", eventId);
  const searchSpaceShifted = zonesShifted(areas, storedZones ?? []);

  // 3. Read-through cache: which of this event's candidates are still fresh?
  const discoveryCutoffMs = minutesAgoMs(DISCOVERY_TTL_MINUTES);
  const travelCutoffMs = minutesAgoMs(TRAVEL_TTL_MINUTES);
  const { data: candidateScope, error: scopeReadErr } = await supabase
    .from("event_candidate_scopes")
    .select("generation")
    .eq("event_id", eventId)
    .maybeSingle();
  if (scopeReadErr) return json({ error: scopeReadErr.message }, 500);
  let cachedCandidateQuery = supabase
    .from("event_restaurant_candidates")
    .select("place_id, discovered_at")
    .eq("event_id", eventId);
  if (typeof candidateScope?.generation === "string") {
    cachedCandidateQuery = cachedCandidateQuery.eq(
      "scope_generation",
      candidateScope.generation,
    );
  }
  const { data: cachedCandidateRows, error: ccErr } =
    await cachedCandidateQuery;
  if (ccErr) return json({ error: ccErr.message }, 500);
  const allCandidateIds = (cachedCandidateRows ?? []).map((row) =>
    row.place_id as string
  );
  const freshPlaceIds = (cachedCandidateRows ?? [])
    .filter((row) => freshAt(row.discovered_at, discoveryCutoffMs))
    .map((row) => row.place_id as string);

  // Discovery searches *around* the meeting zones, and the zones are built from
  // origins, so with no resolved origin the providers cannot be called at all.
  // Refusing the run because the cache went stale would then punish the caller for
  // something they cannot fix from here, so serve the candidates we already have and
  // say they are stale. Freshness only decides anything when a refresh is possible.
  const canDiscover = origins.length > 0;
  const staleServed = !canDiscover && freshPlaceIds.length === 0 &&
    allCandidateIds.length > 0;
  const cachedPlaceIds = staleServed ? allCandidateIds : freshPlaceIds;

  const discoveryNeeded = canDiscover &&
    (freshPlaceIds.length === 0 || searchSpaceShifted);
  const discoverySkipReason = discoveryNeeded
    ? null
    : staleServed
    ? "stale_candidates_no_resolvable_origin"
    : "fresh_candidates_for_unchanged_meeting_zones";

  // 4. The only genuinely hopeless case: nobody's location is known, so the
  // providers cannot be called, and there is not a single cached candidate to fall
  // back on. That stays a 422, and it names the participants we could not place so
  // the caller can say why (a missing travel_reference_place_id is a fixable UI
  // state, not a server error).
  // Everything else proceeds: a cache hit needs no origin, stale candidates beat no
  // answer when no refresh is possible, and a partially resolved event searches
  // around the origins it has and leaves the unresolved participants out of the
  // travel matrix.
  // Discovery is the only thing that talks to Places, so this is where a missing key is
  // genuinely fatal — and reported as a misconfiguration rather than as a search result,
  // because degrading silently would hand back an empty shortlist that looks like "no
  // restaurant fits" when the truth is that nobody called a provider.
  if (discoveryNeeded && !GOOGLE_PLACES_API_KEY) {
    await persistIncidents();
    return json({ error: "GOOGLE_PLACES_API_KEY not configured" }, 500);
  }

  if (!canDiscover && cachedPlaceIds.length === 0) {
    await persistIncidents();
    return json({
      error: "could not resolve any travel reference",
      unresolved_participants: unresolved,
      travel_unconstrained_participants: unconstrained,
      provider_incidents: incidentSummary(incidents),
    }, 422);
  }

  // 5+6. Places + Hot Pepper per area, dedupe by place_id — only when the cache
  // cannot answer.
  const byPlaceId = new Map<string, Candidate>();
  const sourceRecords: SourceRecord[] = [];
  if (discoveryNeeded) {
    for (const area of areas) {
      const places = await searchRestaurants(area, cuisineTags, incidents);
      for (const { candidate, raw } of places) {
        if (!byPlaceId.has(candidate.place_id)) {
          byPlaceId.set(candidate.place_id, candidate);
          sourceRecords.push({
            place_id: candidate.place_id,
            provider: "google_places",
            source_id: candidate.place_id,
            payload: raw,
          });
        }
      }
      // Enrich Places candidates with Hot Pepper's JP-specific attributes, joined on the
      // one identifier both providers state exactly: the telephone number. See
      // hotPepperIdByPhone for the measurements that replaced coordinate proximity.
      //
      // The lookups run in a small batch rather than all at once: Hot Pepper's throttling is
      // undocumented, and a burst that gets us rate-limited would cost the whole shortlist's
      // enrichment rather than one venue's.
      const unresolved = [...byPlaceId.values()].filter((c) =>
        !c.hotpepper_id && c.phone
      );
      const idByPlace = new Map<string, string>();
      for (let i = 0; i < unresolved.length; i += HOTPEPPER_LOOKUP_BATCH) {
        const slice = unresolved.slice(i, i + HOTPEPPER_LOOKUP_BATCH);
        const ids = await Promise.all(
          slice.map((c) => hotPepperIdByPhone(c.phone as string, incidents)),
        );
        slice.forEach((c, n) => {
          const id = ids[n];
          if (id) idByPlace.set(c.place_id, id);
        });
      }
      const byHotPepperId = new Map<string, Candidate>();
      for (const [placeId, hpId] of idByPlace) {
        const candidate = byPlaceId.get(placeId);
        // Two Places venues resolving to one Hot Pepper shop means the identity is ambiguous,
        // so neither is enriched: attributing 個室 or 禁煙 to the wrong one of a pair is the
        // failure this whole change exists to prevent.
        if (!candidate) continue;
        if (byHotPepperId.has(hpId)) {
          byHotPepperId.delete(hpId);
          continue;
        }
        byHotPepperId.set(hpId, candidate);
      }
      const hpShops = await hotPepperShopsByIds(
        [...byHotPepperId.keys()],
        incidents,
      );
      for (const shop of hpShops) {
        const best = byHotPepperId.get(shop.id);
        if (best && !best.hotpepper_id) {
          best.hotpepper_id = shop.id;
          best.room_type = hotPepperRoomType(shop) ?? best.room_type;
          best.price_yen_estimate = hotPepperBudgetYen(shop) ??
            best.price_yen_estimate;
          // Assigned rather than `??`-merged like the two above: Places contributes
          // no smoking field whatsoever, so there is no earlier value in this run to
          // preserve. Staying null when the shop's 禁煙席 field is unusable is what
          // makes the write path leave a previously recorded policy alone.
          best.hotpepper_non_smoking = hotPepperNonSmokingText(
            shop.non_smoking,
          );
          // Assigned rather than `??`-merged for the same reason: Places contributes no
          // photograph (its own is a separate paid SKU we never request), so there is no
          // earlier value in this run to preserve. Staying null here does NOT leave a stale URL
          // alone — this candidate is matched, so the write below sends the key and null
          // retracts. See fn_record_provider_photo in migration 0028.
          best.photo_url = hotPepperPhotoUrl(shop);
          // Hot Pepper's genre is Japanese and often compounded (「イタリアン・フレンチ」), so it
          // is translated into the same closed vocabulary and merged rather than appended raw —
          // otherwise it joined Google's identifier in matching nothing. Re-canonicalising the
          // whole list keeps it deduped and sorted whichever provider answered first.
          if (shop.genre?.name) {
            best.cuisine_tags = canonicalCuisineTags([
              ...best.cuisine_tags,
              shop.genre.name,
            ]);
          }
          // dietary/allergy tags: only from verified structured attributes —
          // Hot Pepper's basic response has none, so they stay empty
          // ("unverified", never "confirmed safe"). The upsert below is
          // additive, so staying empty no longer erases what another pass
          // already confirmed.
          sourceRecords.push({
            place_id: best.place_id,
            provider: "hotpepper",
            source_id: shop.id,
            payload: shop,
          });
        }
      }
    }
  }

  const fetchedCandidates = [...byPlaceId.values()];

  // 7. Normalized upsert. Additive by construction (see 0017): an empty
  // dietary/allergy/room/cuisine value never overwrites a populated one, and the
  // legacy travel JSONB is merged rather than replaced.
  //
  // accessibility_tags travels in the SAME payload but is written by a SECOND rpc:
  // 0017's fn_record_provider_candidates promises never to touch that column and
  // is a shipped migration, so 0022 adds fn_record_provider_accessibility beside
  // it rather than rewriting it. The key is included ONLY when Places actually
  // returned an accessibilityOptions object — an absent key means "nothing
  // learned, change nothing", a present one (even empty) is the current answer and
  // may retract a stale tag. fn_record_provider_candidates ignores the key.
  //
  // `hotpepper_non_smoking` and `attributions` (migration 0023) ride along the same
  // way, for the same reason and with the same present/absent contract, each with
  // its own writer. Both keys are omitted when the provider said nothing this run:
  // for smoking that is the common case, because only candidates MATCHED in Hot
  // Pepper have any answer at all and a Places-only candidate must not erase a
  // policy an earlier matched run recorded. 0017's writer ignores both keys.
  //
  // `photo_url` (migration 0028) is the fourth, with one difference worth stating: its key is
  // gated on `hotpepper_id` rather than on the value being non-null. Being MATCHED is what
  // makes Hot Pepper's silence an answer — a matched shop with no photograph should retract a
  // URL we stored last week, while an unmatched candidate (about 40% of live venues, because
  // the join is an exact telephone match and nothing weaker) has learned nothing and must not
  // erase anything.
  if (fetchedCandidates.length > 0) {
    const candidatePayload = fetchedCandidates.map((c) => ({
      place_id: c.place_id,
      name: c.name,
      hotpepper_id: c.hotpepper_id,
      price_yen_estimate: c.price_yen_estimate,
      room_type: c.room_type,
      cuisine_tags: c.cuisine_tags,
      dietary_tags: c.dietary_tags,
      allergy_safe_tags: c.allergy_safe_tags,
      atmosphere_tags: c.atmosphere_tags,
      rating: c.rating,
      user_rating_count: c.user_rating_count,
      ...(c.accessibility_tags === null
        ? {}
        : { accessibility_tags: c.accessibility_tags }),
      ...(c.hotpepper_non_smoking === null
        ? {}
        : { hotpepper_non_smoking: c.hotpepper_non_smoking }),
      ...(c.attributions === null ? {} : { attributions: c.attributions }),
      ...(c.hotpepper_id === null ? {} : { photo_url: c.photo_url }),
    }));
    const { error: recordErr } = await supabase.rpc(
      "fn_record_provider_candidates_v2",
      { p_event_id: eventId, p_candidates: candidatePayload },
    );
    if (recordErr) return json({ error: recordErr.message }, 500);

    // Reported rather than swallowed: losing this write would leave every venue
    // looking UNVERIFIED, which silently excludes them from an accessibility MUST
    // (0022 fails closed on purpose). That is a wrong shortlist, not a degraded
    // one, so it is surfaced exactly like the candidate write above.
    const { error: accessErr } = await supabase.rpc(
      "fn_record_provider_accessibility",
      { p_event_id: eventId, p_candidates: candidatePayload },
    );
    if (accessErr) return json({ error: accessErr.message }, 500);

    // Surfaced for the same reason as accessibility: without this write every venue
    // stays "unconfirmed", so a 禁煙 MUST excludes all of them until the group has
    // spent a negotiation round — the dead end migration 0023 exists to remove.
    // Swallowing the error would leave that looking like the provider's answer.
    const { error: smokingErr } = await supabase.rpc(
      "fn_record_provider_smoking_policy",
      { p_event_id: eventId, p_candidates: candidatePayload },
    );
    if (smokingErr) return json({ error: smokingErr.message }, 500);

    // Also surfaced, and here it is a licence question rather than a shortlist one:
    // if the credits Places requires alongside this content are not stored, a client
    // renders the content without them. Returning the shortlist anyway would be
    // choosing that silently, and the candidates are already persisted, so a retry
    // costs no provider call.
    const { error: attributionErr } = await supabase.rpc(
      "fn_record_provider_attributions",
      { p_event_id: eventId, p_candidates: candidatePayload },
    );
    if (attributionErr) return json({ error: attributionErr.message }, 500);

    // NOT surfaced as a 500, unlike the four above. Those decide the shortlist or a licence
    // obligation; a missing thumbnail changes nothing about which venues the group is shown or
    // what has to be credited alongside them (Recruit's credit rides on
    // provider_attributions, which is written above and IS fatal). Failing an entire search
    // over a photograph would make the search less reliable than the data is worth, so this
    // one is recorded as a provider incident and the shortlist is returned.
    const { error: photoErr } = await supabase.rpc(
      "fn_record_provider_photo",
      { p_event_id: eventId, p_candidates: candidatePayload },
    );
    if (photoErr) {
      recordIncident(
        incidents,
        "hotpepper",
        "gourmet.photo.record",
        null,
        photoErr.message,
      );
    }
  }

  // The zones this run actually searched (PRD §15), and the freshness signal for
  // the next run. Written after discovery so a provider outage cannot record a
  // zone we never managed to search.
  if (areas.length > 0) {
    await supabase.from("meeting_zones").upsert(
      areas.map((a, i) => ({
        event_id: eventId,
        lat: a.lat,
        lng: a.lng,
        rank: i + 1,
      })),
      { onConflict: "event_id,rank" },
    );
    await supabase
      .from("meeting_zones")
      .delete()
      .eq("event_id", eventId)
      .gt("rank", areas.length);
  }

  // A provider refresh replaces the previous active set; a cache-served run republishes the
  // resolved cached set. The recorder RPC above intentionally preserves provider records, while
  // this narrow scope RPC atomically advances one generation and removes stale associations.
  const activePlaceIds = [
    ...new Set(discoveryNeeded ? byPlaceId.keys() : cachedPlaceIds),
  ];
  const { error: scopeErr } = await supabase.rpc(
    "fn_replace_event_candidate_scope",
    { p_event_id: eventId, p_place_ids: activePlaceIds },
  );
  if (scopeErr) return json({ error: scopeErr.message }, 500);

  if (activePlaceIds.length === 0) {
    await persistSourceRecords(sourceRecords);
    await persistIncidents();
    return json(searchResponse({
      fetched: 0,
      cached: 0,
      total: 0,
      discoverySkipReason,
      searchSpaceShifted,
      legsFetched: 0,
      legsFromCache: 0,
      areas,
      unresolved,
      unconstrained,
      unroutable: [],
      incidents,
      tabelog: tabelogSummary,
    }));
  }

  // 8. Destination coordinates. New candidates carry theirs; cached ones are
  // recovered from the stored raw Places payload so a cache hit stays free of
  // provider calls. Place coordinates are Places content, so this only ever
  // reads a payload that is still inside the discovery TTL.
  const locations = new Map<string, LatLng>();
  for (const c of fetchedCandidates) {
    if (c.location) locations.set(c.place_id, c.location);
  }
  const needCoordinates = activePlaceIds.filter((id) => !locations.has(id));
  if (needCoordinates.length > 0) {
    const { data: rawRows } = await supabase
      .from("restaurant_source_records")
      .select("place_id, payload, fetched_at")
      .eq("provider", "google_places")
      .in("place_id", needCoordinates);
    for (const row of rawRows ?? []) {
      if (!freshAt(row.fetched_at, discoveryCutoffMs)) continue;
      const loc = (row.payload as {
        location?: { latitude?: number; longitude?: number };
      })?.location;
      if (typeof loc?.latitude !== "number") continue;
      if (typeof loc?.longitude !== "number") continue;
      locations.set(row.place_id as string, {
        lat: loc.latitude,
        lng: loc.longitude,
      });
    }
  }

  // 9. Travel matrix: only the (event, participant, place) legs we are missing.
  // A leg exists per ORIGIN, so an unresolved participant contributes no missing
  // leg and no Routes call: with nothing resolved there is nothing to route, and
  // the event still scores against whatever legs the cache already holds (the
  // scoring engine reads travel_matrix_cache through fn_travel_minutes, not this
  // set). `travel_legs_from_cache` therefore counts the legs THIS RUN would
  // otherwise have paid Routes for — not every leg the event has.
  const activeSet = new Set(activePlaceIds);
  const originIds = new Set(origins.map((o) => o.participantId));
  const { data: cachedLegs } = await supabase
    .from("travel_matrix_cache")
    .select("participant_id, place_id, fetched_at")
    .eq("event_id", eventId);
  const freshLegs = new Set<string>();
  for (const leg of cachedLegs ?? []) {
    if (!activeSet.has(leg.place_id as string)) continue;
    if (!originIds.has(leg.participant_id as string)) continue;
    if (!freshAt(leg.fetched_at, travelCutoffMs)) continue;
    freshLegs.add(`${leg.participant_id}|${leg.place_id}`);
  }

  const unroutable: string[] = [];
  // Group places that need the exact same participant set so every Routes
  // request is a full rectangle and we never pay for a leg we already have.
  const groups = new Map<
    string,
    {
      participantIds: string[];
      destinations: { placeId: string; location: LatLng }[];
    }
  >();
  for (const placeId of activePlaceIds) {
    const location = locations.get(placeId);
    const missing = origins
      .map((o) => o.participantId)
      .filter((participantId) => !freshLegs.has(`${participantId}|${placeId}`));
    if (missing.length === 0) continue;
    if (!location) {
      // No coordinates (a cached candidate whose Places payload has aged out):
      // keep whatever legs are cached rather than guessing a location.
      unroutable.push(placeId);
      continue;
    }
    const key = [...missing].sort().join(",");
    const group = groups.get(key) ??
      { participantIds: missing, destinations: [] };
    group.destinations.push({ placeId, location });
    groups.set(key, group);
  }

  const legs: { participant_id: string; place_id: string; minutes: number }[] =
    [];
  const routeRaw = new Map<
    string,
    { participant_id: string; element: unknown }[]
  >();
  for (const group of groups.values()) {
    const groupOrigins = origins.filter((o) =>
      group.participantIds.includes(o.participantId)
    );
    const matrix = await travelMatrix(
      groupOrigins,
      group.destinations,
      incidents,
    );
    for (const [placeId, byParticipant] of matrix.minutes) {
      for (const [participantId, minutes] of Object.entries(byParticipant)) {
        legs.push({
          participant_id: participantId,
          place_id: placeId,
          minutes,
        });
      }
    }
    for (const [placeId, rows] of matrix.raw) {
      routeRaw.set(placeId, [...(routeRaw.get(placeId) ?? []), ...rows]);
    }
  }

  // 10. Persist travel times: authoritative per-event rows plus the legacy JSONB
  // that fn_travel_minutes falls back to.
  if (legs.length > 0) {
    const { error: legErr } = await supabase.rpc("fn_record_travel_minutes", {
      p_event_id: eventId,
      p_legs: legs,
    });
    if (legErr) return json({ error: legErr.message }, 500);
  }

  // 11. Raw payloads, kept separate from the normalized records. Routes matrices
  // are event-scoped (their origins are this event's participants), so the event
  // id is the source id.
  for (const [placeId, rows] of routeRaw) {
    sourceRecords.push({
      place_id: placeId,
      provider: "google_routes",
      source_id: eventId,
      payload: {
        travel_mode: "TRANSIT",
        elements: rows,
      },
    });
  }

  // 12. Tabelog enrichment — the third provider, the only one without an API, and the one
  // whose terms we do not have consent under. Read the block at the top of this file and the
  // "--- Tabelog ---" section before changing anything here.
  //
  // WITH THE FLAG OFF THIS WHOLE STEP IS A SINGLE `if`. Not a request, not a parse, not a
  // database read, not a column written: the search behaves exactly as it did before this
  // feature existed, and `tabelog_enrichment.enabled: false` on the response says so.
  if (TABELOG_ENRICHMENT_ENABLED) {
    // 12a. THE SHORTLIST, AND WHY IT IS NOT THE CANDIDATE SET. Enrichment runs on venues that
    // have already passed FEASIBILITY (fn_candidate_is_feasible — every MUST, evaluated by the
    // database, which is why it is asked rather than reimplemented here), capped at
    // TABELOG_MAX_VENUES. Discovery typically returns ~30 venues per event and most of them
    // are excluded by somebody's budget, room or travel MUST before anyone sees them; scraping
    // all of them would be six times the requests for data on venues that will never be shown.
    // Enriching only the shortlist is also what keeps the request volume
    // defensible at a site that has not agreed to be read by a program.
    //
    // Feasibility needs restaurant_features and the travel legs, so this step deliberately
    // sits AFTER the candidate upsert (step 7) and the travel-matrix write (step 10).
    //
    // WHICH five, when more than five are feasible, is a REQUEST BUDGET and not a ranking. The
    // order is place_id, which is stable and arbitrary on purpose: the shortlist the group
    // actually sees is decided later by fn_score_feasible_candidates, and ordering these five
    // by some quality guess of our own would be inventing a second opinion about ranking, in
    // the one place that has no business having one.
    //
    // SINCE MIGRATION 0028 THIS CHOICE DOES REACH SCORING, and the honest statement of the
    // consequence is: a venue we resolved on Tabelog is scored on two providers' percentiles
    // and a venue we did not is scored on Google's alone. That is why 0028 blends RANKS rather
    // than raw scores — the ranks are what make the two comparable, so being in this five
    // changes how much evidence a venue's quality rests on without shifting its level up or
    // down. `tabelog_ranked_candidates` in every score_breakdown records how large the Tabelog
    // pool actually was, so a client (or a reviewer) can see exactly how much weight this
    // arbitrary five is carrying rather than having to infer it.
    const shortlist: string[] = [];
    for (const placeId of [...activePlaceIds].sort()) {
      if (shortlist.length >= TABELOG_MAX_VENUES) break;
      const { data: isFeasible, error: feasibilityErr } = await supabase.rpc(
        "fn_candidate_is_feasible",
        { p_event_id: eventId, p_place_id: placeId },
      );
      if (feasibilityErr) {
        // The shortlist is the safety limit itself. If we cannot establish it we do not fall
        // back to "enrich the first five candidates" — we enrich nothing.
        recordIncident(
          incidents,
          "tabelog",
          "tabelog.shortlist",
          null,
          `fn_candidate_is_feasible failed (${feasibilityErr.message}); enriching nothing`,
        );
        shortlist.length = 0;
        break;
      }
      if (isFeasible === true) shortlist.push(placeId);
    }
    tabelogSummary.shortlist_size = shortlist.length;

    // 12b. THE CACHE, so a repeat search re-fetches nothing. A row is written for every venue
    // we ASKED about, resolved or not, and a fresh row of either kind stops us asking again:
    // "we looked and could not confirm which page this is" is exactly as much of an answer as
    // a resolution, and re-asking it every six hours would be the rudest thing in this file.
    const tabelogCutoffMs = minutesAgoMs(TABELOG_TTL_MINUTES);
    const resolutions = new Map<string, TabelogResolution>();
    const answeredFromCache = new Set<string>();
    if (shortlist.length > 0) {
      const { data: cachedTabelogRows } = await supabase
        .from("restaurant_source_records")
        .select("place_id, payload, fetched_at")
        .eq("provider", "tabelog")
        .in("place_id", shortlist);
      for (const row of cachedTabelogRows ?? []) {
        if (!freshAt(row.fetched_at, tabelogCutoffMs)) continue;
        answeredFromCache.add(row.place_id as string);
        const payload = row.payload as Record<string, unknown> | null;
        if (!payload || payload.resolved !== true) continue;
        if (typeof payload.tabelog_id !== "string") continue;
        resolutions.set(row.place_id as string, {
          tabelog_id: payload.tabelog_id,
          rating: tabelogRating(payload.rating),
          review_count: tabelogReviewCount(payload.review_count),
          // Absent on rows written before migration 0028, which is exactly the "we have no
          // band for this venue" state and needs no special case: a cache hit costs zero
          // requests and re-reading the page for a field alone would be the one thing the
          // 24-hour TTL exists to prevent.
          budget_yen: tabelogStoredYen(payload.budget_yen),
          name: typeof payload.name === "string" ? payload.name : null,
          matched_by: payload.matched_by === "name_search"
            ? "name_search"
            : "phone_search",
          source_url: typeof payload.source_url === "string"
            ? payload.source_url
            : "",
        });
      }
    }
    tabelogSummary.resolved_from_cache = resolutions.size;

    // 12c. The telephone number and name to search with. This run's candidates carry theirs;
    // a shortlisted venue that came from the candidate cache has its number recovered from the
    // stored Places payload, exactly as step 8 recovers coordinates and under the same rule —
    // only a payload still inside the discovery TTL is read, because Places content other than
    // the place id is short-lived by policy. Neither spelling of the number is ever persisted
    // by this step.
    const pending = shortlist.filter((id) => !answeredFromCache.has(id));
    const searchKeys = new Map<string, TabelogCandidate>();
    for (const c of fetchedCandidates) {
      searchKeys.set(c.place_id, {
        place_id: c.place_id,
        name: c.name,
        phone: c.phone,
      });
    }
    const needSearchKey = pending.filter((id) => !searchKeys.has(id));
    if (needSearchKey.length > 0) {
      const { data: placesRows } = await supabase
        .from("restaurant_source_records")
        .select("place_id, payload, fetched_at")
        .eq("provider", "google_places")
        .in("place_id", needSearchKey);
      for (const row of placesRows ?? []) {
        if (!freshAt(row.fetched_at, discoveryCutoffMs)) continue;
        const payload = row.payload as {
          nationalPhoneNumber?: unknown;
          displayName?: { text?: unknown };
        } | null;
        searchKeys.set(row.place_id as string, {
          place_id: row.place_id as string,
          name: typeof payload?.displayName?.text === "string"
            ? payload.displayName.text
            : null,
          phone: typeof payload?.nationalPhoneNumber === "string"
            ? payload.nationalPhoneNumber
            : null,
        });
      }
    }

    // 12d. Resolve, strictly one venue at a time. tabelogFetchHtml owns the ≥2 s gap, the
    // request ceiling and the deadline; this loop only has to not go behind its back, which is
    // why there is no Promise.all here.
    const budget = tabelogBudget();
    const cacheRecords: SourceRecord[] = [];
    for (const placeId of pending) {
      const key = searchKeys.get(placeId);
      // No telephone number: nothing to match on, so no request is made and NO cache row is
      // written either. There is no negative result to remember — we never asked.
      if (!key?.phone) {
        tabelogSummary.not_attempted++;
        continue;
      }
      const requestsBefore = budget.requests;
      const resolution = await tabelogResolve(key, budget, incidents);
      if (budget.requests === requestsBefore) {
        // The budget or the deadline stopped us before a single request went out. Same
        // reasoning as above: nothing was asked, so nothing is remembered, and the next search
        // may try again.
        tabelogSummary.not_attempted++;
        continue;
      }
      if (resolution) {
        resolutions.set(placeId, resolution);
        tabelogSummary.resolved++;
      } else {
        tabelogSummary.unresolved++;
      }
      // The cache row. EXTRACTED SCALARS AND A VERDICT, never the page: a Tabelog venue page
      // carries the whole review stream and the search page carries review excerpts, so
      // storing either would store the one thing we have decided never to hold. See section A
      // of migration 0027. The telephone number is not stored either — `phone_match` records
      // that the comparison was made and what it said, which is the auditable part.
      cacheRecords.push({
        place_id: placeId,
        provider: "tabelog",
        source_id: "resolution",
        payload: resolution === null
          ? {
            resolved: false,
            phone_match: "not_confirmed",
            requests: budget.requests - requestsBefore,
          }
          : {
            resolved: true,
            tabelog_id: resolution.tabelog_id,
            name: resolution.name,
            rating: resolution.rating,
            review_count: resolution.review_count,
            budget_yen: resolution.budget_yen,
            matched_by: resolution.matched_by,
            phone_match: "exact",
            source_url: resolution.source_url,
          },
      });
    }
    tabelogSummary.requests = budget.requests;

    // 12e. The write. One element per shortlisted venue, and the `tabelog` key present ONLY
    // for the ones whose identity was confirmed — the same present/absent contract 0022 and
    // 0023 use, and the reason an unresolved venue is left NULL instead of guessed. The four
    // columns are Tabelog's own (0027's three plus 0028's tabelog_budget_yen); `rating`,
    // `user_rating_count` and `price_yen_estimate` remain Google's and Hot Pepper's and are
    // not touched here. tabelog_budget_yen in particular is NOT price_yen_estimate: the budget
    // MUST is decided against a figure we hold under terms that permit it, and conflating the
    // two providers is what 0027 exists to avoid.
    if (shortlist.length > 0) {
      const { error: tabelogErr } = await supabase.rpc(
        "fn_record_tabelog_enrichment",
        {
          p_event_id: eventId,
          p_candidates: shortlist.map((placeId) => {
            const resolution = resolutions.get(placeId);
            return {
              place_id: placeId,
              ...(resolution
                ? {
                  tabelog: {
                    tabelog_id: resolution.tabelog_id,
                    rating: resolution.rating,
                    review_count: resolution.review_count,
                    budget_yen: resolution.budget_yen,
                  },
                }
                : {}),
            };
          }),
        },
      );
      if (tabelogErr) {
        // NOT fatal, unlike the four writes in step 7. Those decide the shortlist or a licence
        // obligation; this one is optional display data behind a flag, and failing an entire
        // search over it would make enabling the flag riskier than the data is worth. It is
        // recorded as a provider incident rather than swallowed, and the cache rows are
        // DROPPED so the next search retries instead of trusting a resolution that never
        // reached a column.
        recordIncident(
          incidents,
          "tabelog",
          "tabelog.record",
          null,
          tabelogErr.message,
        );
      } else {
        sourceRecords.push(...cacheRecords);
      }
    }
  }

  await persistSourceRecords(sourceRecords);
  await persistIncidents();

  return json(searchResponse({
    fetched: fetchedCandidates.length,
    cached: cachedPlaceIds.length,
    total: activePlaceIds.length,
    discoverySkipReason,
    searchSpaceShifted,
    legsFetched: legs.length,
    legsFromCache: freshLegs.size,
    areas,
    unresolved,
    unconstrained,
    unroutable,
    incidents,
    tabelog: tabelogSummary,
  }));
});

// --- Response ----------------------------------------------------------------

function searchResponse(args: {
  fetched: number;
  cached: number;
  total: number;
  discoverySkipReason: string | null;
  searchSpaceShifted: boolean;
  legsFetched: number;
  legsFromCache: number;
  areas: LatLng[];
  unresolved: { participant_id: string; reason: string }[];
  unconstrained: string[];
  unroutable: string[];
  incidents: ProviderIncident[];
  tabelog: {
    enabled: boolean;
    shortlist_size: number;
    resolved: number;
    resolved_from_cache: number;
    unresolved: number;
    not_attempted: number;
    requests: number;
  };
}): Record<string, unknown> {
  return {
    // Unchanged key and unchanged meaning: how many candidates this call
    // obtained from the providers. Clients read 0 as "showing previously
    // fetched candidates", which is exactly what a cache hit is.
    candidate_count: args.fetched,
    // What the event can actually be scored against right now.
    event_candidate_count: args.total,
    candidates_fetched: args.fetched,
    candidates_from_cache: args.cached,
    discovery_served_from_cache: args.discoverySkipReason !== null,
    discovery_skipped_reason: args.discoverySkipReason,
    search_space_shifted: args.searchSpaceShifted,
    travel_legs_fetched: args.legsFetched,
    travel_legs_from_cache: args.legsFromCache,
    meeting_zones: args.areas.map((a, i) => ({
      lat: a.lat,
      lng: a.lng,
      rank: i + 1,
    })),
    unresolved_participants: args.unresolved,
    travel_unconstrained_participants: args.unconstrained,
    unroutable_place_ids: args.unroutable,
    provider_incident_count: args.incidents.length,
    provider_incidents: incidentSummary(args.incidents),
    // The Tabelog phase, always reported — including `enabled: false`, which is the ordinary
    // case and the one worth being able to see. `requests` is the count tabelogFetchHtml
    // actually made, so `enabled: false` with `requests: 0` is a positive statement that
    // nothing was fetched from tabelog.com on this search, not an absence of evidence.
    tabelog_enrichment: args.tabelog,
  };
}

function incidentSummary(
  incidents: ProviderIncident[],
): Record<string, unknown>[] {
  return incidents.slice(0, INCIDENT_SUMMARY_MAX).map((i) => ({
    provider: i.provider,
    operation: i.operation,
    status_code: i.status_code,
    message: i.message,
  }));
}
