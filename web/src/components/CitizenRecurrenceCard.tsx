import { useEffect, useState } from 'react'
import { useAuth } from '../lib/auth'
import { citizenSafeErrorMessage } from '../lib/errors'
import { citizenRecurrenceStatusLabel, RECURRENCE_TYPES, RECURRENCE_TYPE_LABEL, type RecurrenceType } from '../lib/incidentRules'
import { uploadReportPhoto } from '../lib/data'
import {
  fetchMyRecurrenceReports,
  submitIncidentRecurrenceReport,
  type CitizenIncidentView,
  type CitizenRecurrenceReport,
} from '../lib/incidents'

/**
 * "Report that the problem returned" (Phase 5.1) — shown only for a CLOSED
 * incident. Deliberately shows nothing about internal action/agency/officer
 * detail: only the final outcome (from impact_evaluations.outcome, which RLS
 * already lets a linked citizen read directly) and whether an action was
 * completed at all (derived from the PUBLIC timeline, same as
 * CitizenActionVerificationCard's ACTIONABLE_STATUSES check).
 *
 * Submitting never reopens the incident or creates an enforcement task —
 * see `submitIncidentRecurrenceReport` in incidents.ts, which deliberately
 * never touches `incidents` or `actions`.
 */

const OUTCOME_LABEL: Record<string, string> = {
  effective: 'The action worked - pollution levels came down.',
  partly_effective: 'The action partly worked - levels improved somewhat.',
  ineffective: "The action didn't measurably help.",
  inconclusive: 'Not enough data to say whether the action helped.',
  source_disproved: 'The suspected source was ruled out.',
  completed_no_change: 'The action was completed with no measurable change.',
  recurred: 'The problem recurred after the action.',
}

function previousActionStatus(view: CitizenIncidentView): string {
  const types = new Set(view.timeline.map((e) => e.event_type))
  if (types.has('action_completed')) return 'Completed'
  if (types.has('action_dispatched')) return 'Dispatched to a field team'
  if (types.has('task_created') || types.has('custom_intervention_created')) return 'Planned, not yet completed'
  return 'No action recorded'
}

