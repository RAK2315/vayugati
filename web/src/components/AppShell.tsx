import type { ReactNode } from 'react'
import { useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../lib/auth'
import { BUILD_INFO, IS_PRODUCTION } from '../lib/env'
import { OfflineBanner } from './ui'

// ── Brand marks ──────────────────────────────────────────────────────────────
// PLACEHOLDER marks built from the brand tokens (dark brown / sky blue / cream).
// These are NOT the official Vayu Gati logo — no real artwork has been supplied
// to this repository. See web/public/brand/README.md for the exact filenames
// to drop in once real artwork exists; this component is the only place that
// needs to change when that happens.
export function LogoMark({ className = 'h-7 w-7' }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" className={className} aria-hidden fill="none">
      <rect width="32" height="32" rx="8" fill="#422B1C" />
      <path
        d="M6 13h13a2.6 2.6 0 1 0-2.6-2.6M6 16.4h16.5a2.8 2.8 0 1 1-2.8 2.8M6 19.8h8"
        stroke="#C4F1FF"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  )
}

/** Full wordmark — for login / brand surfaces only. Typographic placeholder. */
export function LogoWordmark({ dark = false }: { dark?: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      <LogoMark className="h-9 w-9" />
      <span className={`text-xl font-bold tracking-tight ${dark ? 'text-sky-200' : 'text-ink-800'}`}>Vayu Gati</span>
    </div>
  )
}

const ROLE_LABEL: Record<string, string> = {
  citizen: 'Citizen',
  field_officer: 'Field Officer',
  commander: 'Commander',
  admin: 'Admin',
}

interface RailItem {
  key: string
  label: string
  icon: string
  /** Path to navigate to. Undefined = not built yet in this phase. */
  to?: string
  comingSoon?: string
}

function railItemsForRole(role: string | undefined, homePath: string): RailItem[] {
  const isCommand = role === 'commander' || role === 'admin'
  const isField = role === 'field_officer' || role === 'admin'
  return [
    { key: 'overview', label: 'Overview', icon: '⌂', to: homePath },
    {
      key: 'incidents',
      label: 'Incidents',
      icon: '⚠',
      // Built in Phase 3, for the command roles. Field officers work incidents
      // through their missions rather than the queue.
      to: isCommand ? '/incidents' : undefined,
      comingSoon: isCommand ? undefined : 'The incident queue is a command-centre surface',
    },
    { key: 'map', label: 'Map', icon: '⚲', comingSoon: 'Standalone map view — embedded in Overview for now' },
    {
      key: 'tasks',
      label: 'Tasks',
      icon: '☑',
      to: isField ? '/missions' : undefined,
      comingSoon: isField ? undefined : 'Task queue arrives in Phase 3',
    },
    { key: 'citizens', label: 'Citizens', icon: '☺', comingSoon: 'Citizen operations view arrives in Phase 3/5' },
    { key: 'sensors', label: 'Sensors', icon: '◈', comingSoon: 'Sensor/data-quality view arrives in Phase 4' },
    { key: 'analytics', label: 'Analytics', icon: '▤', comingSoon: 'Outcome analytics arrive in Phase 6' },
    {
      key: 'settings',
      label: 'Settings',
      icon: '⚙',
      // Phase 10: system health + the minimal pilot admin surface.
      to: isCommand ? '/ops' : undefined,
      comingSoon: isCommand ? undefined : 'City Pack settings are a command-centre surface',
    },
  ]
}

