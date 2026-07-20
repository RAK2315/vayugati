import { Building2 } from 'lucide-react'
import type { AgencyPerformanceRow } from '../../lib/overviewRules'
import { Card, CardHeader, ErrorState, Skeleton } from '../ui'

export default function AgencyPerformancePanel({
  rows,
  windowLabel,
  loading,
  error,
  onRetry,
}: {
  rows: AgencyPerformanceRow[]
  windowLabel: string
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <Building2 className="h-4 w-4 text-accent-600" aria-hidden />
            Agency performance
          </span>
        }
        subtitle={`Dispatches by responsible authority - ${windowLabel}`}
      />
      <div className="overflow-x-auto">
        {loading ? (
          <div className="space-y-2 p-4">
            <Skeleton className="h-8 w-full" />
            <Skeleton className="h-8 w-full" />
          </div>
        ) : error ? (
          <ErrorState message={error} onRetry={onRetry} />
        ) : rows.length === 0 ? (
          <p className="px-4 py-8 text-center text-sm text-slate-400">
            No dispatches in this window - agency performance will appear here once incidents are routed to an authority.
          </p>
        ) : (
          <table className="w-full min-w-[600px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-400">
                <th className="px-3 py-2 font-semibold">Agency</th>
                <th className="px-3 py-2 font-semibold">Assigned</th>
                <th className="px-3 py-2 font-semibold">Completed</th>
                <th className="px-3 py-2 font-semibold">Overdue</th>
                <th className="px-3 py-2 font-semibold">Median response</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.agency}>
                  <td className="px-3 py-2 font-medium text-slate-800">{r.agency}</td>
                  <td className="px-3 py-2 tabular-nums text-slate-600">{r.assigned}</td>
                  <td className="px-3 py-2 tabular-nums text-status-success">{r.completed}</td>
                  <td className={`px-3 py-2 tabular-nums ${r.overdue > 0 ? 'font-semibold text-status-critical' : 'text-slate-400'}`}>
                    {r.overdue}
                  </td>
                  <td className="px-3 py-2 tabular-nums text-slate-600">
                    {r.medianResponseMinutes != null
                      ? r.medianResponseMinutes < 60
                        ? `${Math.round(r.medianResponseMinutes)}m`
                        : `${(r.medianResponseMinutes / 60).toFixed(1)}h`
                      : 'No sample'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </Card>
  )
}