export default function CitizenRecurrenceCard({ view }: { view: CitizenIncidentView }) {
  const { session } = useAuth()
  const [reports, setReports] = useState<CitizenRecurrenceReport[]>([])
  const [loadingReports, setLoadingReports] = useState(true)
  const [formOpen, setFormOpen] = useState(false)

  const [recurrenceType, setRecurrenceType] = useState<RecurrenceType>('returned')
  const [note, setNote] = useState('')
  const [geoLoading, setGeoLoading] = useState(false)
  const [coords, setCoords] = useState<{ lat: number; lng: number } | null>(null)
  const [photo, setPhoto] = useState<File | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refreshReports = () => {
    setLoadingReports(true)
    fetchMyRecurrenceReports(view.id)
      .then(setReports)
      .catch(() => setReports([]))
      .finally(() => setLoadingReports(false))
  }

  useEffect(() => {
    refreshReports()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view.id])

  if (view.status !== 'closed') return null

  const hasPending = reports.some((r) => r.review_status === 'pending' || r.review_status === 'more_evidence_requested')

  const detectLocation = () => {
    setGeoLoading(true)
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setCoords({ lat: pos.coords.latitude, lng: pos.coords.longitude })
        setGeoLoading(false)
      },
      () => setGeoLoading(false),
      { timeout: 8000 },
    )
  }

  const submit = async () => {
    if (!session) return
    setSubmitting(true)
    setError(null)
    try {
      let photoUrl: string | null = null
      if (photo) {
        try {
          photoUrl = await uploadReportPhoto(photo, session.user.id)
        } catch {
          // Best-effort, same as the original report form — a failed upload
          // must not block the recurrence report itself.
        }
      }
      await submitIncidentRecurrenceReport({
        incidentId: view.id,
        recurrenceType,
        note: note.trim() || null,
        lat: coords?.lat ?? null,
        lng: coords?.lng ?? null,
        photoUrl,
      })
      setFormOpen(false)
      setNote('')
      setCoords(null)
      setPhoto(null)
      refreshReports()
    } catch (e: unknown) {
      setError(citizenSafeErrorMessage(e, 'Could not send your report.'))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="mt-2 rounded-xl border border-ink-900/10 bg-white p-3">
      <p className="text-sm font-semibold text-ink-800">This incident is closed</p>
      <dl className="mt-1.5 grid grid-cols-1 gap-y-1 text-xs text-ink-600 sm:grid-cols-2">
        <div>
          <dt className="text-ink-400">Final outcome</dt>
          <dd className="font-medium text-ink-700">{view.last_outcome ? (OUTCOME_LABEL[view.last_outcome] ?? view.last_outcome.replace(/_/g, ' ')) : 'Not measured'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Previous action</dt>
          <dd className="font-medium text-ink-700">{previousActionStatus(view)}</dd>
        </div>
      </dl>

      {!loadingReports && reports.length > 0 && (
        <ul className="mt-2 space-y-1 border-t border-ink-900/5 pt-2">
          {reports.map((r) => (
            <li key={r.report_id} className="text-xs text-ink-600">
              <span className="font-semibold text-ink-700">{RECURRENCE_TYPE_LABEL[r.recurrence_type]}:</span>{' '}
              {citizenRecurrenceStatusLabel(r.review_status, r.outcome_kind)}
              {r.public_response && <span className="text-ink-500"> - {r.public_response}</span>}
            </li>
          ))}
        </ul>
      )}

      {hasPending ? (
        <p className="mt-2.5 rounded-lg bg-sky-50 px-2.5 py-1.5 text-xs text-sky-800">
          Your report is being reviewed. We'll update the status here.
        </p>
      ) : !formOpen ? (
        <button
          type="button"
          onClick={() => setFormOpen(true)}
          className="focus-ring mt-2.5 rounded-lg border border-status-warning/40 px-2.5 py-1.5 text-xs font-semibold text-status-warning hover:bg-status-warning/10"
        >
          Report that the problem returned
        </button>
      ) : (
        <div className="mt-2.5 border-t border-ink-900/5 pt-2.5">
          <label className="block text-xs font-semibold text-ink-700">What are you seeing?</label>
          <select
            value={recurrenceType}
            onChange={(e) => setRecurrenceType(e.target.value as RecurrenceType)}
            className="focus-ring mt-1 w-full rounded-lg border border-ink-200 bg-white px-2.5 py-2 text-sm"
          >
            {RECURRENCE_TYPES.map((t) => (
              <option key={t} value={t}>
                {RECURRENCE_TYPE_LABEL[t]}
              </option>
            ))}
          </select>

          <label className="mt-2 block text-xs font-semibold text-ink-700">Note (optional)</label>
          <textarea
            rows={2}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Anything that would help us understand what's happening"
            className="focus-ring mt-1 w-full rounded-lg border border-ink-200 px-2.5 py-2 text-xs"
          />

          <div className="mt-2 flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={detectLocation}
              disabled={geoLoading}
              className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1.5 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50"
            >
              {geoLoading ? 'Locating…' : coords ? '📍 Location added' : '📍 Add my location (optional)'}
            </button>
            <label className="focus-ring cursor-pointer rounded-lg border border-ink-200 px-2.5 py-1.5 text-[11px] font-semibold text-ink-700 hover:bg-ink-50">
              {photo ? '📷 Photo added' : '📷 Add a photo (optional)'}
              <input type="file" accept="image/*" capture="environment" onChange={(e) => setPhoto(e.target.files?.[0] ?? null)} className="hidden" />
            </label>
          </div>

          {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}

          <div className="mt-3 flex justify-end gap-2">
            <button
              type="button"
              onClick={() => setFormOpen(false)}
              className="focus-ring rounded-lg border border-ink-200 px-3 py-1.5 text-xs font-semibold text-ink-700 hover:bg-ink-50"
            >
              Cancel
            </button>
            <button
              type="button"
              disabled={submitting}
              onClick={submit}
              className="focus-ring rounded-lg bg-status-warning px-3 py-1.5 text-xs font-semibold text-white hover:opacity-90 disabled:opacity-50"
            >
              {submitting ? 'Sending…' : 'Send report'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
