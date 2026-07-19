import { useEffect, useState } from 'react'
import { useAuth } from '../lib/auth'
import {
  NOTIFICATION_CHANNEL_LABEL,
  NOTIFICATION_STATUS_LABEL,
  ROUTING_CONFIDENCE_LABEL,
  TASK_DISPATCH_STATUS_LABEL,
  slaCountdownLabel,
  type RoutingConfidenceLevel,
} from '../lib/incidentRules'
import {
  approveIntervention,
  dispatchInterventionTask,
  escalateStaleTaskDispatchesNow,
  getTaskDispatchForAction,
  listNotificationsForDispatch,
  listResponsibilityRegistryForCity,
  previewTaskRouting,
  resolveJurisdictionDispute,
  transitionTaskDispatch,
  type IncidentDetail,
  type NotificationRow,
  type ResponsibilityRegistryRow,
  type TaskDispatchRow,
  type TaskRoutingPreview,
} from '../lib/incidents'
import { Label, UnavailableBadge } from './ui'

/**
 * Operations panel (Phase 9, plan §10) — routed authority, routing
 * confidence, assigned officer/team, task status, SLA countdown, delivery
 * status, acknowledgement status, escalation level, and reason for
 * rejection/rerouting, per intervention. Command actions: dispatch, approve,
 * reroute-to-backup/other unit, escalate, cancel, resolve a jurisdiction
 * dispute with a reason.
 *
 * The routing/lifecycle/SLA/escalation RULES themselves live entirely in
 * `supabase/migrations/20260724000000_authority_routing_and_dispatch.sql` —
 * this panel reads and requests transitions; it computes nothing.
 */

