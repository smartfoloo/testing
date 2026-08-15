// POST /place-search — turns what a participant types into a real place, so their
// travel reference can be stored as `participants.travel_reference_place_id`.
//
// Why this function exists: `participants.travel_reference` is a UI CATEGORY
// ('office' | 'home' | 'station' | 'doesnt_matter'), never an address. The old
// restaurant-search fallback geocoded that literal word — "office Tokyo",
// "home Tokyo" — which invented an origin somewhere in Tokyo for every
// participant and made the meeting zones, the transit matrix and therefore the
// whole travel-fairness dimension fiction. Origins must come from a place the
// participant actually picked, and picking one needs a search.
//
// The search cannot happen in the client: the Google Places key lives only in
// Edge Function secrets (`supabase secrets set GOOGLE_PLACES_API_KEY=...`), the
// same boundary llm-assist and restaurant-search sit behind. The key is never
// returned, never logged, and scrubbed out of anything we do log.
//
// Billing: Places FieldMasks are deliberately minimal — one unrequested extra
// field silently upgrades the call to a pricier SKU. This asks for exactly the
// three fields it returns and nothing else:
//   places.id               -> place_id  (the only durable value; the rest is display)
//   places.displayName      -> name
//   places.formattedAddress -> address
// Note what is absent: `places.location` is NOT requested even though an origin
// is ultimately a coordinate, because restaurant-search already resolves the
// stored place id to a location itself (places.get with a `location` FieldMask)
// and paying for coordinates here would bill the picker for data it discards on
// every keystroke-debounced lookup. `rating` / `photos` / `openingHours` /
// `editorialSummary` must never be added here — restaurant-search accepts the
// pricier tier deliberately for its quality signal; a location picker has no
// such excuse.
//
// Privacy: only the place id is ever persisted (by fn_create_event /
// fn_join_event, from the client). Names and addresses are Places content, so
// they are passed straight through for display and stored nowhere.
//
// Request:  { "query": "渋谷駅" }
// Response: { "places": [{ "place_id", "name", "address" }] }
//           — exactly `PlaceSuggestion` in web/src/models/types.ts.
// A provider failure answers with an empty `places` array plus an `error`, so a
// caller that only reads `places` degrades to "no results" instead of crashing.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const GOOGLE_PLACES_API_KEY = Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// A picker fires one of these per debounced keystroke burst, so everything here
// is bounded: the query the user can send, the rows we ask Places for, and how
// long a stalled provider may hold the request open.
const MIN_QUERY_CHARS = 2;
const MAX_QUERY_CHARS = 120;
const MAX_RESULTS = 6;
const PROVIDER_TIMEOUT_MS = 8_000;

// Tokyo Station. The product is explicitly Tokyo coworker 飲み会 (PRD §1), and a
// bias — not a restriction — keeps "渋谷" from resolving to a Shibuya somewhere
// else while still allowing a commuter whose home is outside the ring. 45 km
// stays inside the 50 km cap the Places circle bias allows.
const TOKYO_CENTER = { latitude: 35.6812, longitude: 139.7671 };
const TOKYO_BIAS_RADIUS_METERS = 45_000;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/** The picker's row shape — snake_case because it is decoded straight into TS. */
interface PlaceSuggestion {
  place_id: string;
  name: string;
  address: string | null;
}

/** The subset of a Places (New) `Place` our FieldMask can actually return. */
interface PlacesTextSearchPlace {
  id?: unknown;
  displayName?: { text?: unknown };
  formattedAddress?: unknown;
}

// The key is a request-scoped secret and an error body can echo the request back,
// so nothing reaches the log or the response without passing through here.
function scrubSecrets(text: string): string {
  const out = GOOGLE_PLACES_API_KEY.length > 0
    ? text.split(GOOGLE_PLACES_API_KEY).join("[redacted]")
    : text;
  return out.slice(0, 400);
}

async function bodyText(res: Response): Promise<string> {
  try {
    return await res.text();
  } catch {
    return "";
  }
}

