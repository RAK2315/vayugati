/**
 * Pure derivation rules for the "Forecast Trust" surface (Analytics KPI
 * strip + ForecastTrustPanel). No I/O here - mirrors incidentRules.ts's and
 * overviewRules.ts's own convention (pure functions, unit-tested directly).
 *
 * Every function here operates on the LATEST forecast_runs row per
 * (ward_id, pollutant) pair, matching ForecastTrustPanel's own existing
 * subtitle ("Latest validated run per ward + pollutant") - not a historical
 * distribution across every run ever generated. The caller (data.ts) owns
 * fetching + deduping to "latest per pair"; this file only derives summaries
 * from whatever array it's handed.
 *
 * The forecast-gate upgrade (docs/data/forecast-baseline-gate-upgrade.md)
 * added new validation_metrics keys (best_baseline, best_baseline_mae,
 * diurnal_mae, same_hour_yesterday_mae, rolling_24h_avg_mae) without a
 * migration or a schema change - they're additive keys inside the
 * pre-existing free-form jsonb column. Every function below MUST tolerate
 * rows written before that upgrade shipped (validation_metrics = {}, or
 * present but missing the new keys entirely) - a mixed fleet of old and new
 * rows is the expected steady state until every ward has cycled through at
 * least one post-upgrade run, not an edge case to special-case away.
 */
import type { Json } from './database.types'

export type ForecastMethod = 'lightgbm' | 'diurnal_persistence'

export interface ForecastRunLike {
  ward_id: number
  pollutant: string
  method: string
  beats_persistence: boolean
  max_validated_horizon_hours: number | null
  generated_at: string
  validation_metrics: Json
}

// ── method mix: is the engine choosing ML or the conservative fallback? ─────

export interface ForecastMethodMix {
  lightgbmCount: number
  diurnalPersistenceCount: number
  /** Defensive only - forecast_runs.method has a DB CHECK constraint
   *  limiting it to 'lightgbm'/'diurnal_persistence', so this should always
   *  be 0 in practice. Counted rather than silently dropped so a genuine
   *  future third value would be visible here instead of vanishing. */
  otherCount: number
  total: number
}

export function summarizeForecastMethodMix(rows: { method: string }[]): ForecastMethodMix {
  let lightgbmCount = 0
  let diurnalPersistenceCount = 0
  let otherCount = 0
  for (const r of rows) {
    if (r.method === 'lightgbm') lightgbmCount++
    else if (r.method === 'diurnal_persistence') diurnalPersistenceCount++
    else otherCount++
  }
  return { lightgbmCount, diurnalPersistenceCount, otherCount, total: rows.length }
}

// ── baseline winners: which simple baseline is hardest to beat, if known ────

const KNOWN_BASELINE_NAMES = ['persistence', 'diurnal', 'same_hour_yesterday', 'rolling_24h_avg'] as const
export type BaselineName = (typeof KNOWN_BASELINE_NAMES)[number]

export interface BaselineWinnerTally {
  /** best_baseline -> how many horizon-entries (across all rows) it won.
   *  Only the four known names are ever counted - see docs/data/
   *  forecast-baseline-gate-upgrade.md §1 for what each one means. */
  counts: Record<BaselineName, number>
  /** Horizon-entries counted (a row can contribute up to 4, one per
   *  validated horizon - 6h/12h/24h/48h). */
  totalHorizonEntries: number
  /** Rows that had at least one horizon with a `best_baseline` key -
   *  i.e., written by the post-upgrade code. */
  rowsWithBaselineData: number
  /** Rows with no usable baseline-comparison data at all - either an empty
   *  validation_metrics ({}) or a pre-upgrade row that predates the new
   *  keys. Real, honest count, never silently merged into "0 wins". */
  rowsWithoutBaselineData: number
}

