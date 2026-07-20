export type SensorStatus = 'active' | 'stale' | 'offline' | 'no_data' | 'unknown'

export const SENSOR_STATUS_LABEL: Record<SensorStatus, string> = {
  active: 'Active',
  stale: 'Stale',
  offline: 'Offline',
  no_data: 'No recent data',
  unknown: 'Unknown',
}

const TONE: Record<SensorStatus, string> = {
  active: 'text-status-success ring-status-success/40',
  stale: 'text-status-warning ring-status-warning/40',
  offline: 'text-slate-500 ring-slate-300',
  no_data: 'text-status-critical ring-status-critical/40',
  unknown: 'text-slate-400 ring-slate-200',
}

const DOT: Record<SensorStatus, string> = {
  active: 'bg-status-success',
  stale: 'bg-status-warning',
  offline: 'bg-slate-400',
  no_data: 'bg-status-critical',
  unknown: 'bg-slate-300',
}

/** Real classification, not a guess: offline = deliberately deactivated
 *  (stations.is_active = false, the operator's own toggle below); no_data =
 *  active but has never produced a reading; stale = active, has readings,
 *  but the newest one is older than STATION_STALE_MINUTES (ops.ts, the same
 *  cutoff the ingest service's own /health check uses); active = fresh. */
export function sensorStatus(row: { is_active: boolean; is_stale: boolean; latest_reading_at: string | null }): SensorStatus {
  if (!row.is_active) return 'offline'
  if (row.latest_reading_at == null) return 'no_data'
  if (row.is_stale) return 'stale'
  return 'active'
}

export default function SensorStatusBadge({ status }: { status: SensorStatus }) {
  return (
    <span className={`inline-flex items-center gap-1 whitespace-nowrap rounded px-1.5 py-0.5 text-[11px] font-semibold ring-1 ring-inset ${TONE[status]}`}>
      <span className={`h-1.5 w-1.5 rounded-full ${DOT[status]}`} aria-hidden />
      {SENSOR_STATUS_LABEL[status]}
    </span>
  )
}
