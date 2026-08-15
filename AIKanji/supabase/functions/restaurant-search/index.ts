// POST /restaurant-search — gathers candidate restaurants for an event.
//
// All provider keys (Google Places, Google Routes, Hot Pepper) live only in
// Edge Function secrets; the iOS client only ever calls this function.
// Places FieldMasks are deliberately minimal: an unrequested field such as
// `rating` silently upgrades the call to a pricier billing tier.
// Places content other than place_id is short-lived by policy, so
// restaurant_features is a refreshable cache (fetched_at), not a warehouse.

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
  travel_reference: string;
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
  location: LatLng | null;
}

// --- Google Places ---------------------------------------------------------

async function placeLocation(placeId: string): Promise<LatLng | null> {
  const res = await fetch(
    `https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`,
    {
      headers: {
        "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
        "X-Goog-FieldMask": "location",
      },
    },
  );
  if (!res.ok) return null;
  const data = await res.json();
  const loc = data?.location;
  if (typeof loc?.latitude !== "number") return null;
  return { lat: loc.latitude, lng: loc.longitude };
}

async function geocodeText(text: string): Promise<LatLng | null> {
  const res = await fetch(
    "https://places.googleapis.com/v1/places:searchText",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
        "X-Goog-FieldMask": "places.id,places.location",
      },
      body: JSON.stringify({
        textQuery: `${text} Tokyo`,
        pageSize: 1,
        languageCode: "ja",
      }),
    },
  );
  if (!res.ok) return null;
  const data = await res.json();
  const loc = data?.places?.[0]?.location;
  if (typeof loc?.latitude !== "number") return null;
  return { lat: loc.latitude, lng: loc.longitude };
}

