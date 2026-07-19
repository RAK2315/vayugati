import { useMemo, useState } from 'react'
import { useAuth } from '../lib/auth'
import {
  BEFORE_AFTER_LIMITATION,
  CITIZEN_ACTION_ANSWER_LABEL,
  CONFIDENCE_LABEL,
  IMPACT_OUTCOME_LABEL,
  MIN_COMPLETENESS_FOR_RESULT,
  PLAYBOOK_ACTION_TYPE_LABEL,
  RECOMMENDED_ACTION_SUGGESTIONS,
  WORKFLOW_STATUS_LABEL,
  isOutcomeStatus,
  nextOperationalStatus,
  playbookRequiresApproval,
  previewImpactOutcome,
  rankPlaybooks,
  requiresHumanApproval,
  tallyPlaybookUsage,
  taskBlockedReason,
  type ActionWorkflowStatus,
  type CitizenActionAnswer,
  type PlaybookActionType,
  type PlaybookScore,
  type SourceCategory,
} from '../lib/incidentRules'
import {
  advanceIntervention,
  approveIntervention,
  assignIntervention,
  buildPlaybookRankingContext,
  createIntervention,
  createInterventionFromPlaybook,
  fetchPlaybookUsageBatch,
  listAssignableOfficers,
  listPlaybooksForCity,
  recordImpactEvaluation,
  type AssignableOfficer,
  type IncidentDetail,
  type InterventionWithEvidence,
  type PlaybookRow,
} from '../lib/incidents'
import { useAsync } from '../lib/useAsync'
import { EmptyState, Label } from './ui'

/**
 * Intervention + impact workspace (Phase 4): the approved intervention,
 * responsible authority, action timeline, operational evidence, before/after
 * pollutant readings, citizen verification, and the impact result — plus the
 * reopen/close decision. Sits alongside IncidentEvidencePanel (which covers
 * SOURCE evidence); this covers what was done about it and whether it worked.
 *
 * "Completed" and "effective" are rendered with visibly different chrome
 * throughout this file on purpose — see WORKFLOW_STATUS_LABEL / OUTCOME_STATUSES
 * in incidentRules.ts. An action can sit at "completed" indefinitely with no
 * outcome badge at all; that gap is not a bug, it is the plan's own rule that a
 * completed action is not yet a measured result.
 */

const OP_STYLE: Record<string, string> = {
  drafted: 'bg-ink-100 text-ink-600',
  awaiting_approval: 'bg-amber-100 text-amber-800',
  assigned: 'bg-sky-100 text-sky-800',
  accepted: 'bg-sky-100 text-sky-800',
  in_progress: 'bg-sky-100 text-sky-800',
  completed: 'bg-ink-200 text-ink-700',
  verification_pending: 'bg-amber-100 text-amber-800',
  reopened: 'bg-red-100 text-red-700',
}

const OUTCOME_STYLE: Record<string, string> = {
  effective: 'bg-green-100 text-green-800',
  partly_effective: 'bg-lime-100 text-lime-800',
  ineffective: 'bg-red-100 text-red-700',
  inconclusive: 'bg-ink-100 text-ink-600',
}

