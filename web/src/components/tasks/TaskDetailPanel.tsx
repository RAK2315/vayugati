import { CheckCircle2, Circle, X } from 'lucide-react'
import { Link } from 'react-router-dom'
import { INCIDENT_OUTCOME_LABEL } from '../../lib/incidentRules'
import { getImpactEvaluationForAction, listActionEvidenceForAction, type ActiveTaskDispatch } from '../../lib/incidents'
import { useAsync } from '../../lib/useAsync'
import { Skeleton } from '../ui'
import TaskStatusBadge, { TaskPriorityBadge } from './TaskStatusBadge'

const SLA_CHECKPOINTS: { key: keyof ActiveTaskDispatch; label: string; doneKey: keyof ActiveTaskDispatch }[] = [
  { key: 'sla_ack_due_at', label: 'Acknowledge', doneKey: 'acknowledged_at' },
  { key: 'sla_accept_due_at', label: 'Accept', doneKey: 'accepted_at' },
  { key: 'sla_arrival_due_at', label: 'Arrive on site', doneKey: 'arrived_at' },
  { key: 'sla_completion_due_at', label: 'Complete', doneKey: 'completed_at' },
  { key: 'sla_verification_due_at', label: 'Verify', doneKey: 'verified_at' },
]

// Every timestamp actually populated on the row, in a fixed chronological
// order - this IS the dispatch's real activity timeline, not a separate
// fabricated log. A checkpoint with no timestamp simply hasn't happened yet.
const TIMELINE_STEPS: { key: keyof ActiveTaskDispatch; label: string }[] = [
  { key: 'created_at', label: 'Dispatch created' },
  { key: 'routed_at', label: 'Routed to authority' },
  { key: 'sent_at', label: 'Sent' },
  { key: 'acknowledged_at', label: 'Acknowledged' },
  { key: 'accepted_at', label: 'Accepted' },
  { key: 'arrived_at', label: 'Arrived on site' },
  { key: 'completed_at', label: 'Completed' },
  { key: 'verification_requested_at', label: 'Verification requested' },
  { key: 'verified_at', label: 'Verified' },
  { key: 'escalated_at', label: 'Escalated' },
]

function fmt(ts: string | null | undefined): string {
  return ts ? new Date(ts).toLocaleString() : '—'
}