async function searchRestaurants(
  area: LatLng,
  cuisineTags: string[],
): Promise<Candidate[]> {
  const query = cuisineTags.length > 0
    ? `${cuisineTags.join(" ")} restaurant`
    : "restaurant izakaya";
  const res = await fetch(
    "https://places.googleapis.com/v1/places:searchText",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
        // Only what we use: anything extra (rating, photos…) raises the SKU.
        "X-Goog-FieldMask":
          "places.id,places.displayName,places.priceLevel,places.primaryType,places.location",
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
  if (!res.ok) return [];
  const data = await res.json();
  const places: Record<string, unknown>[] = data?.places ?? [];
  return places
    .filter((p) => typeof p.id === "string")
    .map((p) => ({
      place_id: p.id as string,
      name: typeof (p.displayName as { text?: unknown } | undefined)?.text === "string"
        ? (p.displayName as { text: string }).text
        : null,
      hotpepper_id: null,
      price_yen_estimate: priceLevelToYen(p.priceLevel as string | undefined),
      room_type: null,
      cuisine_tags: typeof p.primaryType === "string" ? [p.primaryType] : [],
      dietary_tags: [],
      allergy_safe_tags: [],
      atmosphere_tags: [],
      location: (p.location as { latitude?: number; longitude?: number })
          ?.latitude != null
        ? {
          lat: (p.location as { latitude: number }).latitude,
          lng: (p.location as { longitude: number }).longitude,
        }
        : null,
    }));
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

async function hotPepperSearch(area: LatLng): Promise<HotPepperShop[]> {
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
  const res = await fetch(url);
  if (!res.ok) return [];
  const data = await res.json();
  return data?.results?.shop ?? [];
}

function hotPepperRoomType(
  shop: HotPepperShop,
): "private" | "semi_private" | null {
  if (shop.private_room && shop.private_room.includes("あり")) {
    return "private";
  }
  return null;
}

function hotPepperBudgetYen(shop: HotPepperShop): number | null {
  const avg = shop.budget?.average ?? "";
  const m = avg.replace(/[,，]/g, "").match(/(\d{3,6})/);
  return m ? Number(m[1]) : null;
}

// --- Google Routes ----------------------------------------------------------

async function travelMatrix(
  origins: { participantId: string; location: LatLng }[],
  destinations: { placeId: string; location: LatLng }[],
): Promise<Map<string, Record<string, number>>> {
  const byPlace = new Map<string, Record<string, number>>();
  if (origins.length === 0 || destinations.length === 0) return byPlace;
  for (let offset = 0; offset < destinations.length; offset += 20) {
    const chunk = destinations.slice(offset, offset + 20);
    const res = await fetch(
      "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": GOOGLE_ROUTES_API_KEY,
          "X-Goog-FieldMask": "originIndex,destinationIndex,duration,condition",
        },
        body: JSON.stringify({
          origins: origins.map((o) => ({
            waypoint: {
              location: {
                latLng: { latitude: o.location.lat, longitude: o.location.lng },
              },
            },
          })),
          destinations: chunk.map((d) => ({
            waypoint: {
              location: {
                latLng: { latitude: d.location.lat, longitude: d.location.lng },
              },
            },
          })),
          travelMode: "TRANSIT",
        }),
      },
    );
    if (!res.ok) continue;
    const rows: {
      originIndex?: number;
      destinationIndex?: number;
      duration?: string;
    }[] = await res.json();
    for (const row of Array.isArray(rows) ? rows : []) {
      if (
        row.originIndex == null || row.destinationIndex == null ||
        typeof row.duration !== "string"
      ) continue;
      const seconds = Number(row.duration.replace(/s$/, ""));
      if (!Number.isFinite(seconds)) continue;
      const dest = chunk[row.destinationIndex];
      const origin = origins[row.originIndex];
      if (!dest || !origin) continue;
      const entry = byPlace.get(dest.placeId) ?? {};
      entry[origin.participantId] = Math.round(seconds / 60);
      byPlace.set(dest.placeId, entry);
    }
  }
  return byPlace;
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
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
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

  // 1. Resolve each participant's travel reference to a location.
  const origins: { participantId: string; location: LatLng }[] = [];
  for (const p of participants as ParticipantRow[]) {
    const loc = p.travel_reference_place_id
      ? await placeLocation(p.travel_reference_place_id)
      : await geocodeText(p.travel_reference);
    if (loc) origins.push({ participantId: p.id, location: loc });
  }
  if (origins.length === 0) {
    return json({ error: "could not resolve any travel reference" }, 422);
  }

  // 2. Candidate meeting areas.
  const areas = meetingAreas(origins.map((o) => o.location));

  // 3+4. Places + Hot Pepper per area, dedupe by place_id.
  const byPlaceId = new Map<string, Candidate>();
  for (const area of areas) {
    const [places, hpShops] = await Promise.all([
      searchRestaurants(area, cuisineTags),
      hotPepperSearch(area),
    ]);
    for (const c of places) {
      if (!byPlaceId.has(c.place_id)) byPlaceId.set(c.place_id, c);
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
        // ("unverified", never "confirmed safe").
      }
    }
  }

  const candidates = [...byPlaceId.values()];
  if (candidates.length === 0) return json({ candidate_count: 0 });

  // 5. Travel-time matrix participant -> candidate.
  const withLocation = candidates.filter((c) => c.location != null);
  const matrix = await travelMatrix(
    origins,
    withLocation.map((c) => ({ placeId: c.place_id, location: c.location! })),
  );

  // 6. Upsert.
  const { error: rErr } = await supabase.from("restaurants").upsert(
    candidates.map((c) => ({
      place_id: c.place_id,
      name: c.name,
      hotpepper_id: c.hotpepper_id,
      last_fetched_at: new Date().toISOString(),
    })),
  );
  if (rErr) return json({ error: rErr.message }, 500);

  const { error: fErr } = await supabase.from("restaurant_features").upsert(
    candidates.map((c) => ({
      place_id: c.place_id,
      name: c.name,
      price_yen_estimate: c.price_yen_estimate,
      room_type: c.room_type,
      cuisine_tags: c.cuisine_tags,
      dietary_tags: c.dietary_tags,
      allergy_safe_tags: c.allergy_safe_tags,
      atmosphere_tags: c.atmosphere_tags,
      travel_minutes_by_participant: matrix.get(c.place_id) ?? {},
      fetched_at: new Date().toISOString(),
    })),
  );
  if (fErr) return json({ error: fErr.message }, 500);

  return json({ candidate_count: candidates.length });
});