function IconRail({ role, homePath }: { role: string | undefined; homePath: string }) {
  const navigate = useNavigate()
  const location = useLocation()
  const items = railItemsForRole(role, homePath)

  return (
    <nav
      aria-label="Primary"
      className="z-rail flex w-14 flex-shrink-0 flex-col items-center gap-1 bg-ink-800 py-3 sm:w-16"
    >
      <div className="mb-2">
        <LogoMark className="h-8 w-8" />
      </div>
      {items.map((item) => {
        const active = !!item.to && location.pathname === item.to
        const disabled = !item.to
        return (
          <button
            key={item.key}
            type="button"
            disabled={disabled}
            title={disabled ? item.comingSoon : item.label}
            aria-current={active ? 'page' : undefined}
            aria-disabled={disabled}
            onClick={() => item.to && navigate(item.to)}
            className={`focus-ring group relative flex w-11 flex-col items-center gap-0.5 rounded-lg py-1.5 text-[10px] font-medium transition sm:w-12 ${
              active
                ? 'bg-sky-200/20 text-sky-200'
                : disabled
                  ? 'cursor-not-allowed text-ink-400'
                  : 'text-ink-100 hover:bg-white/10 hover:text-sky-200'
            }`}
          >
            <span className="text-base leading-none" aria-hidden>
              {item.icon}
            </span>
            <span className="leading-none">{item.label}</span>
            {disabled && <span className="absolute -right-0.5 -top-0.5 h-1.5 w-1.5 rounded-full bg-ink-500" aria-hidden />}
          </button>
        )
      })}
    </nav>
  )
}

function TopBar({ subtitle, dark }: { subtitle?: string; dark: boolean }) {
  const { profile, signOut } = useAuth()
  const [menuOpen, setMenuOpen] = useState(false)
  const [helpOpen, setHelpOpen] = useState(false)

  return (
    <header
      className={`z-header flex items-center gap-3 border-b px-3 py-2 sm:px-4 ${
        dark ? 'border-white/10 bg-ink-900' : 'border-ink-900/10 bg-white'
      }`}
    >
      <div className="flex min-w-0 items-baseline gap-2">
        <span className={`truncate text-[15px] font-bold tracking-tight ${dark ? 'text-sky-100' : 'text-ink-800'}`}>
          Vayu Gati
        </span>
        {subtitle && (
          <span className={`hidden truncate text-xs font-medium sm:inline ${dark ? 'text-ink-300' : 'text-ink-400'}`}>
            {subtitle}
          </span>
        )}
      </div>

      {/* global search — visual placeholder, not wired yet */}
      <div className="mx-auto hidden max-w-md flex-1 sm:block">
        <input
          type="search"
          disabled
          placeholder="Search incidents, reports, wards… (coming soon)"
          title="Global search arrives with the incident queue in Phase 3"
          className={`focus-ring w-full cursor-not-allowed rounded-lg border px-3 py-1.5 text-sm ${
            dark
              ? 'border-white/10 bg-white/5 text-ink-300 placeholder:text-ink-400'
              : 'border-ink-900/10 bg-ink-50 text-ink-400 placeholder:text-ink-400'
          }`}
        />
      </div>

      <div className="ml-auto flex items-center gap-1.5 sm:ml-0">
        <button
          type="button"
          title="Alerts — none yet"
          className={`focus-ring relative rounded-lg p-2 text-sm transition ${
            dark ? 'text-ink-200 hover:bg-white/10' : 'text-ink-500 hover:bg-ink-50'
          }`}
        >
          <span aria-hidden>🔔</span>
          <span className="sr-only">Alerts</span>
        </button>

        <div className="relative">
          <button
            type="button"
            onClick={() => setHelpOpen((v) => !v)}
            title="Help"
            className={`focus-ring rounded-lg p-2 text-sm transition ${
              dark ? 'text-ink-200 hover:bg-white/10' : 'text-ink-500 hover:bg-ink-50'
            }`}
          >
            <span aria-hidden>❓</span>
            <span className="sr-only">Help</span>
          </button>
          {helpOpen && (
            <div className="z-dropdown absolute right-0 top-full mt-1 w-56 rounded-xl border border-ink-900/10 bg-white p-3 text-xs text-ink-600 shadow-card-lg">
              <p className="font-semibold text-ink-800">Vayu Gati</p>
              <p className="mt-1">
                Pan-India air incident-response platform. Delhi is the first City Pack — see{' '}
                <code>docs/IMPLEMENTATION_STATUS.md</code> for what&apos;s live today.
              </p>
              <p className="mt-2 border-t border-ink-900/5 pt-2 text-[10px] text-ink-400">
                Build {BUILD_INFO.sha} · {BUILD_INFO.environment}
              </p>
            </div>
          )}
        </div>

        <div className="relative">
          <button
            type="button"
            onClick={() => setMenuOpen((v) => !v)}
            className={`focus-ring flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm transition ${
              dark ? 'text-ink-100 hover:bg-white/10' : 'text-ink-700 hover:bg-ink-50'
            }`}
          >
            <span
              className={`flex h-6 w-6 items-center justify-center rounded-full text-[11px] font-bold ${
                dark ? 'bg-sky-200/20 text-sky-200' : 'bg-ink-100 text-ink-700'
              }`}
              aria-hidden
            >
              {(profile ? ROLE_LABEL[profile.role] : '?').charAt(0)}
            </span>
            <span className="hidden text-xs font-medium sm:inline">
              {profile ? ROLE_LABEL[profile.role] ?? profile.role : ''}
            </span>
          </button>
          {menuOpen && (
            <div className="z-dropdown absolute right-0 top-full mt-1 w-48 rounded-xl border border-ink-900/10 bg-white p-1.5 text-sm shadow-card-lg">
              {profile && (
                <div className="border-b border-ink-900/5 px-2.5 py-2">
                  <p className="font-semibold text-ink-800">{ROLE_LABEL[profile.role] ?? profile.role}</p>
                  {profile.wardName && <p className="text-xs text-ink-400">{profile.wardName}</p>}
                </div>
              )}
              <button
                onClick={signOut}
                className="mt-1 w-full rounded-lg px-2.5 py-1.5 text-left text-ink-700 transition hover:bg-ink-50"
              >
                Sign out
              </button>
            </div>
          )}
        </div>
      </div>
    </header>
  )
}

