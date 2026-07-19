import { useState } from 'react'
import { useAuth } from '../lib/auth'
import {
  RECURRENCE_REVIEW_STATUS_LABEL,
  RECURRENCE_TYPE_LABEL,
  recommendRecurrenceDecision,
  type RecurrenceDecisionContext,
} from '../lib/incidentRules'
import {
  confirmRecurrenceReport,
  createLinkedIncidentFromRecurrence,
  dismissRecurrenceReport,
  mergeRecurrenceIntoIncident,
  reopenIncidentFromRecurrence,
  requestMoreEvidenceForRecurrence,
  type IncidentDetail,
  type IncidentRecurrenceReportRow,
} from '../lib/incidents'
import { Label } from './ui'

/**
 * Command review queue for citizen recurrence reports on a CLOSED incident
 * (Phase 5.1). Shown only for closed incidents that have at least one
 * recurrence report — a citizen's report never reopens anything or creates an
 * enforcement task by itself (see incidents.ts); every disposition here is an
 * explicit command decision.
 */

function ageHours(ts: string): number {
  return (Date.now() - new Date(ts).getTime()) / 3_600_000
}

function fmtAge(hours: number): string {
  if (hours < 1) return '<1h'
  if (hours < 48) return `${Math.floor(hours)}h`
  return `${Math.floor(hours / 24)}d`
}

const STATUS_STYLE: Record<string, string> = {
  pending: 'bg-status-warning/20 text-status-warning',
  more_evidence_requested: 'bg-sky-100 text-sky-800',
  confirmed: 'bg-green-100 text-green-800',
  dismissed: 'bg-ink-100 text-ink-600',
}

