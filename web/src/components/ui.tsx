import type { ReactNode } from 'react'
import { useEffect, useState } from 'react'

// ── Card ─────────────────────────────────────────────────────────────────────
export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <div className={`card ${className}`}>{children}</div>
}

export function CardHeader({
  title,
  subtitle,
  right,
}: {
  title: ReactNode
  subtitle?: ReactNode
  right?: ReactNode
}) {
  return (
    <div className="flex items-start justify-between gap-3 border-b border-slate-100 px-4 py-3">
      <div>
        <h2 className="text-sm font-semibold text-slate-800">{title}</h2>
        {subtitle && <p className="mt-0.5 text-xs text-slate-400">{subtitle}</p>}
      </div>
      {right}
    </div>
  )
}

// ── Skeleton ─────────────────────────────────────────────────────────────────
export function Skeleton({ className = '' }: { className?: string }) {
  return <div className={`skeleton ${className}`} />
}

// ── Stat tile ────────────────────────────────────────────────────────────────
export function Stat({
  value,
  label,
  accent = 'text-slate-900',
}: {
  value: ReactNode
  label: string
  accent?: string
}) {
  return (
    <div className="rounded-xl bg-slate-50 px-3 py-2.5 text-center">
      <p className={`text-2xl font-bold tabular-nums ${accent}`}>{value}</p>
      <p className="mt-0.5 text-xs text-slate-500">{label}</p>
    </div>
  )
}

// ── Empty state ──────────────────────────────────────────────────────────────
export function EmptyState({ icon, children }: { icon?: string; children: ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center px-4 py-8 text-center">
      {icon && <div className="mb-2 text-2xl opacity-60">{icon}</div>}
      <p className="text-sm text-slate-400">{children}</p>
    </div>
  )
}

// ── Section label ────────────────────────────────────────────────────────────
export function Label({ children, dark = false }: { children: ReactNode; dark?: boolean }) {
  return (
    <p className={`text-xs font-semibold uppercase tracking-wide ${dark ? 'text-slate-500' : 'text-slate-400'}`}>
      {children}
    </p>
  )
}

// ── Error state ──────────────────────────────────────────────────────────────
// For a failed fetch/mutation. Distinct from EmptyState (which means "nothing
// to show", not "something went wrong").
export function ErrorState({
  message = 'Something went wrong loading this data.',
  onRetry,
}: {
  message?: string
  onRetry?: () => void
}) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-4 py-8 text-center">
      <div className="mb-1 text-2xl" aria-hidden>
        ⚠️
      </div>
      <p className="text-sm text-status-critical">{message}</p>
      {onRetry && (
        <button
          onClick={onRetry}
          className="focus-ring mt-1 rounded-lg border border-ink-200 px-3 py-1.5 text-xs font-semibold text-ink-700 transition hover:bg-ink-50"
        >
          Retry
        </button>
      )}
    </div>
  )
}

// ── Data-quality badges ──────────────────────────────────────────────────────
// Small, explicit labels — never silently show fresh-looking data that is
// actually stale, partial, or unavailable. See docs/DATA_QUALITY_AND_SCIENCE.md.
export function StaleBadge({ label = 'Stale' }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wide text-status-warning ring-1 ring-inset ring-status-warning/40">
      <span className="h-1.5 w-1.5 rounded-full bg-status-warning" aria-hidden />
      {label}
    </span>
  )
}

export function PartialDataBadge({ label = 'Partial data' }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wide text-status-info ring-1 ring-inset ring-status-info/40">
      <span className="h-1.5 w-1.5 rounded-full bg-status-info" aria-hidden />
      {label}
    </span>
  )
}

export function UnavailableBadge({ label = 'Unavailable' }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wide text-slate-500 ring-1 ring-inset ring-slate-300">
      <span className="h-1.5 w-1.5 rounded-full bg-slate-400" aria-hidden />
      {label}
    </span>
  )
}

// ── Offline banner ───────────────────────────────────────────────────────────
// Shell-level: tracks the browser's connectivity state and surfaces it
// explicitly rather than letting screens fail silently. Field/citizen surfaces
// that support offline drafts (Phase 3) will layer their own queue status on
// top of this.
export function useOnlineStatus(): boolean {
  const [online, setOnline] = useState(() => (typeof navigator === 'undefined' ? true : navigator.onLine))
  useEffect(() => {
    const goOnline = () => setOnline(true)
    const goOffline = () => setOnline(false)
    window.addEventListener('online', goOnline)
    window.addEventListener('offline', goOffline)
    return () => {
      window.removeEventListener('online', goOnline)
      window.removeEventListener('offline', goOffline)
    }
  }, [])
  return online
}

export function OfflineBanner() {
  const online = useOnlineStatus()
  if (online) return null
  return (
    <div
      role="status"
      className="flex items-center justify-center gap-2 bg-status-warning/15 px-4 py-1.5 text-xs font-semibold text-status-warning"
    >
      <span className="h-1.5 w-1.5 rounded-full bg-status-warning" aria-hidden />
      You&apos;re offline — showing the last data loaded on this device.
    </div>
  )
}