// Places returns Japanese addresses as "日本、〒150-0002 東京都渋谷区…". The country
// and the postal code are noise in a Japanese-only UI where every candidate is in
// Tokyo, and the row has one line to work with.
function tidyAddress(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value
    .replace(/^日本[、,]\s*/, "")
    .replace(/^〒\d{3}-?\d{4}\s*/, "")
    .trim();
  return trimmed.length > 0 ? trimmed : null;
}

function toSuggestion(place: PlacesTextSearchPlace): PlaceSuggestion | null {
  // A row without an id is unusable: the id is the whole point of the picker.
  if (typeof place.id !== "string" || place.id.length === 0) return null;
  const name = place.displayName?.text;
  return {
    place_id: place.id,
    // Falling back to the address keeps an unnamed row selectable rather than
    // rendering a blank button.
    name: typeof name === "string" && name.length > 0
      ? name
      : (tidyAddress(place.formattedAddress) ?? place.id),
    address: tidyAddress(place.formattedAddress),
  };
}

async function searchPlaces(
  query: string,
): Promise<{ places: PlaceSuggestion[]; failed: boolean }> {
  let data: { places?: PlacesTextSearchPlace[] };
  try {
    const res = await fetch(
      "https://places.googleapis.com/v1/places:searchText",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
          // Exactly the three fields returned below — see the billing note at
          // the top of this file before adding anything.
          "X-Goog-FieldMask":
            "places.id,places.displayName,places.formattedAddress",
        },
        body: JSON.stringify({
          textQuery: query,
          languageCode: "ja",
          regionCode: "JP",
          pageSize: MAX_RESULTS,
          locationBias: {
            circle: {
              center: TOKYO_CENTER,
              radius: TOKYO_BIAS_RADIUS_METERS,
            },
          },
        }),
        signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      },
    );
    if (!res.ok) {
      console.error(
        `places.searchText failed: ${res.status} ${
          scrubSecrets(await bodyText(res))
        }`,
      );
      return { places: [], failed: true };
    }
    data = await res.json();
  } catch (err) {
    // Network error, timeout, or unparseable body: the caller gets an empty
    // list, never an exception.
    console.error(`places.searchText threw: ${scrubSecrets(String(err))}`);
    return { places: [], failed: true };
  }

  const rows = Array.isArray(data?.places) ? data.places : [];
  const suggestions: PlaceSuggestion[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    const suggestion = toSuggestion(row);
    // Places can return the same establishment twice for a station query.
    if (!suggestion || seen.has(suggestion.place_id)) continue;
    seen.add(suggestion.place_id);
    suggestions.push(suggestion);
    if (suggestions.length >= MAX_RESULTS) break;
  }
  return { places: suggestions, failed: false };
}

// --- Handler -----------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }
  if (!SUPABASE_URL || !ANON_KEY) {
    return json({ error: "server misconfigured" }, 500);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const rawQuery = (body as { query?: unknown })?.query;
  if (typeof rawQuery !== "string") {
    return json({ error: "query (string) is required" }, 400);
  }
  const query = rawQuery.trim();
  if (query.length < MIN_QUERY_CHARS) {
    return json(
      { error: `query must be at least ${MIN_QUERY_CHARS} characters` },
      400,
    );
  }
  if (query.length > MAX_QUERY_CHARS) {
    return json(
      { error: `query must be at most ${MAX_QUERY_CHARS} characters` },
      400,
    );
  }

  // Same boundary as every other function: a signed-in caller only. Anonymous
  // sign-in is enough (that is what the app uses), but an unauthenticated
  // request must not be able to spend our Places quota — or to probe whether the
  // provider key is configured, which is why that check comes after this one.
  const authorization = req.headers.get("Authorization") ?? "";
  if (authorization === "") {
    return json({ error: "missing authorization" }, 401);
  }
  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: auth, error: authError } = await caller.auth.getUser();
  if (authError || !auth?.user) {
    return json({ error: "not authenticated" }, 401);
  }

  if (!GOOGLE_PLACES_API_KEY) {
    return json({ error: "server misconfigured" }, 500);
  }

  const { places, failed } = await searchPlaces(query);
  if (failed) {
    // Still shaped like a success so a caller that only reads `places` shows an
    // empty list; the status and `error` let a careful one say "try again".
    return json({ places, error: "place provider unavailable" }, 502);
  }
  return json({ places });
});
