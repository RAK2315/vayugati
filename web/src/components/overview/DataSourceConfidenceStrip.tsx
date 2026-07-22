import { AlertTriangle, Bus, Database, History } from 'lucide-react'
import type { TransportActivitySummary } from '../../lib/data'
import type { DataSourceTally } from '../../lib/latestReadingRules'

/**
 * At-a-glance rollup of which source is actually backing "latest reading"
 * right now, city-wide - a compact strip, not another dashboard. Every
 * number here is a plain count/passthrough of data Overview already
 * fetched (latestReadingsState, transitState) - nothing new requested,
 * nothing fabricated when a source is unavailable (shown as "—").
 */
export default function DataSourceConfidenceStrip({
  tally,
  transit,
}: {
  /** null while the CPCB/data.gov reconciliation hasn't loaded yet. */
  tally: DataSourceTally | null
  /** null while the Delhi OTD summary hasn't loaded yet or is unavailable. */
  transit: TransportActivitySummary | null
}) {
  const transitUnavailable = !transit || transit.unavailableReason != null

  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-2 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-xs shadow-card">
      <div className="flex items-center gap-1.5">
        <Database className="h-3.5 w-3.5 flex-shrink-0 text-accent-600" aria-hidden />
        <span className="text-slate-500">CPCB/data.gov matched</span>
        <span className="font-bold tabular-nums text-slate-900">{tally ? tally.cpcbMatched : '—'}</span>
      </div>
      <div className="flex items-center gap-1.5">
        <History className="h-3.5 w-3.5 flex-shrink-0 text-slate-400" aria-hidden />
        <span className="text-slate-500">OpenAQ fallback</span>
        <span className="font-bold tabular-nums text-slate-900">{tally ? tally.openaqFallback : '—'}</span>
      </div>
      <div className="flex items-center gap-1.5">
        <span className="text-slate-500">Forecast history</span>
        <span className="font-bold text-slate-900">OpenAQ</span>
      </div>
      <div className="flex items-center gap-1.5">
        <Bus className="h-3.5 w-3.5 flex-shrink-0 text-teal-600" aria-hidden />
        <span className="text-slate-500">Delhi OTD</span>
        <span className="font-bold tabular-nums text-slate-900">
          {transitUnavailable ? '—' : `${transit!.liveBusesTracked ?? '—'} vehicles / ${transit!.activeRoutes ?? '—'} routes`}
        </span>
      </div>
      <div className="flex items-center gap-1.5">
        <AlertTriangle className={`h-3.5 w-3.5 flex-shrink-0 ${tally && tally.staleOrMismatch > 0 ? 'text-status-warning' : 'text-slate-300'}`} aria-hidden />
        <span className="text-slate-500">Stale or mismatch flags</span>
        <span className={`font-bold tabular-nums ${tally && tally.staleOrMismatch > 0 ? 'text-status-warning' : 'text-slate-900'}`}>
          {tally ? tally.staleOrMismatch : '—'}
        </span>
      </div>
    </div>
  )
}