function RoutingConfidenceBadge({ level }: { level: RoutingConfidenceLevel }) {
  const styles: Record<RoutingConfidenceLevel, string> = {
    confirmed: 'bg-status-success/10 text-status-success',
    probable: 'bg-brand-100 text-brand-700',
    disputed: 'bg-status-warning/10 text-status-warning',
    unresolved: 'bg-status-critical/10 text-status-critical',
  }
  return (
    <span className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${styles[level]}`}>
      {ROUTING_CONFIDENCE_LABEL[level]}
    </span>
  )
}

function DispatchRow({
  actionId,
  actionType,
  cityId,
  incidentId,
  dispatch,
  onRefresh,
}: {
  actionId: number
  actionType: string | null
  cityId: number | null
  incidentId: number
  dispatch: TaskDispatchRow | null | undefined
  onRefresh: () => void
}) {
  const { session } = useAuth()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [preview, setPreview] = useState<TaskRoutingPreview | null>(null)
  const [notifs, setNotifs] = useState<NotificationRow[] | null>(null)
  const [registry, setRegistry] = useState<ResponsibilityRegistryRow[] | null>(null)
  const [showDispute, setShowDispute] = useState(false)

  const act = async (fn: () => Promise<void>) => {
    setBusy(true)
    setError(null)
    try {
      await fn()
      onRefresh()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Action failed.')
    } finally {
      setBusy(false)
    }
  }

  const loadPreview = async () => {
    try {
      setPreview(await previewTaskRouting(actionId))
    } catch {
      /* preview is advisory only - a failed load just leaves the button available */
    }
  }

  const loadNotifs = async () => {
    if (!dispatch) return
    setNotifs(await listNotificationsForDispatch(dispatch.id))
  }

  const loadRegistry = async () => {
    if (cityId == null) return
    setRegistry(await listResponsibilityRegistryForCity(cityId))
  }

  useEffect(() => {
    if (!dispatch) void loadPreview()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dispatch?.id])

  if (!session) return null

  const handleDispatch = () =>
    act(async () => {
      await dispatchInterventionTask(actionId, session.user.id)
    })

  const handleApproveAndDispatch = () =>
    act(async () => {
      await approveIntervention(actionId, incidentId, session.user.id, 'command')
      await dispatchInterventionTask(actionId, session.user.id)
    })

  const handleEscalate = () =>
    act(async () => {
      if (!dispatch) return
      await transitionTaskDispatch(dispatch.id, 'escalated', session.user.id, 'Escalated manually by command.')
    })

  const handleCancel = () =>
    act(async () => {
      if (!dispatch) return
      const reason = window.prompt('Why is this task being cancelled?')
      if (!reason?.trim()) return
      await transitionTaskDispatch(dispatch.id, 'cancelled', session.user.id, reason.trim())
    })

  const handleResolveDispute = (registryId: number) =>
    act(async () => {
      if (!dispatch) return
      const note = window.prompt('Why does this unit have jurisdiction? (shown in the audit trail)')
      if (!note?.trim()) return
      await resolveJurisdictionDispute(dispatch.id, session.user.id, registryId, note.trim())
      setShowDispute(false)
    })

  const showApprovalPath = !dispatch || dispatch.status === 'drafted' || dispatch.status === 'awaiting_approval'
  const disputed = dispatch?.routing_confidence === 'disputed'
  const isTerminal = dispatch != null && ['completed', 'verification_pending', 'cancelled', 'rejected'].includes(dispatch.status)

  return (
    <li className="rounded-lg bg-ink-50/60 p-2.5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm font-semibold capitalize text-ink-800">{actionType?.replace(/_/g, ' ') ?? 'Intervention'}</span>
        <div className="flex items-center gap-1.5">
          <RoutingConfidenceBadge level={dispatch?.routing_confidence ?? preview?.routing_confidence ?? 'unresolved'} />
          <span className="rounded bg-ink-200/60 px-1.5 py-0.5 text-[10px] font-bold uppercase text-ink-700">
            {dispatch ? TASK_DISPATCH_STATUS_LABEL[dispatch.status] : 'Not yet dispatched'}
          </span>
        </div>
      </div>

      <dl className="mt-1.5 grid grid-cols-2 gap-x-3 gap-y-1 text-[11px] sm:grid-cols-4">
        <div>
          <dt className="text-ink-400">Responsible agency</dt>
          <dd className="font-semibold text-ink-700">
            {dispatch?.responsible_agency ?? preview?.responsible_agency ?? '-'}
          </dd>
        </div>
        <div>
          <dt className="text-ink-400">Officer / team</dt>
          <dd className="font-semibold text-ink-700">
            {dispatch?.primary_team ?? preview?.primary_team ?? (dispatch?.primary_officer ? 'Assigned officer' : '-')}
          </dd>
        </div>
        <div>
          <dt className="text-ink-400">SLA</dt>
          <dd className="font-semibold text-ink-700">
            {dispatch && !isTerminal
              ? slaCountdownLabel(
                  dispatch.sla_ack_due_at ?? dispatch.sla_accept_due_at ?? dispatch.sla_arrival_due_at ?? dispatch.sla_completion_due_at,
                )
              : '-'}
          </dd>
        </div>
        <div>
          <dt className="text-ink-400">Escalation level</dt>
          <dd className="font-semibold text-ink-700">{dispatch ? dispatch.escalation_level : '-'}</dd>
        </div>
      </dl>

      {dispatch?.rejection_reason && (
        <p className="mt-1.5 text-[11px] text-status-critical">Rejected: {dispatch.rejection_reason}</p>
      )}
      {dispatch?.reroute_reason && <p className="mt-1.5 text-[11px] text-status-warning">Reroute: {dispatch.reroute_reason}</p>}
      {dispatch?.escalation_reason && (
        <p className="mt-1.5 text-[11px] text-status-warning">Escalation: {dispatch.escalation_reason}</p>
      )}
      {dispatch?.resource_availability === 'unavailable' && (
        <p className="mt-1.5 text-[11px] text-status-warning">
          Resource reported unavailable{dispatch.resource_note ? `: ${dispatch.resource_note}` : '.'}
        </p>
      )}

      {!dispatch && preview?.routing_confidence === 'unresolved' && (
        <div className="mt-1.5 flex items-start gap-2 rounded-lg bg-status-critical/10 px-2.5 py-1.5">
          <UnavailableBadge label="Unresolved routing" />
          <p className="text-[11px] text-ink-600">No matching responsible unit found - this will not dispatch automatically.</p>
        </div>
      )}

      {notifs && (
        <ul className="mt-1.5 space-y-0.5 text-[11px] text-ink-500">
          {notifs.map((n) => (
            <li key={n.id}>
              {NOTIFICATION_CHANNEL_LABEL[n.channel]} - {NOTIFICATION_STATUS_LABEL[n.status]}
              {n.failure_reason ? ` (${n.failure_reason})` : ''}
            </li>
          ))}
          {notifs.length === 0 && <li>No notifications queued yet.</li>}
        </ul>
      )}

      {showDispute && registry && (
        <div className="mt-1.5 rounded-lg border border-ink-200 bg-white p-2">
          <p className="mb-1 text-[11px] font-semibold text-ink-700">Select the correct responsible unit:</p>
          <ul className="space-y-1">
            {registry.map((r) => (
              <li key={r.id}>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => handleResolveDispute(r.id)}
                  className="focus-ring w-full rounded border border-ink-200 px-2 py-1 text-left text-[11px] hover:bg-ink-50 disabled:opacity-50"
                >
                  {r.regulating_authority ?? 'Unnamed unit'} {r.division_zone ? `· ${r.division_zone}` : ''}
                  {r.is_disputed ? ' (also disputed)' : ''}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="mt-2 flex flex-wrap gap-1.5">
        {showApprovalPath && !disputed && (
          <button
            type="button"
            disabled={busy}
            onClick={dispatch?.status === 'awaiting_approval' ? handleApproveAndDispatch : handleDispatch}
            className="focus-ring rounded border border-ink-200 px-2 py-0.5 text-[11px] font-semibold text-ink-700 hover:bg-white disabled:opacity-50"
          >
            {dispatch?.status === 'awaiting_approval' ? 'Approve & dispatch' : 'Preview & dispatch'}
          </button>
        )}
        {disputed && (
          <button
            type="button"
            disabled={busy}
            onClick={() => {
              setShowDispute((v) => !v)
              if (!registry) void loadRegistry()
            }}
            className="focus-ring rounded border border-status-warning/30 px-2 py-0.5 text-[11px] font-semibold text-status-warning hover:bg-status-warning/10 disabled:opacity-50"
          >
            Resolve jurisdiction dispute
          </button>
        )}
        {dispatch && !isTerminal && dispatch.status !== 'escalated' && (
          <button
            type="button"
            disabled={busy}
            onClick={handleEscalate}
            className="focus-ring rounded border border-ink-200 px-2 py-0.5 text-[11px] font-semibold text-ink-700 hover:bg-white disabled:opacity-50"
          >
            Escalate
          </button>
        )}
        {dispatch && !isTerminal && (
          <button
            type="button"
            disabled={busy}
            onClick={handleCancel}
            className="focus-ring rounded border border-status-critical/30 px-2 py-0.5 text-[11px] font-semibold text-status-critical hover:bg-status-critical/10 disabled:opacity-50"
          >
            Cancel
          </button>
        )}
        {dispatch && (
          <button
            type="button"
            onClick={loadNotifs}
            className="focus-ring rounded border border-ink-200 px-2 py-0.5 text-[11px] font-semibold text-ink-700 hover:bg-white"
          >
            {notifs ? 'Refresh delivery status' : 'Show delivery status'}
          </button>
        )}
      </div>

      {error && <p className="mt-1.5 text-[11px] text-status-critical">{error}</p>}
    </li>
  )
}

export default function TaskDispatchPanel({ detail, onRefresh }: { detail: IncidentDetail; onRefresh: () => void }) {
  const { session } = useAuth()
  const { incident, interventions, unavailable } = detail
  const [dispatches, setDispatches] = useState<Record<number, TaskDispatchRow | null>>({})
  const [escalating, setEscalating] = useState(false)

  useEffect(() => {
    let cancelled = false
    void Promise.all(
      interventions.map(async ({ action }) => {
        const d = await getTaskDispatchForAction(action.id).catch(() => null)
        return [action.id, d] as const
      }),
    ).then((pairs) => {
      if (!cancelled) setDispatches(Object.fromEntries(pairs))
    })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [interventions.length, incident.id])

  if (unavailable.includes('Interventions')) return null
  if (interventions.length === 0) return null

  const runEscalation = async () => {
    setEscalating(true)
    try {
      await escalateStaleTaskDispatchesNow()
      onRefresh()
    } finally {
      setEscalating(false)
    }
  }

  return (
    <section className="border-t border-ink-900/5 px-4 py-3">
      <div className="mb-1 flex items-center justify-between gap-2">
        <Label dark>Operations</Label>
        {session && (
          <button
            type="button"
            disabled={escalating}
            onClick={runEscalation}
            className="focus-ring rounded border border-ink-200 px-2 py-0.5 text-[11px] font-semibold text-ink-700 hover:bg-white disabled:opacity-50"
          >
            Check for overdue tasks
          </button>
        )}
      </div>
      <ul className="space-y-2">
        {interventions.map(({ action }) => (
          <DispatchRow
            key={action.id}
            actionId={action.id}
            actionType={action.type}
            cityId={incident.city_id}
            incidentId={incident.id}
            dispatch={dispatches[action.id]}
            onRefresh={() => {
              onRefresh()
              void getTaskDispatchForAction(action.id).then((d) =>
                setDispatches((prev) => ({ ...prev, [action.id]: d })),
              )
            }}
          />
        ))}
      </ul>
    </section>
  )
}
