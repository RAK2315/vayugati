/**
 * Vayu Gati design tokens — single source of truth for colour, type, spacing,
 * radii, shadows, z-index and status states.
 *
 * These values MUST stay in sync with `web/tailwind.config.js`, which turns
 * the same palette into Tailwind utility classes (`bg-ink-700`, `text-sky-600`,
 * `bg-status-critical`, etc.). Use this module directly only where Tailwind
 * classes can't reach — inline SVG fills, canvas/map layers, and chart code.
 *
 * Do not add new raw hex values in components. Extend this file (and the
 * matching entry in tailwind.config.js) instead.
 *
 * See docs/DESIGN_SYSTEM.md for the full rationale.
 */

/** Primary brand ramp — anchored on the dark-brown mark, #422B1C (ink.700). */
export const ink = {
  50: '#F6EFE4', // warm cream — page/app background
  100: '#EDE0CB',
  200: '#DEC7A0',
  300: '#C9A876',
  400: '#A9814F',
  500: '#8A6238',
  600: '#6B4A2A',
  700: '#422B1C', // brand dark brown — primary chrome, primary text on light
  800: '#341F14',
  900: '#241109',
} as const

/** Secondary brand ramp — anchored on the sky-blue mark, #C4F1FF (sky.200). */
export const sky = {
  50: '#F2FCFF',
  100: '#E5F9FF',
  200: '#C4F1FF', // brand sky blue — accents on dark surfaces, links, focus rings
  300: '#9FE6FB',
  400: '#6ED4F0',
  500: '#3EBEDE',
  600: '#2A9BB9',
  700: '#1F7A92',
  800: '#1B5F71',
  900: '#16454F',
} as const

/** Named brand constants exactly as specified in the product plan. */
export const brand = {
  darkBrown: '#422B1C',
  skyBlue: '#C4F1FF',
  warmCream: '#F6EFE4',
  white: '#FFFFFF',
} as const

/**
 * Accent ramp — Outlook/Fluent-style primary blue, introduced in the Phase 11
 * commander UI redesign. The ONLY colour used for active nav states, focus
 * rings, primary buttons and selected rows on the redesigned surfaces
 * (AppShell, Incidents, Overview, Ops). Main surfaces are white/slate; `ink`/
 * `sky`/`cream` above stay reserved for the logo mark and any not-yet-
 * redesigned surface (Field/Citizen), never re-applied as a page background.
 */
export const accent = {
  50: '#EFF6FC',
  100: '#DEECF9',
  200: '#C7E0F4',
  300: '#71AFE5',
  400: '#2B88D8',
  500: '#0F6CBD',
  600: '#0C5A9E',
  700: '#0A4A82',
  800: '#083861',
  900: '#062843',
} as const

/**
 * Status colours. Reserved ONLY for severity/operational status — never for
 * decorative branding. Distinct from the India NAQI pollutant-severity scale
 * (see AqiBadge.tsx), which is a regulated public-communication scale and is
 * intentionally kept separate (documented in docs/DESIGN_SYSTEM.md).
 */
export const status = {
  critical: '#DC2626', // red — breach / overdue / officially verified violation
  warning: '#D97706', // amber — at risk / suspected / pending approval
  success: '#16A34A', // green — on track / effective / resolved
  info: '#0284C7', // sky-leaning blue — informational, corroborated
  neutral: '#64748B', // slate — unknown / not applicable
} as const

export const typography = {
  fontFamily: [
    '"Segoe UI Variable"',
    '"Segoe UI"',
    'Inter',
    '"Noto Sans Devanagari"',
    'system-ui',
    '-apple-system',
    'Roboto',
    'sans-serif',
  ].join(', '),
} as const

/** Spacing scale (px), for contexts that can't use Tailwind's default scale directly. */
export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  '2xl': 32,
} as const

/** Restrained radii — compact, government-operations feel, not consumer-rounded. */
export const radii = {
  sm: 6,
  md: 10,
  lg: 14,
  full: 9999,
} as const

/** Subtle shadows only — thin borders do most of the separation work. */
export const shadows = {
  card: '0 1px 2px rgba(16,24,40,.04), 0 1px 3px rgba(16,24,40,.08)',
  cardLg: '0 4px 6px -1px rgba(16,24,40,.06), 0 10px 24px -4px rgba(16,24,40,.10)',
  rail: '1px 0 0 rgba(16,24,40,.08)',
} as const

/** z-index scale for the shared shell (keep every layer here, not ad hoc). */
export const zIndex = {
  rail: 30,
  header: 40,
  dropdown: 50,
  modal: 60,
  toast: 70,
} as const