export default function TaskDetailPanel({ task, onClose }: { task: ActiveTaskDispatch; onClose: () => void }) {
  const evidence = useAsync(() => listActionEvidenceForAction(task.action_id), [task.action_id])
  const impact = useAsync(() => getImpactEvaluationForAction(task.action_id), [task.action_id])

  const requiredItems = task.action_checklist_snapshot ?? []
  const submittedTypes = new Set((evidence.data ?? []).map((e) => e.evidence_type))

  const exceptionNote = task.cancellation_reason ?? task.rejection_reason ?? task.dispute_resolution_note ?? task.escalation_reason ?? null

  const timelineEntries = TIMELINE_STEPS.map((s) => ({ ...s, ts: task[s.key] as string | null })).filter((s) => s.ts)

  return (
    <div className="flex h-full flex-col overflow-y-auto">
      <div className="flex items-start justify-between gap-2 border-b border-slate-100 p-4">
        <div className="min-w-0">
          <p className="text-[10px] font-semibold uppercase tracking-wide text-slate-400">
            Dispatch #{task.id}
          </p>
          <h2 className="truncate text-sm font-semibold text-slate-800">
            {task.incident_summary ?? `Incident #${task.incident_id ?? '—'}`}
          </h2>
          <Link
            to={task.incident_id != null ? `/incidents?incident=${task.incident_id}` : '/incidents'}
            className="focus-ring text-xs text-accent-700 hover:underline"
          >
            Open full incident workspace
          </Link>
        </div>
        <button type="button" onClick={onClose} className="focus-ring flex-shrink-0 rounded p-1 text-slate-400 hover:bg-slate-100">
          <X className="h-3.5 w-3.5" aria-hidden />
        </button>
      </div>

      <div className="space-y-4 p-4">
        <div className="flex flex-wrap items-center gap-1.5">
          <TaskStatusBadge status={task.status} />
          <TaskPriorityBadge severity={task.incident_severity} />
          {task.action_priority_score != null && (
            <span className="text-[11px] text-slate-400">score {task.action_priority_score.toFixed(1)}</span>
          )}
        </div>

        <dl className="grid grid-cols-2 gap-x-3 gap-y-2 text-xs">
          <div>
            <dt className="text-slate-400">Ward</dt>
            <dd className="font-medium text-slate-800">{task.ward_name ?? 'Unknown'}</dd>
          </div>
          <div>
            <dt className="text-slate-400">Location</dt>
            <dd className="font-medium text-slate-800">{task.physical_location ?? 'Not recorded'}</dd>
          </div>
          <div>
            <dt className="text-slate-400">Responsible agency</dt>
            <dd className="font-medium text-slate-800">{task.responsible_agency ?? 'Unrouted'}</dd>
          </div>
          <div>
            <dt className="text-slate-400">Backup agency</dt>
            <dd className="font-medium text-slate-800">{task.backup_agency ?? 'None assigned'}</dd>
          </div>
          <div>
            <dt className="text-slate-400">Primary team / officer</dt>
            <dd className="font-medium text-slate-800">{task.primary_team ?? task.primary_officer ?? 'Not recorded'}</dd>
          </div>
          <div>
            <dt className="text-slate-400">Escalation level</dt>
            <dd className="font-medium text-slate-800">{task.escalation_level > 0 ? task.escalation_level : 'None'}</dd>
          </div>
        </dl>

        {exceptionNote && (
          <div className="rounded-lg bg-status-warning/10 px-2.5 py-2 text-xs text-status-warning">
            <p className="font-semibold uppercase tracking-wide">Exception note</p>
            <p className="mt-0.5 text-slate-700">{exceptionNote}</p>
          </div>
        )}

        <div>
          <p className="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-slate-400">SLA checkpoints</p>
          <ul className="space-y-1 text-xs">
            {SLA_CHECKPOINTS.map((c) => {
              const due = task[c.key] as string | null
              const done = task[c.doneKey] as string | null
              if (!due && !done) return null
              return (
                <li key={c.key} className="flex items-center justify-between gap-2">
                  <span className="text-slate-500">{c.label}</span>
                  <span className={`tabular-nums ${done ? 'text-status-success' : 'text-slate-600'}`}>
                    {done ? `Done ${fmt(done)}` : `Due ${fmt(due)}`}
                  </span>
                </li>
              )
            })}
            {SLA_CHECKPOINTS.every((c) => !task[c.key] && !task[c.doneKey]) && (
              <li className="text-slate-400">No SLA checkpoints set for this dispatch.</li>
            )}
          </ul>
        </div>

        <div>
          <p className="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-slate-400">
            Evidence required{evidence.data ? ` (${evidence.data.length} submitted)` : ''}
          </p>
          {requiredItems.length === 0 ? (
            <p className="text-xs text-slate-400">No evidence checklist attached to this action.</p>
          ) : evidence.loading ? (
            <Skeleton className="h-10 w-full" />
          ) : evidence.error ? (
            <p className="text-xs text-status-critical">{evidence.error}</p>
          ) : (
            <ul className="space-y-1 text-xs">
              {requiredItems.map((item) => {
                const done = submittedTypes.has(item.id)
                return (
                  <li key={item.id} className="flex items-center gap-1.5">
                    {done ? (
                      <CheckCircle2 className="h-3.5 w-3.5 flex-shrink-0 text-status-success" aria-hidden />
                    ) : (
                      <Circle className="h-3.5 w-3.5 flex-shrink-0 text-slate-300" aria-hidden />
                    )}
                    <span className={done ? 'text-slate-600' : 'text-slate-500'}>{item.label}</span>
                  </li>
                )
              })}
            </ul>
          )}
        </div>

        <div>
          <p className="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-slate-400">Activity</p>
          <ul className="space-y-1.5 border-l border-slate-200 pl-3 text-xs">
            {timelineEntries.length === 0 ? (
              <li className="text-slate-400">No activity recorded yet.</li>
            ) : (
              timelineEntries.map((s) => (
                <li key={s.key} className="relative">
                  <span className="absolute -left-[15px] top-1 h-1.5 w-1.5 rounded-full bg-accent-400" aria-hidden />
                  <span className="text-slate-600">{s.label}</span>
                  <span className="ml-1.5 tabular-nums text-slate-400">{fmt(s.ts)}</span>
                </li>
              ))
            )}
          </ul>
        </div>

        <div>
          <p className="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-slate-400">Verification</p>
          {impact.loading ? (
            <Skeleton className="h-12 w-full" />
          ) : impact.error ? (
            <p className="text-xs text-status-critical">{impact.error}</p>
          ) : !impact.data ? (
            <p className="text-xs text-slate-400">Not verified yet - no impact evaluation recorded for this action.</p>
          ) : (
            <div className="rounded-lg bg-slate-50 px-2.5 py-2 text-xs">
              <p className="font-semibold text-slate-800">{INCIDENT_OUTCOME_LABEL[impact.data.outcome] ?? impact.data.outcome}</p>
              {impact.data.pct_change != null && (
                <p className="mt-0.5 text-slate-500">
                  {impact.data.pct_change > 0 ? '+' : ''}
                  {impact.data.pct_change.toFixed(1)}% change · {impact.data.method}
                </p>
              )}
              {impact.data.notes && <p className="mt-1 text-slate-600">{impact.data.notes}</p>}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
