import { CheckCircle2, TrendingUp } from 'lucide-react'
import type { ForecastAccuracySummary } from '../../lib/data'
import { BASELINE_DISPLAY_LABEL, forecastEngineStatusLine, modelSelectionExplainer, strongestBaselineLabel } from '../../lib/forecastTrustRules'
import { Card, CardHeader, ErrorState, Skeleton, Stat } from '../ui'

// Below this many validated ward/pollutant pairs, a beats-persistence
// percentage is more noise than signal - shown as "insufficient sample"
// rather than a misleadingly precise number. Not a backend threshold,
// purely a display-honesty cutoff.
const MIN_SAMPLE_FOR_PERCENT = 5

export default function ForecastTrustPanel({
  data,
  loading,
  error,
  onRetry,
}: {
  data: ForecastAccuracySummary | null
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  const trustPct =
    data && data.totalWardPollutantPairs >= MIN_SAMPLE_FOR_PERCENT
      ? Math.round((data.beatsPersistenceCount / data.totalWardPollutantPairs) * 100)
      : null

  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <TrendingUp className="h-4 w-4 text-accent-600" aria-hidden />
            Forecast trust
          </span>
        }
        subtitle="Latest run per ward + pollutant"
      />
      {loading ? (
        <div className="grid grid-cols-2 gap-2 p-4">
          <Skeleton className="h-16" />
          <Skeleton className="h-16" />
        </div>
      ) : error ? (
        <ErrorState message={error} onRetry={onRetry} />
      ) : !data || data.totalWardPollutantPairs === 0 ? (
        <p className="px-4 py-8 text-center text-sm text-slate-400">
          No forecast runs recorded yet - trust metrics will appear here once forecasts are generated and validated.
        </p>
      ) : (
        <div className="p-4">
          {/* Coverage first - "is this even running" is the question a reader
              asks before "how good is it", and answering it up front (in
              plain language, not a percentage) is what stops "1%" from
              being misread as "the system is down". */}
          <div className="flex items-start gap-1.5 rounded-lg bg-status-success/10 px-2.5 py-2 text-[11px] text-slate-700">
            <CheckCircle2 className="mt-0.5 h-3.5 w-3.5 flex-shrink-0 text-status-success" aria-hidden />
            <span>{forecastEngineStatusLine(data.coverage)}</span>
          </div>

          <p className="mt-2 text-[11px] leading-relaxed text-slate-500">{modelSelectionExplainer(data.methodMix)}</p>

          <div className="mt-3 grid grid-cols-2 gap-2">
            <Stat value={data.methodMix.lightgbmCount} label="Using machine learning" />
            <Stat value={data.methodMix.diurnalPersistenceCount} label="Using a safer baseline" />
            <Stat value={`${data.wardsWithAnyValidatedHorizon}/${data.totalWardPollutantPairs}`} label="Have a validated horizon" />
            <Stat
              value={trustPct != null ? `${trustPct}%` : `${data.beatsPersistenceCount}/${data.totalWardPollutantPairs}`}
              label="Beat plain persistence"
              accent={trustPct != null && trustPct >= 50 ? 'text-status-success' : undefined}
            />
          </div>
          {trustPct == null && (
            <p className="mt-2 rounded-lg bg-slate-50 px-2.5 py-2 text-[11px] text-slate-500">
              Insufficient sample size for a trust percentage (fewer than {MIN_SAMPLE_FOR_PERCENT} validated ward/pollutant pairs) - raw
              counts shown instead.
            </p>
          )}

          {strongestBaselineLabel(data.baselineWinners) && (
            <p className="mt-2 text-[11px] text-slate-500">
              {strongestBaselineLabel(data.baselineWinners)}{' '}
              <span className="text-slate-400">
                (of {Object.keys(BASELINE_DISPLAY_LABEL).length} candidate baselines compared: persistence, seasonal/hourly, same-hour-yesterday, rolling
                average)
              </span>
            </p>
          )}
          {data.baselineWinners.totalHorizonEntries === 0 && (
            <p className="mt-2 text-[11px] text-slate-400">
              Baseline-comparison detail isn't available yet for these rows - it appears after each ward/pollutant's next scheduled run.
            </p>
          )}

          {data.coverage.staleCount > 0 && (
            <p className="mt-2 rounded-lg bg-status-warning/10 px-2.5 py-2 text-[11px] text-status-warning">
              {data.coverage.staleCount} of {data.coverage.totalPairs} pairs haven't produced a new run recently - worth checking the ingest
              service if this persists.
            </p>
          )}
        </div>
      )}
    </Card>
  )
}
