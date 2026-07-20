import { Flame, Repeat } from 'lucide-react'
import type { SourceMixEntry } from '../../lib/overviewRules'
import type { RecurringWardSummary } from '../../lib/overviewRules'
import { sourceCategoryLabel, type SourceCategory } from '../../lib/incidentRules'
import { Card, CardHeader, ErrorState, Skeleton } from '../ui'

export default function RecurrencePanel({
  recurringWards,
  sourceMix,
  windowLabel,
  loading,
  error,
  onRetry,
}: {
  recurringWards: RecurringWardSummary[]
  sourceMix: SourceMixEntry[]
  windowLabel: string
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card className="flex min-h-0 flex-col overflow-hidden">
        <CardHeader
          title={
            <span className="flex items-center gap-1.5">
              <Repeat className="h-4 w-4 text-status-warning" aria-hidden />
              Recurring hotspots
            </span>
          }
          subtitle={`Wards with a flagged recurrence - ${windowLabel}`}
        />
        {loading ? (
          <div className="space-y-2 p-4">
            <Skeleton className="h-8 w-full" />
            <Skeleton className="h-8 w-full" />
          </div>
        ) : error ? (
          <ErrorState message={error} onRetry={onRetry} />
        ) : recurringWards.length === 0 ? (
          <p className="px-4 py-8 text-center text-sm text-slate-400">
            No recurrences flagged in this window - a ward appears here once a closed incident there is reopened as a
            recurrence.
          </p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {recurringWards.slice(0, 8).map((w) => (
              <li key={w.wardId} className="flex items-center justify-between px-4 py-2 text-sm">
                <span className="font-medium text-slate-700">{w.wardName}</span>
                <span className="font-semibold tabular-nums text-status-warning">{w.recurrenceCount}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card className="flex min-h-0 flex-col overflow-hidden">
        <CardHeader
          title={
            <span className="flex items-center gap-1.5">
              <Flame className="h-4 w-4 text-status-critical" aria-hidden />
              Dominant source mix
            </span>
          }
          subtitle="Current leading suspected source, by ward - city-wide"
        />
        {loading ? (
          <div className="space-y-2 p-4">
            <Skeleton className="h-6 w-full" />
            <Skeleton className="h-6 w-full" />
          </div>
        ) : error ? (
          <ErrorState message={error} onRetry={onRetry} />
        ) : sourceMix.length === 0 ? (
          <p className="px-4 py-8 text-center text-sm text-slate-400">No ward source data available yet.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {sourceMix.map((s) => (
              <li key={s.source} className="flex items-center justify-between px-4 py-2 text-sm">
                <span className="capitalize text-slate-600">
                  {s.source === 'Unknown' ? 'Unknown' : sourceCategoryLabel(s.source as SourceCategory)}
                </span>
                <span className="font-semibold tabular-nums text-slate-900">{s.count} ward(s)</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  )
}
