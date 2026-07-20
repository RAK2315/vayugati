import { SENSOR_STATUS_LABEL, type SensorStatus } from './SensorStatusBadge'

export const ALL = '__all__'

export interface SensorFilters {
  status: string
  ward: string
  sensorType: string
}

export default function SensorFilterBar({
  filters,
  onChange,
  statuses,
  wards,
  sensorTypes,
}: {
  filters: SensorFilters
  onChange: (next: SensorFilters) => void
  statuses: SensorStatus[]
  wards: string[]
  sensorTypes: string[]
}) {
  const set = <K extends keyof SensorFilters>(key: K, value: SensorFilters[K]) => onChange({ ...filters, [key]: value })
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 shadow-card">
      <select
        value={filters.status}
        onChange={(e) => set('status', e.target.value)}
        className="focus-ring rounded-lg border border-slate-200 px-2 py-1.5 text-xs text-slate-700"
      >
        <option value={ALL}>All statuses</option>
        {statuses.map((s) => (
          <option key={s} value={s}>
            {SENSOR_STATUS_LABEL[s]}
          </option>
        ))}
      </select>
      <select
        value={filters.ward}
        onChange={(e) => set('ward', e.target.value)}
        className="focus-ring rounded-lg border border-slate-200 px-2 py-1.5 text-xs text-slate-700"
      >
        <option value={ALL}>All wards</option>
        {wards.map((w) => (
          <option key={w} value={w}>
            {w}
          </option>
        ))}
      </select>
      <select
        value={filters.sensorType}
        onChange={(e) => set('sensorType', e.target.value)}
        className="focus-ring rounded-lg border border-slate-200 px-2 py-1.5 text-xs text-slate-700"
      >
        <option value={ALL}>All types</option>
        {sensorTypes.map((t) => (
          <option key={t} value={t} className="uppercase">
            {t}
          </option>
        ))}
      </select>
      {(filters.status !== ALL || filters.ward !== ALL || filters.sensorType !== ALL) && (
        <button
          type="button"
          onClick={() => onChange({ status: ALL, ward: ALL, sensorType: ALL })}
          className="focus-ring rounded-lg px-2 py-1.5 text-xs font-semibold text-accent-700 hover:bg-accent-50"
        >
          Clear filters
        </button>
      )}
    </div>
  )
}
