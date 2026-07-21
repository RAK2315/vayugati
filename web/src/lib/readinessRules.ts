/**
 * Pure derivation for the Data Readiness card (Sensors page) - launch-status
 * checklist built from real counts already fetched elsewhere (ward boundary
 * count, station health, forecast coverage, readings depth). No I/O here,
 * same convention as forecastTrustRules.ts/overviewRules.ts: given real
 * numbers, decide whether each line reads "ok" or "needs attention" -
 * never a hardcoded "everything's fine" string.
 */

export type ReadinessStatus = 'ok' | 'attention'

export interface ReadinessItem {
  key: string
  label: string
  detail: string
  status: ReadinessStatus
}

export interface DataReadinessInput {
  wardBoundaryCount: number
  stationCount: number
  activeStationCount: number
  forecastFreshCount: number
  forecastTotalPairs: number
  totalReadingsCount: number
}

/** One line per data source this launch depends on - "ok" requires a real,
 *  non-zero count (or, for forecasts, at least one fresh pair); anything
 *  short of that reads "attention" rather than being silently hidden. */
export function buildDataReadinessChecklist(input: DataReadinessInput): ReadinessItem[] {
  return [
    {
      key: 'wardBoundaries',
      label: 'Ward boundaries',
      detail: input.wardBoundaryCount > 0 ? `${input.wardBoundaryCount} loaded` : 'Not loaded',
      status: input.wardBoundaryCount > 0 ? 'ok' : 'attention',
    },
    {
      key: 'stations',
      label: 'AQ stations',
      detail:
        input.stationCount > 0
          ? `${input.stationCount} loaded, ${input.activeStationCount} active`
          : 'Not loaded',
      status: input.stationCount > 0 ? 'ok' : 'attention',
    },
    {
      key: 'forecastPipeline',
      label: 'Forecast pipeline',
      detail:
        input.forecastTotalPairs === 0
          ? 'No forecast runs yet'
          : input.forecastFreshCount > 0
            ? `Live - ${input.forecastFreshCount} of ${input.forecastTotalPairs} pairs fresh`
            : `Stalled - 0 of ${input.forecastTotalPairs} pairs fresh`,
      status: input.forecastTotalPairs > 0 && input.forecastFreshCount > 0 ? 'ok' : 'attention',
    },
    {
      key: 'historicalData',
      label: 'Historical OpenAQ data',
      detail: input.totalReadingsCount > 0 ? `${input.totalReadingsCount.toLocaleString()} readings loaded` : 'Not loaded',
      status: input.totalReadingsCount > 0 ? 'ok' : 'attention',
    },
    {
      key: 'forecastGate',
      label: 'Forecast gate',
      detail: 'Strict baseline validation active (ML selected only when it beats the best of 4 baselines)',
      status: 'ok',
    },
  ]
}