function isPlainObject(v: Json | undefined): v is { [key: string]: Json | undefined } {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

/** Reads `best_baseline` off one horizon-entry, tolerating every shape a
 *  real row can have: missing entirely (pre-upgrade), present but not a
 *  known name (defensive), or a genuinely new-shape entry. */
function horizonBestBaseline(entry: Json | undefined): BaselineName | null {
  if (!isPlainObject(entry)) return null
  const val = entry.best_baseline
  return typeof val === 'string' && (KNOWN_BASELINE_NAMES as readonly string[]).includes(val) ? (val as BaselineName) : null
}

export function summarizeBaselineWinners(rows: { validation_metrics: Json }[]): BaselineWinnerTally {
  const counts: Record<BaselineName, number> = {
    persistence: 0,
    diurnal: 0,
    same_hour_yesterday: 0,
    rolling_24h_avg: 0,
  }
  let totalHorizonEntries = 0
  let rowsWithBaselineData = 0
  let rowsWithoutBaselineData = 0

  for (const r of rows) {
    const vm = r.validation_metrics
    if (!isPlainObject(vm) || Object.keys(vm).length === 0) {
      rowsWithoutBaselineData++
      continue
    }
    let rowHadAny = false
    for (const entry of Object.values(vm)) {
      const winner = horizonBestBaseline(entry)
      if (winner) {
        counts[winner]++
        totalHorizonEntries++
        rowHadAny = true
      }
    }
    if (rowHadAny) rowsWithBaselineData++
    else rowsWithoutBaselineData++
  }

  return { counts, totalHorizonEntries, rowsWithBaselineData, rowsWithoutBaselineData }
}

// ── reach: how much of the city/pollutant surface does this cover? ──────────

export interface ForecastReachSummary {
  distinctWardCount: number
  pollutants: string[]
}

/** Distinct wards and pollutants represented in the given rows - answers
 *  "wards/pollutants covered", separate from the raw pair count
 *  (ForecastMethodMix.total mixes wards × pollutants together). */
export function summarizeForecastReach(rows: { ward_id: number; pollutant: string }[]): ForecastReachSummary {
  const wardIds = new Set<number>()
  const pollutants = new Set<string>()
  for (const r of rows) {
    wardIds.add(r.ward_id)
    pollutants.add(r.pollutant)
  }
  return { distinctWardCount: wardIds.size, pollutants: [...pollutants].sort() }
}

// ── coverage & staleness: is the engine actually running, and recently? ─────

/** Display-only heuristic, not a backend threshold - same spirit as
 *  ForecastTrustPanel's own MIN_SAMPLE_FOR_PERCENT. Production's observed
 *  cadence is close to hourly (docs/data/forecast-gate-production-
 *  verification.md), so 6h is generous enough to absorb one or two missed
 *  cycles without false-flagging, while still catching a genuinely stuck
 *  pipeline well before a full day goes by. */
export const FORECAST_RUN_STALE_HOURS = 6

export interface ForecastCoverageSummary {
  /** Distinct (ward, pollutant) pairs with at least one recorded run -
   *  NOT compared against a theoretical total (that would need a separate
   *  wards x enabled-pollutants query this summary doesn't have); see
   *  docs/data/forecast-trust-ui-framing-report.md for why "fully missing"
   *  (zero runs ever) isn't separately counted here. */
  totalPairs: number
  staleCount: number
  freshCount: number
  latestGeneratedAt: string | null
}

export function summarizeForecastCoverage(
  rows: { generated_at: string }[],
  now: Date = new Date(),
): ForecastCoverageSummary {
  let staleCount = 0
  let latestMs: number | null = null
  const staleCutoffMs = now.getTime() - FORECAST_RUN_STALE_HOURS * 3_600_000

  for (const r of rows) {
    const ms = new Date(r.generated_at).getTime()
    if (!Number.isFinite(ms)) continue
    if (ms < staleCutoffMs) staleCount++
    if (latestMs == null || ms > latestMs) latestMs = ms
  }

  return {
    totalPairs: rows.length,
    staleCount,
    freshCount: rows.length - staleCount,
    latestGeneratedAt: latestMs != null ? new Date(latestMs).toISOString() : null,
  }
}

// ── plain-language framing (the actual point of this file) ──────────────────

/** The one line ForecastTrustPanel leads with - written so "mostly
 *  fallback" reads as intentional caution, not failure. Never claims a
 *  baseline forecast is bad, never claims ML is always better - both
 *  explicitly ruled out by docs/data/forecast-trust-ui-framing-report.md's
 *  brief. */
export function forecastEngineStatusLine(coverage: ForecastCoverageSummary): string {
  if (coverage.totalPairs === 0) {
    return 'No forecast runs recorded yet.'
  }
  if (coverage.freshCount === 0) {
    return `Forecasts have not refreshed in over ${FORECAST_RUN_STALE_HOURS}h - the pipeline may be stuck.`
  }
  if (coverage.staleCount > 0) {
    return `Forecasts are live for ${coverage.freshCount} of ${coverage.totalPairs} ward/pollutant pairs; ${coverage.staleCount} haven't refreshed recently.`
  }
  return `Forecasts are live for all ${coverage.totalPairs} ward/pollutant pairs.`
}

/** The model-selection explainer - the specific honesty-vs-alarm framing
 *  this whole feature exists to get right. */
export function modelSelectionExplainer(mix: ForecastMethodMix): string {
  if (mix.total === 0) return 'No forecasts to evaluate yet.'
  const pct = Math.round((mix.lightgbmCount / mix.total) * 100)
  return (
    `The system uses machine learning (LightGBM) only when it beats the strongest of several simple baselines - ` +
    `persistence, seasonal/hourly patterns, same-hour-yesterday, and a rolling average. Right now that happens for ` +
    `${mix.lightgbmCount} of ${mix.total} pairs (${pct}%); the rest use the best-performing simple baseline instead, ` +
    `which is the safer, still-real choice when ML hasn't proven itself for that ward and pollutant yet.`
  )
}

/** Which baseline is hardest to beat, in one line - omitted entirely (by
 *  the caller checking rowsWithBaselineData) when no post-upgrade rows
 *  exist yet, rather than showing a misleading "0 for everything" chart. */
export function strongestBaselineLabel(tally: BaselineWinnerTally): string | null {
  if (tally.totalHorizonEntries === 0) return null
  const [name, count] = (Object.entries(tally.counts) as [BaselineName, number][]).sort((a, b) => b[1] - a[1])[0]
  const pct = Math.round((count / tally.totalHorizonEntries) * 100)
  const label = BASELINE_DISPLAY_LABEL[name]
  return `${label} is the strongest baseline most often (${pct}% of validated horizons).`
}

export const BASELINE_DISPLAY_LABEL: Record<BaselineName, string> = {
  persistence: 'Persistence',
  diurnal: 'Seasonal/hourly average',
  same_hour_yesterday: 'Same hour yesterday',
  rolling_24h_avg: '24h rolling average',
}