/**
 * Shared, role-aware application shell: top bar + left icon rail + responsive
 * main workspace. `dark` switches the workspace background to the command-room
 * palette (used by /command today); the rail and top bar keep the brand chrome
 * regardless, per docs/DESIGN_SYSTEM.md.
 */
export default function AppShell({
  subtitle,
  dark = false,
  secondaryNav,
  children,
}: {
  subtitle?: string
  dark?: boolean
  /** Contextual secondary navigation for the active module (plan §19). Optional:
   *  pages that don't pass it keep the previous single-pane layout unchanged. */
  secondaryNav?: ReactNode
  children: ReactNode
}) {
  const { profile } = useAuth()
  const homePath = profile
    ? profile.role === 'field_officer'
      ? '/field'
      : profile.role === 'commander' || profile.role === 'admin'
        ? '/command'
        : '/citizen'
    : '/'

  return (
    <div className="flex h-[100dvh]">
      <IconRail role={profile?.role} homePath={homePath} />
      <div className={`flex min-w-0 flex-1 flex-col ${dark ? 'bg-ink-900 text-slate-100' : 'bg-cream text-ink-900'}`}>
        <TopBar subtitle={subtitle} dark={dark} />
        {!IS_PRODUCTION && (
          <div className="bg-amber-400 px-3 py-0.5 text-center text-[11px] font-bold uppercase tracking-wide text-amber-950">
            {BUILD_INFO.environment} — not production
          </div>
        )}
        <OfflineBanner />
        {secondaryNav ? (
          // Contextual nav: a column on desktop, a scrollable strip on narrow
          // screens. It must never simply disappear — it is the only way to
          // change queue.
          <div className="flex min-h-0 flex-1 flex-col sm:flex-row">
            <nav
              aria-label="Secondary"
              className={`flex-shrink-0 overflow-x-auto border-b p-2 sm:w-44 sm:overflow-x-visible sm:overflow-y-auto sm:border-b-0 sm:border-r ${
                dark ? 'border-white/10 bg-ink-900/60' : 'border-ink-900/10 bg-white/60'
              }`}
            >
              {secondaryNav}
            </nav>
            <main className="flex min-w-0 flex-1 flex-col">{children}</main>
          </div>
        ) : (
          <main className="flex min-h-0 flex-1 flex-col">{children}</main>
        )}
      </div>
    </div>
  )
}
