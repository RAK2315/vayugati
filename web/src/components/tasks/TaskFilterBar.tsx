import { TASK_DISPATCH_STATUS_LABEL, type TaskDispatchStatus } from '../../lib/incidentRules'

export const ALL = '__all__'
export type DueWindow = typeof ALL | 'overdue' | 'today' | 'week'

const DUE_WINDOW_LABEL: Record<Exclude<DueWindow, typeof ALL>, string> = {
  overdue: 'Overdue',
  today: 'Due today',
  week: 'Due this week',
}

export interface TaskFilters {
  status: string
  ward: string
  agency: string
  severity: string
  dueWindow: DueWindow
}

function Select({
  value,
  onChange,
  children,
}: {
  value: string
  onChange: (v: string) => void
  children: React.ReactNode
}) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="focus-ring rounded-lg border border-slate-200 px-2 py-1.5 text-xs text-slate-700"
    >
      {children}
    </select>
  )
}

export default function TaskFilterBar({
  filters,
  onChange,
  statuses,
  wards,
  agencies,
  severities,
}: {
  filters: TaskFilters
  onChange: (next: TaskFilters) => void
  statuses: TaskDispatchStatus[]
  wards: string[]
  agencies: string[]
  severities: string[]
}) {
  const set = <K extends keyof TaskFilters>(key: K, value: TaskFilters[K]) => onChange({ ...filters, [key]: value })
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 shadow-card">
      <Select value={filters.status} onChange={(v) => set('status', v)}>
        <option value={ALL}>All statuses</option>
        {statuses.map((s) => (
          <option key={s} value={s}>
            {TASK_DISPATCH_STATUS_LABEL[s]}
          </option>
        ))}
      </Select>
      <Select value={filters.ward} onChange={(v) => set('ward', v)}>
        <option value={ALL}>All wards</option>
        {wards.map((w) => (
          <option key={w} value={w}>
            {w}
          </option>
        ))}
      </Select>
      <Select value={filters.agency} onChange={(v) => set('agency', v)}>
        <option value={ALL}>All authorities</option>
        {agencies.map((a) => (
          <option key={a} value={a}>
            {a}
          </option>
        ))}
      </Select>
      <Select value={filters.severity} onChange={(v) => set('severity', v)}>
        <option value={ALL}>All priorities</option>
        {severities.map((s) => (
          <option key={s} value={s} className="capitalize">
            {s}
          </option>
        ))}
      </Select>
      <Select value={filters.dueWindow} onChange={(v) => set('dueWindow', v as DueWindow)}>
        <option value={ALL}>Any due window</option>
        {(Object.keys(DUE_WINDOW_LABEL) as (keyof typeof DUE_WINDOW_LABEL)[]).map((w) => (
          <option key={w} value={w}>
            {DUE_WINDOW_LABEL[w]}
          </option>
        ))}
      </Select>
      {(filters.status !== ALL || filters.ward !== ALL || filters.agency !== ALL || filters.severity !== ALL || filters.dueWindow !== ALL) && (
        <button
          type="button"
          onClick={() => onChange({ status: ALL, ward: ALL, agency: ALL, severity: ALL, dueWindow: ALL })}
          className="focus-ring rounded-lg px-2 py-1.5 text-xs font-semibold text-accent-700 hover:bg-accent-50"
        >
          Clear filters
        </button>
      )}
    </div>
  )
}