function ReportCard({
  report,
  detail,
  onRefresh,
}: {
  report: IncidentRecurrenceReportRow
  detail: IncidentDetail
  onRefresh: () => void
}) {
  const { session } = useAuth()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const { incident, impactEvaluations } = detail
  const lastImpactOutcome = impactEvaluations[0]?.outcome ?? null

  const isPureImpactOutcome = (o: typeof lastImpactOutcome): o is RecurrenceDecisionContext['lastImpactOutcome'] & object =>
    o === 'effective' || o === 'partly_effective' || o === 'ineffective' || o === 'inconclusive'

  const ctx: RecurrenceDecisionContext = {
    closedAt: incident.closed_at,
    reportCreatedAt: report.created_at,
    lastImpactOutcome: isPureImpactOutcome(lastImpactOutcome) ? lastImpactOutcome : null,
    recurrenceType: report.recurrence_type as RecurrenceDecisionContext['recurrenceType'],
    incidentLat: incident.lat,
    incidentLng: incident.lng,
    reportLat: report.lat,
    reportLng: report.lng,
  }
  const decision = recommendRecurrenceDecision(ctx)
  const isPending = report.review_status === 'pending' || report.review_status === 'more_evidence_requested'

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

  const dismiss = () => {
    if (!session) return
    const reason = window.prompt('Public-safe reason for dismissing this report (shown to the citizen):')
    if (!reason?.trim()) return
    void act(() => dismissRecurrenceReport(report.id, incident.id, reason.trim(), session.user.id))
  }

  const requestEvidence = () => {
    if (!session) return
    const msg = window.prompt('What more evidence do you need? (shown to the citizen):')
    if (!msg?.trim()) return
    void act(() => requestMoreEvidenceForRecurrence(report.id, incident.id, msg.trim(), session.user.id))
  }

  const confirm = () => {
    if (!session) return
    void act(() => confirmRecurrenceReport(report.id, incident.id, 'Confirmed as a genuine recurrence.', session.user.id))
  }

  const reopen = () => {
    if (!session) return
    const note = window.prompt('Note for reopening the original incident (shown to the citizen):', 'The problem has returned; the incident has been reopened.')
    if (!note?.trim()) return
    void act(() => reopenIncidentFromRecurrence(report.id, incident.id, session.user.id, note.trim()))
  }

  const createLinked = () => {
    if (!session || incident.ward_id == null) return
    const summary = window.prompt('Summary for the new linked incident:', `Recurrence of incident #${incident.id}: ${incident.summary ?? ''}`.trim())
    if (!summary?.trim()) return
    void act(() =>
      createLinkedIncidentFromRecurrence(report.id, incident.id, incident.ward_id as number, session.user.id, summary.trim()).then(() => {}),
    )
  }

  const merge = () => {
    if (!session) return
    const targetIdRaw = window.prompt('Incident # to merge this recurrence report into:')
    const targetId = targetIdRaw ? Number(targetIdRaw) : NaN
    if (!Number.isFinite(targetId)) return
    void act(() =>
      mergeRecurrenceIntoIncident(report.id, incident.id, targetId, report.note, report.photo_url, report.lat, report.lng, session.user.id),
    )
  }

  return (
    <li className="rounded-xl border border-ink-900/10 bg-white p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-semibold text-ink-800">{RECURRENCE_TYPE_LABEL[report.recurrence_type as keyof typeof RECURRENCE_TYPE_LABEL]}</span>
        <span className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${STATUS_STYLE[report.review_status] ?? 'bg-ink-100 text-ink-600'}`}>
          {RECURRENCE_REVIEW_STATUS_LABEL[report.review_status as keyof typeof RECURRENCE_REVIEW_STATUS_LABEL] ?? report.review_status}
        </span>
        <span className="ml-auto text-[11px] tabular-nums text-ink-400">{fmtAge(ageHours(report.created_at))} ago</span>
      </div>

      {report.note && <p className="mt-1.5 text-sm text-ink-700">{report.note}</p>}
      <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-[11px] sm:grid-cols-3">
        <div>
          <dt className="text-ink-400">Location given</dt>
          <dd className="font-semibold text-ink-700">{report.lat != null && report.lng != null ? `${report.lat.toFixed(3)}, ${report.lng.toFixed(3)}` : 'Not provided'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Photo</dt>
          <dd className="font-semibold text-ink-700">{report.photo_url ? 'Attached' : 'None'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Reported</dt>
          <dd className="font-semibold text-ink-700">{new Date(report.created_at).toLocaleString()}</dd>
        </div>
      </dl>

      <div className="mt-2 rounded-lg bg-brand-50 px-2.5 py-1.5">
        <p className="text-[11px] font-semibold uppercase tracking-wide text-brand-800">
          Recommendation: {decision.recommendation.replace(/_/g, ' ')}
        </p>
        <ul className="mt-1 list-disc pl-4 text-[11px] text-brand-800">
          {decision.reasons.map((r, i) => (
            <li key={i}>{r}</li>
          ))}
        </ul>
        <p className="mt-1 text-[10px] italic text-brand-700">A recommendation only — command makes the final call.</p>
      </div>

      {report.public_response && (
        <p className="mt-2 rounded-lg bg-ink-50 px-2.5 py-1.5 text-[11px] text-ink-600">
          <span className="font-semibold">Sent to citizen: </span>
          {report.public_response}
        </p>
      )}

      {isPending && (
        <div className="mt-3 flex flex-wrap gap-1.5">
          <button type="button" disabled={busy} onClick={dismiss} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Dismiss
          </button>
          <button type="button" disabled={busy} onClick={requestEvidence} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Request more evidence
          </button>
          <button type="button" disabled={busy} onClick={confirm} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Confirm recurrence
          </button>
          <button type="button" disabled={busy} onClick={reopen} className="focus-ring rounded-lg bg-status-warning/15 px-2.5 py-1 text-[11px] font-semibold text-status-warning hover:bg-status-warning/25 disabled:opacity-50">
            Reopen original incident
          </button>
          <button type="button" disabled={busy} onClick={createLinked} className="focus-ring rounded-lg bg-brand-700 px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-brand-800 disabled:opacity-50">
            Create new linked incident
          </button>
          <button type="button" disabled={busy} onClick={merge} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Merge with nearby open incident
          </button>
        </div>
      )}
      {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}
    </li>
  )
}

export default function RecurrencePanel({ detail, onRefresh }: { detail: IncidentDetail; onRefresh: () => void }) {
  const { incident, recurrenceReports, interventions, impactEvaluations } = detail
  if (incident.status !== 'closed' || recurrenceReports.length === 0) return null

  const closedAt = incident.closed_at
  const hoursSinceClosure = closedAt ? ageHours(closedAt) : null
  const lastIntervention = interventions[interventions.length - 1]?.action ?? null
  const lastImpact = impactEvaluations[0] ?? null

  return (
    <section className="border-t border-ink-900/5 px-4 py-3">
      <div className="mb-2 flex items-center gap-2">
        <Label dark>Recurrence reports</Label>
        <span className="rounded bg-ink-100 px-1.5 text-[10px] font-bold text-ink-600">{recurrenceReports.length}</span>
      </div>

      <dl className="mb-3 grid grid-cols-2 gap-x-3 gap-y-1 text-[11px] sm:grid-cols-4">
        <div>
          <dt className="text-ink-400">Closed</dt>
          <dd className="font-semibold text-ink-700">{closedAt ? new Date(closedAt).toLocaleDateString() : 'Unknown'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Time since closure</dt>
          <dd className="font-semibold text-ink-700">{hoursSinceClosure != null ? fmtAge(hoursSinceClosure) : '—'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Previous intervention</dt>
          <dd className="font-semibold capitalize text-ink-700">{lastIntervention?.type ?? 'None recorded'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Previous impact result</dt>
          <dd className="font-semibold capitalize text-ink-700">{lastImpact?.outcome?.replace(/_/g, ' ') ?? 'Not evaluated'}</dd>
        </div>
      </dl>

      <ul className="space-y-2">
        {recurrenceReports.map((r) => (
          <ReportCard key={r.id} report={r} detail={detail} onRefresh={onRefresh} />
        ))}
      </ul>
    </section>
  )
}
