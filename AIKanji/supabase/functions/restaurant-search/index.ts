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
//   * raw provider payloads land in restaurant_source_records and provider
//     failures land in provider_incidents instead of vanishing into a `return
//     []`.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const GOOGLE_PLACES_API_KEY = Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "";
const GOOGLE_ROUTES_API_KEY = Deno.env.get("GOOGLE_ROUTES_API_KEY") ??
  GOOGLE_PLACES_API_KEY;
const HOTPEPPER_API_KEY = Deno.env.get("HOTPEPPER_API_KEY") ?? "";

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
  location: LatLng | null;
}

type Provider = "google_places" | "google_routes" | "hotpepper";

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
          "X-Goog-FieldMask":
            "places.id,places.displayName,places.priceLevel,places.primaryType,places.location,places.rating,places.userRatingCount",
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
        price_yen_estimate: priceLevelToYen(p.priceLevel as string | undefined),
        room_type: null,
        cuisine_tags: typeof p.primaryType === "string" ? [p.primaryType] : [],
        dietary_tags: [],
        allergy_safe_tags: [],
        atmosphere_tags: [],
        rating: placesRating(p.rating),
        user_rating_count: placesRatingCount(p.userRatingCount),
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

function priceLevelToYen(level: string | undefined): number | null {
  switch (level) {
    case "PRICE_LEVEL_INEXPENSIVE":
      return 2000;
    case "PRICE_LEVEL_MODERATE":
      return 4000;
    case "PRICE_LEVEL_EXPENSIVE":
      return 8000;
    case "PRICE_LEVEL_VERY_EXPENSIVE":
      return 15000;
    default:
      return null;
  }
}

// --- Hot Pepper -------------------------------------------------------------

interface HotPepperShop {
  id: string;
  name: string;
  budget?: { average?: string };
  private_room?: string; // "あり" | "なし"
  genre?: { name?: string };
  lat?: string;
  lng?: string;
}

