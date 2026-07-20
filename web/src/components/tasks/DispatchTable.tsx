import { ChevronRight } from 'lucide-react'
import { Link } from 'react-router-dom'
import type { SourceCategory } from '../../lib/incidentRules'
import { slaCountdownLabel, sourceCategoryLabel } from '../../lib/incidentRules'
import type { ActiveTaskDispatch } from '../../lib/incidents'
import { nextDueAt } from '../../lib/overviewRules'
import { Card, CardHeader, ErrorState, Skeleton } from '../ui'
import EmptyDispatchState from './EmptyDispatchState'
import TaskStatusBadge, { TaskPriorityBadge } from './TaskStatusBadge'

function timeAgo(ts: string | null): string {
  if (!ts) return '—'
  const mins = Math.floor((Date.now() - new Date(ts).getTime()) / 60_000)
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 48) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

export default function DispatchTable({
  rows,
  totalCount,
  loading,
  error,
  onRetry,
  selectedId,
  onSelect,
  leadingSourceById,
  isFiltered,
}: {
  rows: ActiveTaskDispatch[]
  totalCount: number
  loading: boolean
  error: string | null
  onRetry: () => void
  selectedId: number | null
  onSelect: (id: number) => void
  leadingSourceById: Map<number, SourceCategory>
  isFiltered: boolean
}) {
  return (
    <Card className="flex min-h-0 flex-1 flex-col overflow-hidden">
      <CardHeader
        title="Active dispatches"
        subtitle={`${rows.length} of ${totalCount} shown - click a row for detail`}
      />
      <div className="min-h-0 flex-1 overflow-auto">
        {loading && rows.length === 0 ? (
          <div className="space-y-2 p-4">
            <Skeleton className="h-10 w-full" />
            <Skeleton className="h-10 w-full" />
            <Skeleton className="h-10 w-full" />
            <Skeleton className="h-10 w-full" />
          </div>
        ) : error ? (
          <ErrorState message={error} onRetry={onRetry} />
        ) : rows.length === 0 ? (
          <EmptyDispatchState filtered={isFiltered} />
        ) : (
          <table className="w-full min-w-[1080px] border-collapse text-sm">
            <thead className="sticky top-0 z-10 bg-slate-50">
              <tr className="border-b border-slate-200 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-400">
                <th className="px-3 py-2 font-semibold">Task</th>
                <th className="px-3 py-2 font-semibold">Ward</th>
                <th className="px-3 py-2 font-semibold">Likely source</th>
                <th className="px-3 py-2 font-semibold">Assigned authority</th>
                <th className="px-3 py-2 font-semibold">Priority</th>
                <th className="px-3 py-2 font-semibold">SLA</th>
                <th className="px-3 py-2 font-semibold">Status</th>
                <th className="px-3 py-2 font-semibold">Evidence</th>
                <th className="px-3 py-2 font-semibold">Updated</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((d) => {
                const selected = d.id === selectedId
                const leading = d.incident_id != null ? leadingSourceById.get(d.incident_id) : undefined
                const checklistCount = d.action_checklist_snapshot?.length ?? 0
                const dueLabel = slaCountdownLabel(nextDueAt(d))
                return (
                  <tr
                    key={d.id}
                    onClick={() => onSelect(d.id)}
                    className={`cursor-pointer transition ${selected ? 'bg-accent-50' : 'hover:bg-slate-50'}`}
                  >
                    <td className="max-w-[220px] px-3 py-2">
                      <p className="truncate font-medium text-slate-800">
                        {d.incident_summary ?? `Incident #${d.incident_id ?? '—'}`}
                      </p>
                      <Link
                        to={d.incident_id != null ? `/incidents?incident=${d.incident_id}` : '/incidents'}
                        onClick={(e) => e.stopPropagation()}
                        className="focus-ring text-[11px] text-accent-700 hover:underline"
                      >
                        View incident
                      </Link>
                    </td>
                    <td className="px-3 py-2 text-slate-600">{d.ward_name ?? '—'}</td>
                    <td className="px-3 py-2 text-slate-600">{leading ? sourceCategoryLabel(leading) : '—'}</td>
                    <td className="px-3 py-2 text-slate-600">{d.responsible_agency ?? 'Unrouted'}</td>
                    <td className="px-3 py-2">
                      <TaskPriorityBadge severity={d.incident_severity} />
                    </td>
                    <td
                      className={`px-3 py-2 tabular-nums ${dueLabel.startsWith('Overdue') ? 'font-semibold text-status-critical' : 'text-slate-600'}`}
                    >
                      {dueLabel}
                    </td>
                    <td className="px-3 py-2">
                      <TaskStatusBadge status={d.status} />
                    </td>
                    <td className="px-3 py-2 text-slate-500">
                      {checklistCount > 0 ? `${checklistCount} item${checklistCount === 1 ? '' : 's'}` : 'None recorded'}
                    </td>
                    <td className="px-3 py-2 tabular-nums text-slate-400">{timeAgo(d.updated_at)}</td>
                    <td className="w-6 px-1 text-slate-300">
                      <ChevronRight className="h-4 w-4" aria-hidden />
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </Card>
  )
}