function StatusBadge({ status }: { status: ActionWorkflowStatus }) {
  const cls = isOutcomeStatus(status) ? (OUTCOME_STYLE[status] ?? 'bg-ink-100') : (OP_STYLE[status] ?? 'bg-ink-100')
  return (
    <span className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${cls}`}>
      {WORKFLOW_STATUS_LABEL[status]}
    </span>
  )
}

function Section({ title, count, children }: { title: string; count?: number; children: React.ReactNode }) {
  return (
    <section className="border-t border-ink-900/5 px-4 py-3 first:border-t-0">
      <div className="mb-2 flex items-center gap-2">
        <Label dark>{title}</Label>
        {count != null && <span className="rounded bg-ink-100 px-1.5 text-[10px] font-bold text-ink-600">{count}</span>}
      </div>
      {children}
    </section>
  )
}

// ── playbook picker (Phase 5) ────────────────────────────────────────────────

const EVIDENCE_BASIS_LABEL: Record<string, string> = {
  literature: 'Literature-based estimate',
  expert_estimate: 'Expert estimate - not yet locally validated',
  vayu_gati_observation: "Based on this city's own observed results",
}

/** One ranked playbook, in the picker's list step. */
function PlaybookListItem({
  candidate,
  usage,
  onSelect,
}: {
  candidate: PlaybookScore
  usage: ReturnType<typeof tallyPlaybookUsage>
  onSelect: () => void
}) {
  const p = candidate.playbook
  const costLabel =
    p.estimated_cost_min != null || p.estimated_cost_max != null
      ? `₹${(p.estimated_cost_min ?? 0).toLocaleString()}–${(p.estimated_cost_max ?? p.estimated_cost_min ?? 0).toLocaleString()}`
      : 'Cost unknown'
  const deployLabel = p.estimated_minutes != null ? `${Math.round(p.estimated_minutes / 60)}h deploy` : null
  const effectLabel = p.expected_time_to_effect_hours != null ? `~${p.expected_time_to_effect_hours}h to effect` : null

  return (
    <li className="rounded-xl border border-ink-900/10 p-3">
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="text-sm font-semibold text-ink-900">{p.title}</span>
        <span className="rounded bg-ink-100 px-1.5 py-0.5 text-[10px] font-bold uppercase text-ink-600">
          {PLAYBOOK_ACTION_TYPE_LABEL[p.action_type as PlaybookActionType] ?? p.action_type}
        </span>
        <span className="rounded bg-sky-100 px-1.5 py-0.5 text-[10px] font-bold uppercase text-sky-800">
          Needs {CONFIDENCE_LABEL[p.min_evidence_level].toLowerCase()}
        </span>
      </div>
      <p className="mt-1 flex flex-wrap gap-x-3 text-[11px] text-ink-500">
        <span>{costLabel}</span>
        {deployLabel && <span>{deployLabel}</span>}
        {effectLabel && <span>{effectLabel}</span>}
        <span>{usage.timesUsed === 0 ? 'Not used yet' : `Used ${usage.timesUsed}×`}</span>
      </p>
      {usage.timesUsed > 0 && (
        <p className="mt-0.5 text-[11px] text-ink-400">
          {usage.effective} effective · {usage.partlyEffective} partly · {usage.ineffective} ineffective ·{' '}
          {usage.inconclusive} inconclusive
          {usage.pending > 0 && ` · ${usage.pending} still in progress`}
        </p>
      )}
      <ul className="mt-1.5 space-y-0.5">
        {candidate.reasons.map((r, i) => (
          <li key={i} className="text-[11px] text-ink-600">
            · {r}
          </li>
        ))}
      </ul>
      <button
        type="button"
        onClick={onSelect}
        className="focus-ring mt-2 rounded-lg bg-brand-700 px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-brand-800"
      >
        Use this playbook
      </button>
    </li>
  )
}

function PlaybookPickerDialog({
  incident,
  wardId,
  leadingCategory,
  onClose,
  onCreated,
  onUseCustom,
}: {
  incident: IncidentDetail['incident']
  wardId: number | null
  leadingCategory: SourceCategory | null
  onClose: () => void
  onCreated: () => void
  onUseCustom: () => void
}) {
  const { session } = useAuth()
  const [selected, setSelected] = useState<PlaybookRow | null>(null)
  const [notesOverride, setNotesOverride] = useState('')
  const [responsibleAgency, setResponsibleAgency] = useState('')
  const [deadlineDays, setDeadlineDays] = useState(3)
  const [verificationHours, setVerificationHours] = useState(72)
  const [assignee, setAssignee] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const playbooks = useAsync(() => listPlaybooksForCity(incident.city_id), [incident.city_id])
  const officers = useAsync(() => listAssignableOfficers(wardId), [wardId])
  const officerList: AssignableOfficer[] = officers.data ?? []

  // `rankPlaybooks` operates on the narrow `PlaybookLike` shape (see its own
  // doc comment), so `ranked[].playbook` is statically typed to that subset —
  // even though at runtime it's the same full row. Resolving a selection back
  // to the FULL row (needed for `instructions`/`checklist`/etc. in step 2)
  // goes through this id lookup rather than casting, so the type system keeps
  // catching a real field going missing.
  const playbookById = useMemo(() => new Map((playbooks.data ?? []).map((p) => [p.id, p])), [playbooks.data])

  const ranked = useMemo(() => {
    if (!playbooks.data) return []
    const ctx = buildPlaybookRankingContext(incident, leadingCategory, officers.data ? officers.data.length : undefined)
    return rankPlaybooks(playbooks.data, ctx)
  }, [playbooks.data, incident, leadingCategory, officers.data])

  const usageBatch = useAsync(
    () => fetchPlaybookUsageBatch(ranked.map((r) => r.playbook.id)),
    [ranked.map((r) => r.playbook.id).join(',')],
    { enabled: ranked.length > 0 },
  )

  const selectPlaybook = (p: PlaybookRow) => {
    setSelected(p)
    setResponsibleAgency(p.responsible_agency_type ?? '')
    setVerificationHours(p.verification_window_hours ?? 72)
  }

  const needsApproval = selected ? playbookRequiresApproval(selected) : false

  const create = async () => {
    if (!session || wardId == null || !selected) return
    setBusy(true)
    setError(null)
    try {
      await createInterventionFromPlaybook({
        incidentId: incident.id,
        wardId,
        playbookId: selected.id,
        notesOverride: notesOverride || null,
        responsibleAgencyOverride: responsibleAgency || null,
        expectedVerificationHoursOverride: verificationHours,
        deadline: new Date(Date.now() + deadlineDays * 86_400_000).toISOString(),
        assignedTo: needsApproval ? null : assignee || null,
      })
      onCreated()
      onClose()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not create the intervention.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="z-modal fixed inset-0 flex items-end justify-center bg-ink-900/40 p-3 sm:items-center">
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Choose an intervention playbook"
        className="max-h-[85vh] w-full max-w-lg overflow-y-auto rounded-2xl bg-white p-4 shadow-card-lg"
      >
        {!selected ? (
          <>
            <h2 className="text-sm font-semibold text-ink-900">Choose an intervention</h2>
            <p className="mt-0.5 text-xs text-ink-400">
              Ranked by source match, evidence level, urgency, cost and deployment time - a stated rule, not a model.
            </p>

            {playbooks.loading || officers.loading ? (
              <p className="mt-3 text-xs text-ink-400">Loading playbooks…</p>
            ) : playbooks.error ? (
              <p className="mt-3 text-xs text-status-critical">{playbooks.error}</p>
            ) : ranked.length === 0 ? (
              <EmptyState icon="📋">
                No playbook matches this incident's current evidence level and source yet. You can still create a
                custom intervention below.
              </EmptyState>
            ) : (
              <ul className="mt-3 space-y-2">
                {ranked.map((r) => (
                  <PlaybookListItem
                    key={r.playbook.id}
                    candidate={r}
                    usage={tallyPlaybookUsage(usageBatch.data?.get(r.playbook.id) ?? [])}
                    onSelect={() => {
                      const full = playbookById.get(r.playbook.id)
                      if (full) selectPlaybook(full)
                    }}
                  />
                ))}
              </ul>
            )}

            <div className="mt-4 flex items-center justify-between border-t border-ink-900/5 pt-3">
              <button
                type="button"
                onClick={onUseCustom}
                className="focus-ring text-xs font-semibold text-brand-700 hover:underline"
              >
                Use a custom intervention instead
              </button>
              <button
                type="button"
                onClick={onClose}
                className="focus-ring rounded-lg border border-ink-200 px-3 py-1.5 text-xs font-semibold text-ink-700 hover:bg-ink-50"
              >
                Cancel
              </button>
            </div>
          </>
        ) : (
          <>
            <button
              type="button"
              onClick={() => setSelected(null)}
              className="focus-ring text-xs font-semibold text-brand-700 hover:underline"
            >
              ← Back to playbooks
            </button>
            <h2 className="mt-2 text-sm font-semibold text-ink-900">{selected.title}</h2>
            {selected.instructions && <p className="mt-1 text-xs text-ink-600">{selected.instructions}</p>}

            <div className="mt-2 rounded-lg bg-ink-50 px-3 py-2">
              <p className="text-[11px] font-semibold uppercase tracking-wide text-ink-500">Expected effect</p>
              <p className="mt-0.5 text-xs text-ink-700">{selected.expected_effect ?? 'Not documented.'}</p>
              <p className="mt-1 text-[11px] font-semibold text-ink-500">
                {EVIDENCE_BASIS_LABEL[selected.evidence_basis ?? ''] ?? 'Basis not recorded'} - not a guarantee.
              </p>
              {selected.known_limitations && (
                <p className="mt-1 text-[11px] text-ink-500">Known limitations: {selected.known_limitations}</p>
              )}
            </div>

            {needsApproval && (
              <p className="mt-2 text-[11px] text-status-warning">
                This is an enforcement action: it needs command approval before it can be assigned.
              </p>
            )}

            <label className="mt-3 block text-xs font-semibold text-ink-700">
              Operational notes <span className="font-normal text-ink-400">(the only thing you can edit here - the playbook itself stays unchanged)</span>
            </label>
            <textarea
              rows={2}
              value={notesOverride}
              onChange={(e) => setNotesOverride(e.target.value)}
              placeholder="Anything specific to this incident the field officer should know"
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-xs"
            />

            <label className="mt-3 block text-xs font-semibold text-ink-700">Responsible authority</label>
            <input
              value={responsibleAgency}
              onChange={(e) => setResponsibleAgency(e.target.value)}
              placeholder="e.g. MCD Zone 3"
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
            />

            <div className="mt-3 grid grid-cols-2 gap-2">
              <div>
                <label className="block text-xs font-semibold text-ink-700">Deadline (days)</label>
                <input
                  type="number"
                  min={1}
                  value={deadlineDays}
                  onChange={(e) => setDeadlineDays(Math.max(1, Number(e.target.value) || 1))}
                  className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
                />
              </div>
              <div>
                <label className="block text-xs font-semibold text-ink-700">Verify within (hours)</label>
                <input
                  type="number"
                  min={1}
                  value={verificationHours}
                  onChange={(e) => setVerificationHours(Math.max(1, Number(e.target.value) || 1))}
                  className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
                />
              </div>
            </div>

            {!needsApproval && (
              <>
                <label className="mt-3 block text-xs font-semibold text-ink-700">Assign to (optional now)</label>
                {officerList.length === 0 ? (
                  <p className="mt-1 rounded-lg bg-status-warning/10 px-2.5 py-2 text-xs text-ink-600">
                    No field officer covers this ward yet - you can save this as drafted and assign later.
                  </p>
                ) : (
                  <select
                    value={assignee}
                    onChange={(e) => setAssignee(e.target.value)}
                    className="focus-ring mt-1 w-full rounded-lg border border-ink-200 bg-white px-2.5 py-2 text-sm"
                  >
                    <option value="">Leave unassigned for now</option>
                    {officerList.map((o) => (
                      <option key={o.id} value={o.id}>
                        {o.full_name ?? o.id.slice(0, 8)}
                      </option>
                    ))}
                  </select>
                )}
              </>
            )}

            {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}

            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={onClose}
                className="focus-ring rounded-lg border border-ink-200 px-3 py-1.5 text-xs font-semibold text-ink-700 hover:bg-ink-50"
              >
                Cancel
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={create}
                className="focus-ring rounded-lg bg-brand-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-800 disabled:opacity-50"
              >
                {busy ? 'Creating…' : 'Create intervention'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

// ── create intervention ───────────────────────────────────────────────────────

function CreateInterventionDialog({
  incidentId,
  wardId,
  onClose,
  onCreated,
}: {
  incidentId: number
  wardId: number | null
  onClose: () => void
  onCreated: () => void
}) {
  const { session } = useAuth()
  const [type, setType] = useState('inspect')
  const [recommendedAction, setRecommendedAction] = useState(RECOMMENDED_ACTION_SUGGESTIONS.other)
  const [responsibleAgency, setResponsibleAgency] = useState('')
  const [customReason, setCustomReason] = useState('')
  const [deadlineDays, setDeadlineDays] = useState(3)
  const [verificationHours, setVerificationHours] = useState(72)
  const [assignee, setAssignee] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const officers = useAsync(() => listAssignableOfficers(wardId), [wardId])
  const officerList: AssignableOfficer[] = officers.data ?? []
  const needsApproval = requiresHumanApproval(type)

  const create = async () => {
    if (!session || wardId == null) return
    setBusy(true)
    setError(null)
    try {
      await createIntervention({
        incidentId,
        wardId,
        type,
        recommendedAction,
        responsibleAgency,
        customReason,
        deadline: new Date(Date.now() + deadlineDays * 86_400_000).toISOString(),
        expectedVerificationHours: verificationHours,
        assignedTo: needsApproval ? null : assignee || null,
      })
      onCreated()
      onClose()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not create the intervention.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="z-modal fixed inset-0 flex items-end justify-center bg-ink-900/40 p-3 sm:items-center">
      <div role="dialog" aria-modal="true" aria-label="Create intervention" className="w-full max-w-md rounded-2xl bg-white p-4 shadow-card-lg">
        <h2 className="text-sm font-semibold text-ink-900">Create an intervention</h2>
        <p className="mt-0.5 text-xs text-ink-400">Only offered when the incident's evidence level allows it.</p>

        <label className="mt-3 block text-xs font-semibold text-ink-700">Action type</label>
        <select
          value={type}
          onChange={(e) => setType(e.target.value)}
          className="focus-ring mt-1 w-full rounded-lg border border-ink-200 bg-white px-2.5 py-2 text-sm"
        >
          <option value="inspect">Inspection</option>
          <option value="sprinkle">Preventive - water sprinkling</option>
          <option value="notice">Preventive - notice</option>
          <option value="penalty">Enforcement - penalty</option>
          <option value="stop_work">Enforcement - stop-work order</option>
        </select>
        {needsApproval && (
          <p className="mt-1 text-[11px] text-status-warning">
            This is an enforcement action: it needs command approval before it can be assigned.
          </p>
        )}

        <label className="mt-3 block text-xs font-semibold text-ink-700">Recommended action</label>
        <textarea
          rows={2}
          value={recommendedAction}
          onChange={(e) => setRecommendedAction(e.target.value)}
          className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-xs"
        />

        <label className="mt-3 block text-xs font-semibold text-ink-700">Responsible authority</label>
        <input
          value={responsibleAgency}
          onChange={(e) => setResponsibleAgency(e.target.value)}
          placeholder="e.g. MCD Zone 3"
          className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
        />

        <label className="mt-3 block text-xs font-semibold text-ink-700">Why no playbook was suitable</label>
        <p className="mt-0.5 text-[11px] text-ink-400">
          This is a custom intervention, not a structured playbook. Required - recorded on the audit trail.
        </p>
        <textarea
          rows={2}
          value={customReason}
          onChange={(e) => setCustomReason(e.target.value)}
          placeholder="e.g. No playbook covers this source category yet"
          className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-xs"
        />

        <div className="mt-3 grid grid-cols-2 gap-2">
          <div>
            <label className="block text-xs font-semibold text-ink-700">Deadline (days)</label>
            <input
              type="number"
              min={1}
              value={deadlineDays}
              onChange={(e) => setDeadlineDays(Math.max(1, Number(e.target.value) || 1))}
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs font-semibold text-ink-700">Verify within (hours)</label>
            <input
              type="number"
              min={1}
              value={verificationHours}
              onChange={(e) => setVerificationHours(Math.max(1, Number(e.target.value) || 1))}
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
            />
          </div>
        </div>

        {!needsApproval && (
          <>
            <label className="mt-3 block text-xs font-semibold text-ink-700">Assign to (optional now)</label>
            {officers.loading ? (
              <p className="mt-1 text-xs text-ink-400">Loading officers…</p>
            ) : officerList.length === 0 ? (
              <p className="mt-1 rounded-lg bg-status-warning/10 px-2.5 py-2 text-xs text-ink-600">
                No field officer covers this ward yet - you can save this as drafted and assign later.
              </p>
            ) : (
              <select
                value={assignee}
                onChange={(e) => setAssignee(e.target.value)}
                className="focus-ring mt-1 w-full rounded-lg border border-ink-200 bg-white px-2.5 py-2 text-sm"
              >
                <option value="">Leave unassigned for now</option>
                {officerList.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.full_name ?? o.id.slice(0, 8)}
                  </option>
                ))}
              </select>
            )}
          </>
        )}

        {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}

        <div className="mt-4 flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="focus-ring rounded-lg border border-ink-200 px-3 py-1.5 text-xs font-semibold text-ink-700 hover:bg-ink-50"
          >
            Cancel
          </button>
          <button
            type="button"
            disabled={busy || !recommendedAction.trim() || !responsibleAgency.trim() || !customReason.trim()}
            onClick={create}
            className="focus-ring rounded-lg bg-brand-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-800 disabled:opacity-50"
          >
            {busy ? 'Creating…' : 'Create intervention'}
          </button>
        </div>
      </div>
    </div>
  )
}

// ── record impact evaluation ────────────────────────────────────────────────

function RecordImpactDialog({
  incidentId,
  actionId,
  onClose,
  onRecorded,
}: {
  incidentId: number
  actionId: number
  onClose: () => void
  onRecorded: () => void
}) {
  const [before, setBefore] = useState<string>('')
  const [after, setAfter] = useState<string>('')
  const [windowHours, setWindowHours] = useState(48)
  const [station, setStation] = useState('')
  const [completeness, setCompleteness] = useState(1)
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const beforeNum = before === '' ? null : Number(before)
  const afterNum = after === '' ? null : Number(after)
  const preview = previewImpactOutcome({ before: beforeNum, after: afterNum, completeness })

  const submit = async () => {
    setBusy(true)
    setError(null)
    try {
      await recordImpactEvaluation({
        incidentId,
        actionId,
        before: beforeNum,
        after: afterNum,
        observationWindowHours: windowHours,
        stationLabel: station || 'Not specified',
        dataCompleteness: completeness,
        notes: notes || null,
      })
      onRecorded()
      onClose()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not record the impact evaluation.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="z-modal fixed inset-0 flex items-end justify-center bg-ink-900/40 p-3 sm:items-center">
      <div role="dialog" aria-modal="true" aria-label="Record impact evaluation" className="w-full max-w-md rounded-2xl bg-white p-4 shadow-card-lg">
        <h2 className="text-sm font-semibold text-ink-900">Record before/after impact</h2>
        <p className="mt-0.5 text-xs text-ink-400">{BEFORE_AFTER_LIMITATION}</p>

        <div className="mt-3 grid grid-cols-2 gap-2">
          <div>
            <label className="block text-xs font-semibold text-ink-700">Before (PM2.5 µg/m³)</label>
            <input
              type="number"
              value={before}
              onChange={(e) => setBefore(e.target.value)}
              placeholder="Leave blank if unknown"
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs font-semibold text-ink-700">After (PM2.5 µg/m³)</label>
            <input
              type="number"
              value={after}
              onChange={(e) => setAfter(e.target.value)}
              placeholder="Leave blank if unknown"
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
            />
          </div>
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2">
          <div>
            <label className="block text-xs font-semibold text-ink-700">Observation window (h)</label>
            <input
              type="number"
              min={1}
              value={windowHours}
              onChange={(e) => setWindowHours(Math.max(1, Number(e.target.value) || 1))}
              className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs font-semibold text-ink-700">
              Data completeness ({Math.round(completeness * 100)}%)
            </label>
            <input
              type="range"
              min={0}
              max={1}
              step={0.05}
              value={completeness}
              onChange={(e) => setCompleteness(Number(e.target.value))}
              className="mt-2.5 w-full"
            />
          </div>
        </div>

        <label className="mt-3 block text-xs font-semibold text-ink-700">Station / sensor used</label>
        <input
          value={station}
          onChange={(e) => setStation(e.target.value)}
          placeholder="e.g. CPCB Anand Vihar"
          className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-sm"
        />

        <label className="mt-3 block text-xs font-semibold text-ink-700">Notes (optional)</label>
        <textarea
          rows={2}
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-xs"
        />

        {/* Preview only - the database computes the real outcome from the same
            rule. Shown so the operator isn't surprised, never as the source of
            truth (see recordImpactEvaluation's docstring). */}
        <div className="mt-3 rounded-lg bg-ink-50 px-3 py-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-ink-500">Expected result</p>
          <p className="mt-0.5 text-sm font-semibold text-ink-800">
            {IMPACT_OUTCOME_LABEL[preview.outcome]}
            {preview.pctChange != null && (
              <span className="ml-1 font-normal text-ink-500">({preview.pctChange.toFixed(0)}% change)</span>
            )}
          </p>
          {completeness < MIN_COMPLETENESS_FOR_RESULT && (
            <p className="mt-0.5 text-[11px] text-ink-500">
              Below {Math.round(MIN_COMPLETENESS_FOR_RESULT * 100)}% completeness always reads inconclusive, regardless
              of the readings.
            </p>
          )}
        </div>

        {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}

        <div className="mt-4 flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="focus-ring rounded-lg border border-ink-200 px-3 py-1.5 text-xs font-semibold text-ink-700 hover:bg-ink-50"
          >
            Cancel
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={submit}
            className="focus-ring rounded-lg bg-brand-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-brand-800 disabled:opacity-50"
          >
            {busy ? 'Recording…' : 'Record evaluation'}
          </button>
        </div>
      </div>
    </div>
  )
}

// ── one intervention card ───────────────────────────────────────────────────

function InterventionCard({
  item,
  incidentId,
  wardId,
  onRefresh,
}: {
  item: InterventionWithEvidence
  incidentId: number
  wardId: number | null
  onRefresh: () => void
}) {
  const { session } = useAuth()
  const { action, evidence } = item
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [assignPicker, setAssignPicker] = useState(false)
  const [assignee, setAssignee] = useState('')
  const [impactOpen, setImpactOpen] = useState(false)

  const officers = useAsync(() => listAssignableOfficers(wardId), [wardId], { enabled: assignPicker })
  const officerList: AssignableOfficer[] = officers.data ?? []

  const needsApproval = requiresHumanApproval(action.type ?? '')
  const isApproved = action.approved_by != null
  const next = nextOperationalStatus(action.workflow_status)
  const canEvaluate = action.workflow_status === 'completed' || action.workflow_status === 'verification_pending'

  const act = async (fn: () => Promise<void>) => {
    if (!session) return
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

  const approve = () => {
    if (!session) return
    void act(() => approveIntervention(action.id, incidentId, session.user.id, 'command'))
  }

  const assign = () => {
    if (!session || !assignee) return
    void act(() => assignIntervention(action.id, incidentId, assignee, session.user.id))
    setAssignPicker(false)
  }

  const advance = () => {
    if (!session || !next) return
    const field = next === 'accepted' ? 'accepted_at' : next === 'in_progress' ? 'started_at' : next === 'completed' ? 'completed_at' : undefined
    void act(() => advanceIntervention(action.id, incidentId, next, session.user.id, field))
  }

  return (
    <li className="rounded-xl border border-ink-900/10 bg-white p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-semibold capitalize text-ink-800">{action.type ?? 'intervention'}</span>
        <StatusBadge status={action.workflow_status} />
        {action.playbook_id == null && (
          <span className="rounded bg-ink-100 px-1.5 py-0.5 text-[10px] font-bold uppercase text-ink-500">Custom intervention</span>
        )}
        {needsApproval && (
          <span
            className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${isApproved ? 'bg-green-100 text-green-800' : 'bg-status-warning/20 text-status-warning'}`}
          >
            {isApproved ? 'Approved' : 'Needs approval'}
          </span>
        )}
      </div>

      {action.recommended_action && <p className="mt-1.5 text-sm text-ink-700">{action.recommended_action}</p>}
      {action.playbook_id != null && (
        <p className="mt-1 text-[11px] text-ink-400">
          From playbook #{action.playbook_id}
          {action.playbook_version != null && ` (v${action.playbook_version} at selection)`}
        </p>
      )}
      {action.playbook_notes_override && (
        <p className="mt-1 rounded-lg bg-brand-50 px-2.5 py-1.5 text-xs italic text-brand-800">
          {action.playbook_notes_override}
        </p>
      )}
      {action.playbook_id == null && action.custom_reason && (
        <p className="mt-1 text-[11px] text-ink-500">
          <span className="font-semibold text-ink-600">Why no playbook: </span>
          {action.custom_reason}
        </p>
      )}

      <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-[11px] sm:grid-cols-4">
        <div>
          <dt className="text-ink-400">Responsible authority</dt>
          <dd className="font-semibold text-ink-700">{action.responsible_agency ?? '-'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Deadline</dt>
          <dd className="font-semibold text-ink-700">{action.deadline ? new Date(action.deadline).toLocaleDateString() : '-'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Assignee</dt>
          <dd className="font-semibold text-ink-700">{action.assigned_to ? action.assigned_to.slice(0, 8) : 'Unassigned'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Expected verification</dt>
          <dd className="font-semibold text-ink-700">
            {action.expected_verification_hours ? `within ${action.expected_verification_hours}h` : '-'}
          </dd>
        </div>
      </dl>

      {isApproved && (
        <p className="mt-1.5 text-[11px] text-ink-500">
          Approved by {action.approved_by?.slice(0, 8)} ({action.approval_level ?? 'command'}) ·{' '}
          {action.approved_at && new Date(action.approved_at).toLocaleString()}
        </p>
      )}
      {action.not_completed_reason && (
        <p className="mt-1.5 rounded-lg bg-status-critical/10 px-2.5 py-1.5 text-xs text-status-critical">
          Not completed: {action.not_completed_reason}
        </p>
      )}
      {action.source_confirmed != null && (
        <p className="mt-1.5 text-[11px] text-ink-500">
          Field officer {action.source_confirmed ? 'confirmed' : 'did not confirm'} the source on site.
        </p>
      )}

      {/* ── operational evidence ── */}
      {evidence.length > 0 && (
        <div className="mt-2 border-t border-ink-900/5 pt-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-ink-400">Operational evidence</p>
          <ul className="mt-1 space-y-1">
            {evidence.map((e) => (
              <li key={e.id} className="flex flex-wrap items-center gap-2 text-[11px] text-ink-600">
                <span className="rounded bg-ink-100 px-1.5 py-0.5 font-semibold uppercase text-ink-600">
                  {e.evidence_type.replace(/_/g, ' ')}
                </span>
                <span className="text-ink-400">{new Date(e.captured_at).toLocaleString()}</span>
                {e.photo_url && (
                  <a href={e.photo_url} target="_blank" rel="noreferrer" className="font-semibold text-brand-700 hover:underline">
                    View photo →
                  </a>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* ── controls ── */}
      <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-ink-900/5 pt-2.5">
        {needsApproval && !isApproved && (
          <button
            type="button"
            disabled={busy}
            onClick={approve}
            className="focus-ring rounded-lg bg-brand-700 px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-brand-800 disabled:opacity-50"
          >
            Approve
          </button>
        )}
        {!action.assigned_to && (!needsApproval || isApproved) && (
          assignPicker ? (
            <span className="flex items-center gap-1">
              <select
                value={assignee}
                onChange={(e) => setAssignee(e.target.value)}
                className="focus-ring rounded-lg border border-ink-200 px-2 py-1 text-[11px]"
              >
                <option value="">{officers.loading ? 'Loading…' : 'Select officer…'}</option>
                {officerList.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.full_name ?? o.id.slice(0, 8)}
                  </option>
                ))}
              </select>
              <button
                type="button"
                disabled={!assignee || busy}
                onClick={assign}
                className="focus-ring rounded-lg bg-brand-700 px-2 py-1 text-[11px] font-semibold text-white disabled:opacity-50"
              >
                Assign
              </button>
            </span>
          ) : (
            <button
              type="button"
              onClick={() => setAssignPicker(true)}
              className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50"
            >
              Assign officer
            </button>
          )
        )}
        {next && (
          <button
            type="button"
            disabled={busy}
            onClick={advance}
            className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50"
          >
            Mark {WORKFLOW_STATUS_LABEL[next].toLowerCase()}
          </button>
        )}
        {canEvaluate && (
          <button
            type="button"
            onClick={() => setImpactOpen(true)}
            className="focus-ring rounded-lg bg-status-info/10 px-2.5 py-1 text-[11px] font-semibold text-status-info hover:bg-status-info/20"
          >
            Record impact evaluation
          </button>
        )}
      </div>
      {error && <p className="mt-1.5 text-[11px] text-status-critical">{error}</p>}

      {impactOpen && (
        <RecordImpactDialog
          incidentId={incidentId}
          actionId={action.id}
          onClose={() => setImpactOpen(false)}
          onRecorded={onRefresh}
        />
      )}
    </li>
  )
}

// ── panel ────────────────────────────────────────────────────────────────────

export default function InterventionPanel({ detail, onRefresh }: { detail: IncidentDetail; onRefresh: () => void }) {
  const { incident, interventions, impactEvaluations, evidence, hypotheses } = detail
  // `pickerOpen` is the default entry point (plan §7: replace free-text
  // creation with playbooks); `customOpen` is the explicit fallback reached
  // via the picker's "Use a custom intervention instead" link, for a source/
  // city with no matching playbook yet.
  const [pickerOpen, setPickerOpen] = useState(false)
  const [customOpen, setCustomOpen] = useState(false)
  // Highest-probability hypothesis, already sorted by listSourceHypotheses —
  // the same signal the field checklist and citizen safety gate use elsewhere.
  const leadingCategory = hypotheses[0]?.source_category ?? null

  const blocked = taskBlockedReason(incident.source_confidence, 'inspection')
  // Citizen action-verification answers arrive as incident_evidence rows with
  // this payload key (see submit_citizen_action_verification). Filtered here
  // rather than fetched separately — they are already loaded as part of the
  // regular evidence list.
  const citizenAnswers = evidence.filter(
    (e) => e.payload && typeof e.payload === 'object' && !Array.isArray(e.payload) && 'citizen_action_answer' in e.payload,
  )

  return (
    <div className="divide-y divide-ink-900/5">
      {/* ── intervention(s) ── */}
      <Section title="Intervention" count={interventions.length}>
        {interventions.length === 0 ? (
          blocked ? (
            <EmptyState icon="🔒">{blocked}</EmptyState>
          ) : (
            <EmptyState icon="🛠️">No intervention created yet.</EmptyState>
          )
        ) : (
          <ul className="space-y-2">
            {interventions.map((item) => (
              <InterventionCard
                key={item.action.id}
                item={item}
                incidentId={incident.id}
                wardId={incident.ward_id}
                onRefresh={onRefresh}
              />
            ))}
          </ul>
        )}
        <button
          type="button"
          disabled={!!blocked}
          title={blocked ?? undefined}
          onClick={() => setPickerOpen(true)}
          className="focus-ring mt-2 rounded-lg border border-ink-200 px-2.5 py-1.5 text-xs font-semibold text-ink-700 transition hover:bg-ink-50 disabled:cursor-not-allowed disabled:opacity-50"
        >
          + New intervention
        </button>
      </Section>

      {/* ── before/after impact result ── */}
      <Section title="Impact result" count={impactEvaluations.length}>
        {impactEvaluations.length === 0 ? (
          <EmptyState icon="📊">
            No impact evaluation recorded yet - completing an action does not by itself mean pollution was reduced.
          </EmptyState>
        ) : (
          <ul className="space-y-2">
            {impactEvaluations.map((e) => (
              <li key={e.id} className="rounded-lg bg-ink-50/60 p-2.5">
                <div className="flex flex-wrap items-center gap-2">
                  <span className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${OUTCOME_STYLE[e.outcome] ?? 'bg-ink-100'}`}>
                    {IMPACT_OUTCOME_LABEL[e.outcome as keyof typeof IMPACT_OUTCOME_LABEL] ?? e.outcome}
                  </span>
                  <span className="text-[11px] text-ink-400">{new Date(e.evaluated_at).toLocaleString()}</span>
                </div>
                <dl className="mt-1.5 grid grid-cols-2 gap-x-3 gap-y-0.5 text-[11px] sm:grid-cols-4">
                  <div>
                    <dt className="text-ink-400">Before</dt>
                    <dd className="font-semibold text-ink-700">{e.before_value ?? '-'}</dd>
                  </div>
                  <div>
                    <dt className="text-ink-400">After</dt>
                    <dd className="font-semibold text-ink-700">{e.after_value ?? '-'}</dd>
                  </div>
                  <div>
                    <dt className="text-ink-400">Change</dt>
                    <dd className="font-semibold text-ink-700">{e.pct_change != null ? `${e.pct_change.toFixed(0)}%` : '-'}</dd>
                  </div>
                  <div>
                    <dt className="text-ink-400">Data completeness</dt>
                    <dd className="font-semibold text-ink-700">
                      {e.data_completeness != null ? `${Math.round(e.data_completeness * 100)}%` : '-'}
                    </dd>
                  </div>
                </dl>
                {e.station_label && <p className="mt-1 text-[11px] text-ink-500">Station: {e.station_label}</p>}
                {e.method_limitation && <p className="mt-1 text-[11px] italic text-ink-400">{e.method_limitation}</p>}
                {e.notes && <p className="mt-1 text-[11px] text-ink-500">{e.notes}</p>}
              </li>
            ))}
          </ul>
        )}
      </Section>

      {/* ── citizen verification ── */}
      <Section title="Citizen verification" count={citizenAnswers.length}>
        {citizenAnswers.length === 0 ? (
          <p className="text-xs text-ink-500">No citizen has reported on the action outcome yet.</p>
        ) : (
          <ul className="space-y-1.5">
            {citizenAnswers.map((e) => {
              const answer = (e.payload as Record<string, unknown>).citizen_action_answer as CitizenActionAnswer
              return (
                <li key={e.id} className="flex items-center gap-2 text-xs text-ink-700">
                  <span aria-hidden>👤</span>
                  <span>{CITIZEN_ACTION_ANSWER_LABEL[answer] ?? answer}</span>
                  <span className="text-ink-400">{new Date(e.collected_at).toLocaleDateString()}</span>
                </li>
              )
            })}
          </ul>
        )}
        <p className="mt-2 text-[11px] text-ink-400">
          A citizen's confirmation supports the result but does not independently prove pollution reduction.
        </p>
      </Section>

      {pickerOpen && (
        <PlaybookPickerDialog
          incident={incident}
          wardId={incident.ward_id}
          leadingCategory={leadingCategory}
          onClose={() => setPickerOpen(false)}
          onCreated={onRefresh}
          onUseCustom={() => {
            setPickerOpen(false)
            setCustomOpen(true)
          }}
        />
      )}
      {customOpen && (
        <CreateInterventionDialog
          incidentId={incident.id}
          wardId={incident.ward_id}
          onClose={() => setCustomOpen(false)}
          onCreated={onRefresh}
        />
      )}
    </div>
  )
}