async function hotPepperSearch(
  area: LatLng,
  incidents: ProviderIncident[],
): Promise<HotPepperShop[]> {
  if (!HOTPEPPER_API_KEY) return [];
  const url = new URL(
    "https://webservice.recruit.co.jp/hotpepper/gourmet/v1/",
  );
  url.searchParams.set("key", HOTPEPPER_API_KEY);
  url.searchParams.set("lat", String(area.lat));
  url.searchParams.set("lng", String(area.lng));
  url.searchParams.set("range", "3"); // 1000m
  url.searchParams.set("count", "10");
  url.searchParams.set("format", "json");
  try {
    const res = await fetch(url);
    if (!res.ok) {
      recordIncident(
        incidents,
        "hotpepper",
        "gourmet.search",
        res.status,
        await bodyText(res),
      );
      return [];
    }
    const data = await res.json();
    return data?.results?.shop ?? [];
  } catch (err) {
    recordIncident(incidents, "hotpepper", "gourmet.search", null, String(err));
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

// --- Google Routes ----------------------------------------------------------

interface TravelMatrixResult {
  // placeId -> participantId -> minutes
  minutes: Map<string, Record<string, number>>;
  // placeId -> the raw elements that produced it. The element's originIndex is
  // only meaningful against the request that returned it, so the participant it
  // resolved to travels with it.
  raw: Map<string, { participant_id: string; element: unknown }[]>;
}

async function travelMatrix(
  origins: Origin[],
  destinations: { placeId: string; location: LatLng }[],
  incidents: ProviderIncident[],
): Promise<TravelMatrixResult> {
  const result: TravelMatrixResult = { minutes: new Map(), raw: new Map() };
  if (origins.length === 0 || destinations.length === 0) return result;

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
      let rows: {
        originIndex?: number;
        destinationIndex?: number;
        duration?: string;
        condition?: string;
      }[];
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
              origins: originChunk.map((o) => ({
                waypoint: {
                  location: {
                    latLng: {
                      latitude: o.location.lat,
                      longitude: o.location.lng,
                    },
                  },
                },
              })),
              destinations: chunk.map((d) => ({
                waypoint: {
                  location: {
                    latLng: {
                      latitude: d.location.lat,
                      longitude: d.location.lng,
                    },
                  },
                },
              })),
              travelMode: "TRANSIT",
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
          continue;
        }
        rows = await res.json();
      } catch (err) {
        recordIncident(
          incidents,
          "google_routes",
          "routes.computeRouteMatrix",
          null,
          String(err),
        );
        continue;
      }
      for (const row of Array.isArray(rows) ? rows : []) {
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
        entry[origin.participantId] = Math.round(seconds / 60);
        result.minutes.set(dest.placeId, entry);
        const rawRows = result.raw.get(dest.placeId) ?? [];
        rawRows.push({ participant_id: origin.participantId, element: row });
        result.raw.set(dest.placeId, rawRows);
      }
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
function zonesShifted(
  areas: LatLng[],
  stored: { lat: number; lng: number }[],
): boolean {
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

  if (!GOOGLE_PLACES_API_KEY) {
    return json({ error: "GOOGLE_PLACES_API_KEY not configured" }, 500);
  }

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
  // `travel_reference` is a UI CATEGORY ('office'|'home'|'station'|
  // 'doesnt_matter'), not an address. Geocoding the word — the old
  // `geocodeText("office Tokyo")` path — invented a location somewhere in Tokyo
  // for every participant and made the whole travel-fairness story fiction, so
  // an unresolvable participant is now reported instead of guessed.
  const origins: Origin[] = [];
  const unresolved: { participant_id: string; reason: string }[] = [];
  const unconstrained: string[] = [];
  const locationByPlaceId = new Map<string, LatLng | null>();
  for (const p of participants as ParticipantRow[]) {
    if (p.travel_reference === "doesnt_matter") {
      // No travel constraint by definition: they are not an origin, and their
      // absence must not stop the event.
      unconstrained.push(p.id);
      continue;
    }
    const referencePlaceId = p.travel_reference_place_id;
    if (!referencePlaceId) {
      unresolved.push({
        participant_id: p.id,
        reason: "travel_reference_place_id_missing",
      });
      continue;
    }
    // Colleagues share an office: one Places lookup per distinct place id.
    if (!locationByPlaceId.has(referencePlaceId)) {
      locationByPlaceId.set(
        referencePlaceId,
        await placeLocation(referencePlaceId, incidents),
      );
    }
    const loc = locationByPlaceId.get(referencePlaceId) ?? null;
    if (!loc) {
      unresolved.push({
        participant_id: p.id,
        reason: "travel_reference_place_lookup_failed",
      });
      continue;
    }
    origins.push({ participantId: p.id, location: loc });
  }
  if (origins.length === 0) {
    // Unchanged contract: 422 only when NO origin at all can be resolved.
    await persistIncidents();
    return json({
      error: "could not resolve any travel reference",
      unresolved_participants: unresolved,
      travel_unconstrained_participants: unconstrained,
      provider_incidents: incidentSummary(incidents),
    }, 422);
  }

  // 2. Candidate meeting areas, and the zones we searched last time.
  const areas = meetingAreas(origins.map((o) => o.location));
  const { data: storedZones } = await supabase
    .from("meeting_zones")
    .select("lat, lng")
    .eq("event_id", eventId);
  const searchSpaceShifted = zonesShifted(areas, storedZones ?? []);

  // 3. Read-through cache: which of this event's candidates are still fresh?
  const discoveryCutoffMs = minutesAgoMs(DISCOVERY_TTL_MINUTES);
  const travelCutoffMs = minutesAgoMs(TRAVEL_TTL_MINUTES);
  const { data: cachedCandidateRows, error: ccErr } = await supabase
    .from("event_restaurant_candidates")
    .select("place_id, discovered_at")
    .eq("event_id", eventId);
  if (ccErr) return json({ error: ccErr.message }, 500);
  const cachedPlaceIds = (cachedCandidateRows ?? [])
    .filter((row) => freshAt(row.discovered_at, discoveryCutoffMs))
    .map((row) => row.place_id as string);

  const discoveryNeeded = cachedPlaceIds.length === 0 || searchSpaceShifted;
  const discoverySkipReason = discoveryNeeded
    ? null
    : "fresh_candidates_for_unchanged_meeting_zones";

  // 4+5. Places + Hot Pepper per area, dedupe by place_id — only when the cache
  // cannot answer.
  const byPlaceId = new Map<string, Candidate>();
  const sourceRecords: SourceRecord[] = [];
  if (discoveryNeeded) {
    for (const area of areas) {
      const [places, hpShops] = await Promise.all([
        searchRestaurants(area, cuisineTags, incidents),
        hotPepperSearch(area, incidents),
      ]);
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
      // Enrich nearest Places candidate with Hot Pepper JP-specific attributes.
      for (const shop of hpShops) {
        const shopLat = Number(shop.lat);
        const shopLng = Number(shop.lng);
        if (!Number.isFinite(shopLat) || !Number.isFinite(shopLng)) continue;
        let best: Candidate | null = null;
        let bestD = Infinity;
        for (const c of byPlaceId.values()) {
          if (!c.location) continue;
          const d = (c.location.lat - shopLat) ** 2 +
            (c.location.lng - shopLng) ** 2;
          if (d < bestD) {
            bestD = d;
            best = c;
          }
        }
        // ~100m match threshold; otherwise skip rather than guess.
        if (best && bestD < 1e-6 && !best.hotpepper_id) {
          best.hotpepper_id = shop.id;
          best.room_type = hotPepperRoomType(shop) ?? best.room_type;
          best.price_yen_estimate = hotPepperBudgetYen(shop) ??
            best.price_yen_estimate;
          if (shop.genre?.name) best.cuisine_tags.push(shop.genre.name);
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

  // 6. Normalized upsert. Additive by construction (see 0017): an empty
  // dietary/allergy/room/cuisine value never overwrites a populated one, and the
  // legacy travel JSONB is merged rather than replaced.
  if (fetchedCandidates.length > 0) {
    const { error: recordErr } = await supabase.rpc(
      "fn_record_provider_candidates",
      {
        p_event_id: eventId,
        p_candidates: fetchedCandidates.map((c) => ({
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
        })),
      },
    );
    if (recordErr) return json({ error: recordErr.message }, 500);
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

  const activePlaceIds = [
    ...new Set([...cachedPlaceIds, ...byPlaceId.keys()]),
  ];
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
    }));
  }

  // 7. Destination coordinates. New candidates carry theirs; cached ones are
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

  // 8. Travel matrix: only the (event, participant, place) legs we are missing.
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

  // 9. Persist travel times: authoritative per-event rows plus the legacy JSONB
  // that fn_travel_minutes falls back to.
  if (legs.length > 0) {
    const { error: legErr } = await supabase.rpc("fn_record_travel_minutes", {
      p_event_id: eventId,
      p_legs: legs,
    });
    if (legErr) return json({ error: legErr.message }, 500);
  }

  // 10. Raw payloads, kept separate from the normalized records. Routes matrices
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
