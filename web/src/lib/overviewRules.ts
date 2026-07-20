/**
 * Pure derivation rules for the commander Overview page (CommandView.tsx).
 * No I/O here - mirrors incidentRules.ts's own convention (pure functions,
 * unit-tested directly rather than only through the UI). Every input here
 * comes from data already fetched by existing lib/*.ts functions; nothing
 * in this file invents a new metric that isn't grounded in real columns.
 */
import type { ActiveTaskDispatch } from './incidents'
import { minutesUntil } from './incidentRules'
import type { StationHealthRow } from './ops'
import type { WardForecastSummary, WardSummary } from './data'

export type TimeWindowHours = 12 | 24 | 36 | 48

export interface SevereWardAlert {
  wardId: number
  wardName: string
  peakPred: number | null
  hoursToSevere: number | null
}

/** Today's exact `grapAlerts` logic, generalized: `hoursToSevere <= windowHours`
 *  instead of a hardcoded 36. */
export function severeWardsWithin(
  wards: WardSummary[],
  forecasts: Map<number, WardForecastSummary>,
  windowHours: TimeWindowHours,
): SevereWardAlert[] {
  return [...forecasts.values()]
    .filter((f) => f.hoursToSevere != null && f.hoursToSevere <= windowHours)
    .map((f) => ({
      wardId: f.wardId,
      wardName: wards.find((w) => w.id === f.wardId)?.name ?? `Ward ${f.wardId}`,
      peakPred: f.peakPred,
      hoursToSevere: f.hoursToSevere,
    }))
    .sort((a, b) => (a.hoursToSevere ?? 99) - (b.hoursToSevere ?? 99))
}

/** The only real "confidence" value tied to a ward's forecast peak - the
 *  confidence of the specific point where the peak occurs, not an invented
 *  aggregate. */
export function confidenceAtPeak(forecast: WardForecastSummary | undefined): number | null {
  if (!forecast?.peakTs) return null
  return forecast.points.find((p) => p.horizon_ts === forecast.peakTs)?.confidence ?? null
}

export type HotspotStatus = 'severe' | 'watch' | 'stable' | 'no_data'

export const HOTSPOT_STATUS_LABEL: Record<HotspotStatus, string> = {
  severe: 'Severe imminent',
  watch: 'Trending up',
  stable: 'Stable',
  no_data: 'No data',
}

/** Severe (crossing within the selected window) -> Watch (rising local
 *  excess, not yet crossing) -> Stable (a current reading exists) -> No
 *  data. A UI-only categorization built entirely from fields the page
 *  already has - not a new detection signal. */
export function hotspotStatus(
  row: { hoursToSevere: number | null; peakExcess: number | null; aqi: number | null },
  windowHours: TimeWindowHours,
): HotspotStatus {
  if (row.hoursToSevere != null && row.hoursToSevere <= windowHours) return 'severe'
  if (row.peakExcess != null && row.peakExcess > 0) return 'watch'
  if (row.aqi != null) return 'stable'
  return 'no_data'
}

/** Same "first populated checkpoint column" fallback already duplicated in
 *  TasksView.tsx / FieldTaskDispatchCard.tsx / TaskDispatchPanel.tsx -
 *  centralizing here is incidental cleanup, not a new rule. */
export function nextDueAt(d: ActiveTaskDispatch): string | null {
  return d.sla_ack_due_at ?? d.sla_accept_due_at ?? d.sla_arrival_due_at ?? d.sla_completion_due_at
}

export interface DispatchSlaBuckets {
  overdue: number
  dueSoon: number
  onTrack: number
  noSla: number
}

/** overdue: past due. Due soon: due within 2h. On track: due later than
 *  that. No SLA: no checkpoint column populated at all (e.g. already
 *  awaiting verification). */
export function bucketDispatchSla(dispatches: ActiveTaskDispatch[]): DispatchSlaBuckets {
  const buckets: DispatchSlaBuckets = { overdue: 0, dueSoon: 0, onTrack: 0, noSla: 0 }
  for (const d of dispatches) {
    const mins = minutesUntil(nextDueAt(d))
    if (mins == null) buckets.noSla++
    else if (mins < 0) buckets.overdue++
    else if (mins <= 120) buckets.dueSoon++
    else buckets.onTrack++
  }
  return buckets
}

export interface SourceMixEntry {
  source: string
  count: number
}

/** Pure client-side tally of wards[].dominant_source - no new fetch. */
export function tallySourceMix(wards: WardSummary[]): SourceMixEntry[] {
  const counts = new Map<string, number>()
  for (const w of wards) {
    const key = w.dominant_source ?? 'Unknown'
    counts.set(key, (counts.get(key) ?? 0) + 1)
  }
  return [...counts.entries()]
    .map(([source, count]) => ({ source, count }))
    .sort((a, b) => b.count - a.count)
}

export interface StationHealthRollup {
  total: number
  active: number
  stale: number
  inactive: number
  topStale: { name: string; wardName: string | null; ageMinutes: number | null }[]
}

/** Compact summary distinct from the full /sensors page - no per-station
 *  actions here, those write paths stay on SensorsView.tsx. */
export function rollupStationHealth(rows: StationHealthRow[]): StationHealthRollup {
  const active = rows.filter((r) => r.is_active)
  const stale = active.filter((r) => r.is_stale)
  const inactive = rows.filter((r) => !r.is_active)
  const topStale = [...stale]
    .sort((a, b) => (b.latest_reading_age_minutes ?? 0) - (a.latest_reading_age_minutes ?? 0))
    .slice(0, 3)
    .map((r) => ({ name: r.name, wardName: r.ward_name, ageMinutes: r.latest_reading_age_minutes }))
  return { total: rows.length, active: active.length, stale: stale.length, inactive: inactive.length, topStale }
}
