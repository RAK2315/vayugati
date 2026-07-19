# Vayu Gati — Design System

Implements the "professional application shell" required for Phase 1: a
Microsoft 365 / Outlook-inspired operations interface. Tokens live in one
place; components consume them — no raw hex values scattered in JSX.

## Token source of truth

Two files, kept in sync by convention (documented at the top of each):

- [`web/tailwind.config.js`](../web/tailwind.config.js) — turns the palette
  into Tailwind utility classes (`bg-ink-700`, `text-sky-600`,
  `bg-status-critical`, `z-header`, …). This is what components use.
- [`web/src/design/tokens.ts`](../web/src/design/tokens.ts) — the same values
  as typed JS constants, for the few places Tailwind classes can't reach
  (inline SVG fills in `AqiBadge.tsx`/`MapView.tsx`/`ForecastChart.tsx`,
  which intentionally keep their own India-NAQI colour scale — see below).

### Brand palette

| Token | Hex | Use |
|---|---|---|
| `ink.700` (a.k.a. `brand.darkBrown`) | `#422B1C` | Primary chrome: icon rail, primary buttons, primary text on light |
| `sky.200` (a.k.a. `brand.skyBlue`) | `#C4F1FF` | Accents on dark surfaces, focus rings, links |
| `cream` (a.k.a. `brand.warmCream`) | `#F6EFE4` | App background, `ink.50` |
| white | `#FFFFFF` | Work surfaces (cards, tables, forms) |

`brand-*` Tailwind classes (used throughout the pre-existing `CitizenView`/
`FieldView`/`Login` code) were **re-pointed** at the `ink` ramp rather than
deleted, so the whole app picks up the new identity without a page-by-page
rewrite — this is why `bg-brand-600` in older JSX now renders dark brown
instead of the old indigo, with zero component changes required.

### Status colours

`status.critical` / `status.warning` / `status.success` / `status.info` /
`status.neutral` — reserved **only** for severity/operational state (SLA
breach, pending approval, resolved, informational, unknown), never for
decoration. This directly satisfies the plan's "red, amber and green only for
severity/status" rule.

### A second, deliberately separate colour scale: India NAQI

`AqiBadge.tsx`, `MapView.tsx`, and `ForecastChart.tsx` share a 6-band colour
scale (green → lime → yellow → orange → red → purple) that mirrors India's
official National Air Quality Index communication bands. This is **not**
merged into the `status` tokens above, on purpose: it's a regulated,
domain-specific public-communication scale (CPCB's own bands, including
purple for "Severe", which has no place in a generic status vocabulary), not
a general severity/status choice made by this app. Both scales independently
satisfy "red/amber/green [semantic colours] reserved for severity" — they're
just two different domains that both need it.

### Typography

`Segoe UI Variable` → `Segoe UI` → `Inter` → `Noto Sans Devanagari` →
`system-ui` → platform fallbacks, exactly matching the plan's stack. Segoe UI
Variable/Segoe UI are only present on Windows and are *free* there (no
download); Inter + Noto Sans Devanagari continue to be loaded from Google
Fonts as the cross-platform/Hindi-script fallback, unchanged from before this
pass.

### Shadows, radii, z-index

- Shadows: two levels only (`card`, `card-lg`) plus a 1px `rail` separator —
  "subtle shadows," not drop-shadow-heavy.
- Radii: unchanged from the existing Tailwind defaults already in use
  (`rounded-lg`/`rounded-xl`/`rounded-2xl`) — these were already reasonably
  restrained; introducing a second, competing radius scale in this pass would
  have meant re-touching every existing card/button for no visible benefit,
  so it was deliberately left alone. Documented here, not reinvented.
- z-index: a named scale (`z-rail: 30`, `z-header: 40`, `z-dropdown: 50`,
  `z-modal: 60`, `z-toast: 70`) so future modal/toast work has a slot reserved
  instead of picking arbitrary numbers.

