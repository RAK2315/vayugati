import { Activity } from 'lucide-react'
import type { ForecastAccuracySummary, GatiMetrics } from '../../lib/data'
import { modelSelectionExplainer } from '../../lib/forecastTrustRules'
import type { DispatchSlaBuckets } from '../../lib/overviewRules'
import { Card, CardHeader, Stat } from '../ui'

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

        <p className="text-sm text-slate-600">{modelSelectionExplainer(accuracy.methodMix)}</p>
      </div>
    </Card>
  )
}
