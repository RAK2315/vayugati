import { Activity } from 'lucide-react'
import type { ForecastAccuracySummary, GatiMetrics } from '../../lib/data'
import { forecastPipelineStatusLabel } from '../../lib/forecastTrustRules'
import type { DispatchSlaBuckets } from '../../lib/overviewRules'
import { Card, CardHeader, Stat } from '../ui'

const PIPELINE_STATUS_TONE: Record<string, string> = {
  Live: 'text-status-success',
  'Partially live': 'text-status-warning',
  Stale: 'text-status-critical',
  'No data': 'text-slate-400',
}

function TrustRow({ label, value, tone = 'text-slate-800' }: { label: string; value: string; tone?: string }) {
  return (
    <div className="flex items-center justify-between text-sm">
      <span className="text-slate-500">{label}</span>
      <span className={`font-semibold tabular-nums ${tone}`}>{value}</span>
    </div>
  )
}

/** A live snapshot synthesis of already-fetched data - deliberately not an
 *  "improving/worsening" trend claim, since no historical time-series
 *  baseline exists in this app to honestly support that. */
export default function OperationalSummaryPanel({
  metrics,
  slaBuckets,
  accuracy,
}: {
  metrics: GatiMetrics
  slaBuckets: DispatchSlaBuckets
  accuracy: ForecastAccuracySummary
}) {
  return (
    <Card className="flex min-h-0 flex-1 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <Activity className="h-4 w-4 text-accent-600" aria-hidden />
            Operational Summary
          </span>
        }
        subtitle="Live snapshot of the current queue and forecast trust"
      />
      <div className="flex-1 space-y-4 overflow-y-auto px-4 py-3.5">
        <p className="text-sm text-slate-600">
          <span className="font-semibold text-slate-800">{metrics.openCount}</span> incidents open,{' '}
          <span className="font-semibold text-slate-800">{metrics.resolvedCount}</span> resolved with a recorded
          outcome
          {metrics.medianHours != null && (
            <>
              {' '}
              &mdash; median time to action{' '}
              <span className="font-semibold text-slate-800">{metrics.medianHours.toFixed(1)}h</span>
            </>
          )}
          .
        </p>

        <div>
          <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-slate-400">
            Active dispatch SLA
          </p>
          <div className="grid grid-cols-4 gap-2">
            <Stat value={slaBuckets.overdue} label="Overdue" accent="text-status-critical" />
            <Stat value={slaBuckets.dueSoon} label="Due soon" accent="text-status-warning" />
            <Stat value={slaBuckets.onTrack} label="On track" accent="text-status-success" />
            <Stat value={slaBuckets.noSla} label="No SLA" accent="text-slate-500" />
          </div>
        </div>

        <div>
          <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-slate-400">Forecast trust</p>
          <div className="space-y-1 rounded-lg bg-slate-50 px-3 py-2.5">
            <TrustRow
              label="Forecast pipeline"
              value={forecastPipelineStatusLabel(accuracy.coverage)}
              tone={PIPELINE_STATUS_TONE[forecastPipelineStatusLabel(accuracy.coverage)]}
            />
            <TrustRow label="Coverage" value={`${accuracy.coverage.freshCount}/${accuracy.coverage.totalPairs}`} />
            <TrustRow label="ML selected" value={String(accuracy.methodMix.lightgbmCount)} />
            <TrustRow label="Safer baseline" value={String(accuracy.methodMix.diurnalPersistenceCount)} />
          </div>
          <p className="mt-2 text-xs text-slate-500">ML is used only when it beats strong simple baselines.</p>
          {accuracy.coverage.latestGeneratedAt && (
            <p className="mt-1 text-[11px] text-slate-400">
              Latest forecast cycle: {new Date(accuracy.coverage.latestGeneratedAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })}
            </p>
          )}
        </div>
      </div>
    </Card>
  )
}
