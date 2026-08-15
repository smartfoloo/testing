# まとメシ (matomeshi-web)

Web/PWA port of the **AIKanji** iOS app in `../AIKanji`, taken from
`design/japanese-matomeshi-ui` at commit `68e67bb`.

Same product, same Japanese copy, same design system, same backend contract — it talks to
the identical Supabase RPCs, Edge Functions and realtime topics as the SwiftUI client.

## Running it

```bash
cd web
npm install
npm run dev
```

With no configuration it boots on an **in-browser mock backend** seeded from
`AIKanji/supabase/seed.sql`, so the whole flow is usable offline. Invite code `demo01` joins the
five-person demo event.

To point it at a real project:

```bash
cp .env.example .env.local   # fill VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
```

The same setup `AIKanji/README.md` describes is required: apply the migrations, enable
anonymous sign-ins, disable public Realtime access, and deploy the `llm-assist` /
`restaurant-search` functions.

## Scripts

| Command | What it does |
| --- | --- |
| `npm run dev` | Vite dev server |
| `npm run build` | Typecheck, bundle, generate the service worker |
| `npm run preview` | Serve the production build (needed to exercise the PWA) |
| `npm run lint` | oxlint |
| `npm run typecheck` | `tsc -b --noEmit` |
| `npm run verify:engine` | Asserts the ported feasibility engine against the seed fixture |
| `npm run icons` | Regenerates the PWA icon set from the design tokens |

## Layout

```
src/styles/index.css     Design tokens: AppColors (light + dark), AppSpacing, AppRadius, AppTypography
src/design/              copy.ts (AppCopy), components.tsx, icons.tsx, cn.ts
src/models/              types.ts (wire shapes), format.ts (ConstraintFormatter), invite.ts
src/backend/types.ts     The interface the screens consume
src/backend/supabase.ts  Real backend — same RPCs/functions/topics as the Swift services
src/backend/mock.ts      In-browser fixture: seed.sql, deterministic parser, broadcasts
src/backend/engine.ts    TS port of AIKanji/supabase/migrations/0009_*.sql
src/features/            One file per screen, named after its SwiftUI counterpart
scripts/verify-engine.ts Engine assertions mirroring AIKanji/Tests/.../FeasibilityEngineTests.swift
```

### Where each screen came from

| Web | iOS |
| --- | --- |
| `features/Welcome.tsx` | `AIKanji/AIKanji/Features/Onboarding/WelcomeView.swift` |
| `features/CreateEvent.tsx` | `AIKanji/AIKanji/Features/Onboarding/CreateEventView.swift` |
| `features/JoinEvent.tsx` | `AIKanji/AIKanji/Features/Onboarding/JoinEventView.swift` |
| `features/EventHome.tsx` | `AIKanji/AIKanji/Features/Onboarding/EventHomeView.swift` |
| `features/ConstraintEntry.tsx` | `AIKanji/AIKanji/Features/Constraints/ConstraintEntryView.swift` |
| `features/GroupFeed.tsx` | `AIKanji/AIKanji/Features/Activity/GroupActivityFeedView.swift` |
| `features/OrganizerDashboard.tsx` | `AIKanji/AIKanji/Features/Organizer/OrganizerDashboardView.swift` |
| `features/Recommendations.tsx` | `AIKanji/AIKanji/Features/Recommendations/RecommendationListView.swift` |
| `features/RecommendationCard.tsx` | `AIKanji/AIKanji/Features/Recommendations/RecommendationCardView.swift` |
| `features/NegotiationConsent.tsx` | `AIKanji/AIKanji/Features/Negotiation/NegotiationConsentView.swift` |

`data-testid` attributes reproduce the SwiftUI `accessibilityIdentifier`s, so
`AIKanji/Tests/AIKanjiUITests/CriticalScreensUITests.swift` translates across almost verbatim.

## Platform substitutions

The design and behaviour are ported 1:1; these are the places where a native API had to
be swapped for a web equivalent.

| iOS | Web |
| --- | --- |
| `NavigationStack` | History-API stack; pushed screens stay mounted so parent state survives |
| SF Symbols | Inline SVGs in `design/icons.tsx` |
| Asset catalog colorsets | CSS custom properties, dark variant under `.dark` |
| `@Environment(\.colorScheme)` | `prefers-color-scheme` toggling `.dark` on `<html>` |
| `CIFilter.qrCodeGenerator` | `qrcode` |
| `DataScannerViewController` | `getUserMedia` + `jsqr` scan loop |
| `ShareLink` / `UIPasteboard` | `navigator.share` / `navigator.clipboard` |
| Dynamic Type | `text-size-adjust` plus rem-free token sizes |
| Keychain-backed session | `supabase-js` default storage (`localStorage`) |

Realtime is unchanged: private `event-{event_id}` broadcast topics for `constraint_added`
and `run_updated`, authorized by the policy on `realtime.messages`.

## PWA

Installable and offline-capable via `vite-plugin-pwa` (Workbox, `autoUpdate`). The app
shell is precached; Supabase REST/RPC/auth responses deliberately are **not**, because
they are per-session and authorization-dependent. Verify with `npm run build && npm run
preview` — service workers do not run in dev.

## Deliberate deviations

1. **Mock-mode footnote on the welcome screen.** The only UI not in the iOS app: without
   it there is no way to discover the demo invite code. Guarded by `backend.mode === 'mock'`.
2. ~~**`demo01` instead of `DEMO01`.**~~ **Fixed upstream in 0021.** The seed used to carry an
   uppercase invite code that `fn_generate_invite_code` could never emit (its alphabet is
   lowercase and excludes `0`/`1`) and that the join screen's lowercasing could never match,
   making the documented demo event unreachable. `seed.sql` now seeds `demo01`, so the mock
   and the real fixture agree.
3. **Restaurant names in the fixture.** `AIKanji/supabase/seed.sql` leaves `restaurant_features.name` null;
   the real pipeline fills it from the Places `displayName`. The mock seeds Japanese names
   so the recommendation cards are not all titled 「おすすめのお店」.
4. **Mock travel times.** Standing in for `restaurant-search`, the mock fills the travel
   matrix for participants with no cached entry using a stable hash, as the real function
   would. Feasibility is unaffected; fairness scores become meaningful rather than all `1.0`.
5. ~~**Numeric-cast robustness.**~~ **Fixed upstream in 0021.** A non-numeric `max_yen` used to
   abort the entire recompute in Postgres (`invalid input syntax for integer`), while the port
   treated it as absent — so one malformed constraint could break the real backend but never
   the mock. SQL now reads jsonb integers through `fn_jsonb_int`, which matches the port's
   `nullableInt`. The two engines agree again.