## Shared shell

`web/src/components/AppShell.tsx` — used by every authenticated route.

- **Top bar**: product name, a (currently disabled, clearly labelled
  "coming soon") global search field, an alerts icon, a help icon with a
  small info popover, and a user menu (role + ward + sign out).
- **Left icon rail**: the full target navigation set — Overview, Incidents,
  Map, Tasks, Citizens, Sensors, Analytics, Settings — with only the items
  that have a real destination today enabled (see
  [ROLE_WORKFLOWS.md](ROLE_WORKFLOWS.md) for the exact map). Disabled items
  carry a `title` tooltip naming which phase builds them, and an
  `aria-disabled` attribute.
- **Responsive main workspace**: the rail is icon-only at all widths (already
  narrow enough for mobile); the search field collapses below `sm`; every
  existing page's own responsive layout (`CitizenView`/`FieldView` mobile-
  first cards, `CommandView` desktop tables) is untouched.
- **`dark` prop**: `/command` opts into a dark workspace background
  (`bg-ink-900`) for its "command room" feel; the rail and top bar keep the
  brand chrome regardless of this flag, so the shell identity never changes
  per-page — only the workspace canvas does.

## States (loading / empty / error / stale / partial / offline)

`web/src/components/ui.tsx`:

| Component | Meaning |
|---|---|
| `Skeleton` (pre-existing) | Loading |
| `EmptyState` (pre-existing) | Nothing to show — not an error |
| `ErrorState` (new) | A fetch/mutation failed; optional retry callback |
| `StaleBadge` (new) | Data loaded but past its freshness window |
| `PartialDataBadge` (new) | Some but not all expected data arrived |
| `UnavailableBadge` (new) | A feed/connector is not configured (see `city_connectors`) |
| `OfflineBanner` (new, shell-level) | Browser `online`/`offline` events; shown app-wide via `AppShell` |

`StaleBadge`/`PartialDataBadge`/`UnavailableBadge` are primitives only in this
pass — wiring them into every data card (e.g. showing `UnavailableBadge` next
to R.K. Puram's ward tile, whose OpenAQ station id is still `null` in
`stations.yaml`) is Phase 4 work (`docs/DATA_QUALITY_AND_SCIENCE.md`), once
per-reading quality metadata exists to drive them from real state rather than
a hardcoded example.

## Logo / brand assets

**No official Vayu Gati logo artwork exists in this repository.** Per the
migration's explicit instruction not to redraw a logo inaccurately, this pass
ships clearly-labelled placeholders built only from the token palette:

- `web/src/components/AppShell.tsx` → `LogoMark` (compact icon, rail/favicon)
  and `LogoWordmark` (typographic "Vayu Gati" wordmark, login/brand surfaces).
- `web/public/brand/favicon.svg` — same placeholder mark as the browser tab
  icon.
- `web/public/brand/README.md` — documents the **exact filenames** required
  to replace the placeholder (`logo-wordmark-primary.svg`,
  `logo-wordmark-alt.svg`, `logo-icon-compact.svg`, `favicon.svg`/PNGs) and
  states plainly that `LogoMark`/`LogoWordmark` are the only two places that
  need to change once real artwork arrives.

## Accessibility

- Colour is never the only signal: every status badge pairs a colour with a
  text label (`ErrorState`, `StaleBadge`, priority bands in `FieldView`, AQI
  labels in `AqiBadge`).
- `.focus-ring` utility (`web/src/index.css`) gives every new interactive
  element (nav buttons, menu triggers, form inputs) a visible
  `focus-visible` ring — keyboard navigation was tested by tabbing through
  the rail → top bar → page content order.
- Hindi text (login subtitle, citizen advisories) already renders with the
  Noto Sans Devanagari fallback; unchanged, still working.
- Not yet done: a full WCAG AA contrast audit of every new colour pairing
  against every background (spot-checked, not automated) — flagged as a
  follow-up in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).
