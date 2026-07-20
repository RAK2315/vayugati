import { ShieldCheck } from 'lucide-react'
import { INCIDENT_OUTCOME_LABEL } from '../../lib/incidentRules'
import type { ImpactOutcomeSummary } from '../../lib/data'
import { Card, CardHeader, ErrorState, Skeleton } from '../ui'

const POSITIVE = new Set(['effective', 'partly_effective'])
const NEGATIVE = new Set(['ineffective', 'source_disproved', 'recurred'])

export default function InterventionOutcomesPanel({
  rows,
  loading,
  error,
  onRetry,
}: {
  rows: ImpactOutcomeSummary[]
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  const total = rows.reduce((s, r) => s + r.count, 0)
  const effective = rows.filter((r) => POSITIVE.has(r.outcome)).reduce((s, r) => s + r.count, 0)
  const ineffective = rows.filter((r) => NEGATIVE.has(r.outcome)).reduce((s, r) => s + r.count, 0)

  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <ShieldCheck className="h-4 w-4 text-accent-600" aria-hidden />
            Intervention outcomes
          </span>
        }
        subtitle={total > 0 ? `${total} verified impact evaluation(s) - all-time` : 'Post-action verification, all-time'}
      />
      {loading ? (
        <div className="space-y-2 p-4">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
        </div>
      ) : error ? (
        <ErrorState message={error} onRetry={onRetry} />
      ) : total === 0 ? (
        <p className="px-4 py-8 text-center text-sm text-slate-400">
          No impact evaluations recorded yet - verification results will appear here once field actions are evaluated.
        </p>
      ) : (
        <>
          <div className="grid grid-cols-3 gap-2 p-4">
            <div className="rounded-xl bg-slate-50 px-3 py-2.5 text-center">
              <p className="text-xl font-bold tabular-nums text-slate-900">{total}</p>
              <p className="mt-0.5 text-[11px] text-slate-500">Completed &amp; verified</p>
            </div>
            <div className="rounded-xl bg-status-success/10 px-3 py-2.5 text-center">
              <p className="text-xl font-bold tabular-nums text-status-success">{effective}</p>
              <p className="mt-0.5 text-[11px] text-slate-500">Effective / partly</p>
            </div>
            <div className="rounded-xl bg-status-critical/10 px-3 py-2.5 text-center">
              <p className="text-xl font-bold tabular-nums text-status-critical">{ineffective}</p>
              <p className="mt-0.5 text-[11px] text-slate-500">Ineffective / recurred</p>
            </div>
          </div>
          <ul className="divide-y divide-slate-100 border-t border-slate-100">
            {rows.map((r) => (
              <li key={r.outcome} className="flex items-center justify-between px-4 py-2 text-sm">
                <span className="text-slate-600">{INCIDENT_OUTCOME_LABEL[r.outcome as keyof typeof INCIDENT_OUTCOME_LABEL] ?? r.outcome}</span>
                <span className="font-semibold tabular-nums text-slate-900">{r.count}</span>
              </li>
            ))}
          </ul>
        </>
      )}
    </Card>
  )
}
