import type { IncidentEventRow } from '../lib/incidents'
import { EmptyState } from './ui'

/**
 * Incident timeline. Shared by the command workspace and the citizen view — the
 * difference between them is which events RLS returns, not how they render, so
 * there is one component rather than a public and a private copy that could
 * drift apart.
 */

const EVENT_STYLE: Record<string, { dot: string; label: string }> = {
  created: { dot: 'bg-status-info', label: 'Detected' },
  evidence_added: { dot: 'bg-brand-500', label: 'Evidence' },
  hypothesis_updated: { dot: 'bg-brand-500', label: 'Assessment' },
  mission_dispatched: { dot: 'bg-status-warning', label: 'Evidence mission' },
  routed: { dot: 'bg-status-warning', label: 'Routed' },
  task_created: { dot: 'bg-status-warning', label: 'Task' },
  action_approved: { dot: 'bg-status-warning', label: 'Approved' },
  action_dispatched: { dot: 'bg-status-warning', label: 'Dispatched' },
  action_completed: { dot: 'bg-status-success', label: 'Action done' },
  impact_evaluated: { dot: 'bg-status-success', label: 'Impact' },
  status_changed: { dot: 'bg-ink-300', label: 'Status' },
  closed: { dot: 'bg-status-success', label: 'Closed' },
  // Phase 9: authority routing and operational dispatch
  routing_decision: { dot: 'bg-status-warning', label: 'Routing' },
  approval: { dot: 'bg-status-warning', label: 'Approved' },
  dispatch: { dot: 'bg-status-warning', label: 'Dispatched' },
  acknowledgement: { dot: 'bg-status-warning', label: 'Acknowledged' },
  acceptance: { dot: 'bg-status-warning', label: 'Accepted' },
  rejection: { dot: 'bg-status-critical', label: 'Rejected' },
  rerouting: { dot: 'bg-status-warning', label: 'Rerouted' },
  escalation: { dot: 'bg-status-critical', label: 'Escalated' },
  completion: { dot: 'bg-status-success', label: 'Completed' },
  cancellation: { dot: 'bg-ink-300', label: 'Cancelled' },
}

function fmt(ts: string): string {
  return new Date(ts).toLocaleString(undefined, {
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export default function IncidentTimeline({
  events,
  emptyMessage = 'Nothing has happened on this incident yet.',
  /** Marks internal-only entries. Command sees these; citizens never receive them. */
  showVisibility = false,
}: {
  events: IncidentEventRow[]
  emptyMessage?: string
  showVisibility?: boolean
}) {
  if (!events.length) return <EmptyState icon="🕓">{emptyMessage}</EmptyState>

  return (
    <ol className="space-y-0">
      {events.map((e, i) => {
        const style = EVENT_STYLE[e.event_type] ?? { dot: 'bg-ink-300', label: e.event_type.replace(/_/g, ' ') }
        const last = i === events.length - 1
        return (
          <li key={e.id} className="relative flex gap-3 pl-1">
            <div className="flex flex-col items-center">
              <span className={`mt-1.5 h-2 w-2 flex-shrink-0 rounded-full ${style.dot}`} aria-hidden />
              {!last && <span className="w-px flex-1 bg-ink-900/10" aria-hidden />}
            </div>
            <div className={`min-w-0 flex-1 ${last ? 'pb-1' : 'pb-4'}`}>
              <div className="flex flex-wrap items-baseline gap-x-2">
                <span className="text-xs font-semibold text-ink-700">{style.label}</span>
                <span className="text-[11px] text-ink-400">{fmt(e.ts)}</span>
                {showVisibility && !e.is_public && (
                  <span
                    className="rounded bg-ink-100 px-1 text-[10px] font-bold uppercase tracking-wide text-ink-500"
                    title="Internal only — not shown to the citizen who reported this"
                  >
                    Internal
                  </span>
                )}
              </div>
              {e.note && <p className="mt-0.5 text-sm text-ink-600">{e.note}</p>}
            </div>
          </li>
        )
      })}
    </ol>
  )
}
