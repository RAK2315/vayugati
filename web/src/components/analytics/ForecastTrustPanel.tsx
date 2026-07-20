import { TrendingUp } from 'lucide-react'
import type { ForecastAccuracySummary } from '../../lib/data'
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
        subtitle="Latest validated run per ward + pollutant"
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
          <div className="grid grid-cols-2 gap-2">
            <Stat value={`${data.wardsWithAnyValidatedHorizon}/${data.totalWardPollutantPairs}`} label="Have a validated horizon" />
            <Stat
              value={trustPct != null ? `${trustPct}%` : `${data.beatsPersistenceCount}/${data.totalWardPollutantPairs}`}
              label="Beat the persistence baseline"
              accent={trustPct != null && trustPct >= 50 ? 'text-status-success' : undefined}
            />
          </div>
          {trustPct == null && (
            <p className="mt-2 rounded-lg bg-slate-50 px-2.5 py-2 text-[11px] text-slate-500">
              Insufficient sample size for a trust percentage (fewer than {MIN_SAMPLE_FOR_PERCENT} validated ward/pollutant pairs) - raw
              counts shown instead.
            </p>
          )}
        </div>
      )}
    </Card>
  )
}
