import { useState } from 'react'
import { useAuth } from '../../lib/auth'
import { createEvidenceMission, listAssignableOfficers, listLinkedReports, type AssignableOfficer, type Incident } from '../../lib/incidents'
import { useAsync } from '../../lib/useAsync'
import { Modal, Skeleton } from '../ui'

/**
 * Next-best-evidence dialog (plan §10). The rationale is mandatory — the system
 * must always say WHY the evidence is needed, not just ask for it — and a
 * mission with no assignee would never reach anyone, so the officer picker is
 * part of dispatching rather than an afterthought.
 *
 * Migrated onto the shared Modal primitive (ui.tsx) - this was the dialog
 * that predated it and was never moved over. Same fields/validation/handlers,
 * now with Escape-to-close and first-field autofocus for free.
 */
export default function EvidenceMissionDialog({
  incident,
  onClose,
  onCreated,
}: {
  incident: Incident
  onClose: () => void
  onCreated: () => void
}) {
  const { session } = useAuth()
  const [missionType, setMissionType] = useState<'field_photo' | 'citizen_verification' | 'source_status_check'>(
    'field_photo',
  )
  const [assignee, setAssignee] = useState<string>('')
  const [rationale, setRationale] = useState(
    'Source confidence is insufficient to justify an action task. A geotagged field photograph is the smallest evidence that can corroborate or rule out the suspected source.',
  )
  const [publicPrompt, setPublicPrompt] = useState('Is the pollution you reported still happening?')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const officers = useAsync(() => listAssignableOfficers(incident.ward_id), [incident.ward_id])
  const officerList: AssignableOfficer[] = officers.data ?? []
  const isCitizenMission = missionType === 'citizen_verification'

  // A citizen mission has to be addressed to a specific citizen: they only ever
  // see missions assigned to them. The people who reported this incident are the
  // ones who are actually there, so they are the candidates.
  const reporters = useAsync(
    async () => {
      const rs = await listLinkedReports(incident.id)
      const seen = new Set<string>()
      return rs.filter((r) => r.reporter_id && !seen.has(r.reporter_id) && seen.add(r.reporter_id))
    },
    [incident.id],
    { enabled: isCitizenMission },
  )
  const reporterList = reporters.data ?? []

  const create = async () => {
    if (!session) return
    setBusy(true)
    setError(null)
    try {
      await createEvidenceMission({
        incidentId: incident.id,
        missionType,
        // Either way this must name a person: a mission with no assignee is
        // visible to nobody under RLS and would sit unworked forever.
        assignedTo: assignee || null,
        rationale,
        publicPrompt: isCitizenMission ? publicPrompt : null,
        actorId: session.user.id,
      })
      onCreated()
      onClose()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not create the mission.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal title="Request the next best evidence" onClose={onClose}>
      <p className="-mt-1 text-xs text-slate-400">
        The smallest useful mission that would raise or rule out confidence in this source.
      </p>

      <label className="mt-3 block text-xs font-semibold text-slate-700">Mission type</label>
      <select
        value={missionType}
        onChange={(e) => setMissionType(e.target.value as typeof missionType)}
        className="focus-ring mt-1 w-full rounded-lg border border-slate-200 bg-white px-2.5 py-2 text-sm"
      >
        <option value="field_photo">Geotagged field photograph (officer)</option>
        <option value="source_status_check">Source operating-status check (officer)</option>
        <option value="citizen_verification">Targeted citizen verification</option>
      </select>

      <label className="mt-3 block text-xs font-semibold text-slate-700">
        {isCitizenMission ? 'Ask which reporter' : 'Assign to'}
      </label>
      {(isCitizenMission ? reporters.loading : officers.loading) ? (
        <Skeleton className="mt-1 h-9 w-full" />
      ) : (isCitizenMission ? reporters.error : officers.error) ? (
        <p className="mt-1 text-xs text-status-critical">{isCitizenMission ? reporters.error : officers.error}</p>
      ) : isCitizenMission ? (
        reporterList.length === 0 ? (
          <p className="mt-1 rounded-lg bg-status-warning/10 px-2.5 py-2 text-xs text-slate-600">
            No citizen reports are linked to this incident, so there is nobody to ask. Use an officer mission instead.
          </p>
        ) : (
          <select
            value={assignee}
            onChange={(e) => setAssignee(e.target.value)}
            className="focus-ring mt-1 w-full rounded-lg border border-slate-200 bg-white px-2.5 py-2 text-sm"
          >
            <option value="">Select a reporter…</option>
            {reporterList.map((r) => (
              <option key={r.id} value={r.reporter_id ?? ''}>
                Reporter of #{r.id} · {new Date(r.created_at).toLocaleDateString()}
              </option>
            ))}
          </select>
        )
      ) : officerList.length === 0 ? (
        // Honest dead-end: a real operational state (no officer covers this
        // ward), not an empty dropdown to shrug at.
        <p className="mt-1 rounded-lg bg-status-warning/10 px-2.5 py-2 text-xs text-slate-600">
          No field officer is assigned to this ward, so this mission cannot be dispatched. Assign an officer to the
          ward first (roles are set in SQL today - see README).
        </p>
      ) : (
        <select
          value={assignee}
          onChange={(e) => setAssignee(e.target.value)}
          className="focus-ring mt-1 w-full rounded-lg border border-slate-200 bg-white px-2.5 py-2 text-sm"
        >
          <option value="">Select an officer…</option>
          {officerList.map((o) => (
            <option key={o.id} value={o.id}>
              {o.full_name ?? o.id.slice(0, 8)}
            </option>
          ))}
        </select>
      )}

      {isCitizenMission && (
        <p className="mt-1.5 text-[11px] leading-relaxed text-slate-400">
          The citizen is only shown this if our safety rule allows it - we never ask the public to approach fires or
          industrial sites, or to go outside when the air is severe.
        </p>
      )}

      <label className="mt-3 block text-xs font-semibold text-slate-700">
        Why is this evidence needed? <span className="font-normal text-slate-400">(recorded on the incident)</span>
      </label>
      <textarea
        rows={3}
        value={rationale}
        onChange={(e) => setRationale(e.target.value)}
        className="focus-ring mt-1 w-full rounded-lg border border-slate-200 px-2.5 py-2 text-xs"
      />

      {isCitizenMission && (
        <>
          <label className="mt-3 block text-xs font-semibold text-slate-700">
            Question shown to the citizen{' '}
            <span className="font-normal text-slate-400">(never include enforcement detail)</span>
          </label>
          <input
            value={publicPrompt}
            onChange={(e) => setPublicPrompt(e.target.value)}
            className="focus-ring mt-1 w-full rounded-lg border border-slate-200 px-2.5 py-2 text-xs"
          />
        </>
      )}

      {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}

      <div className="mt-4 flex justify-end gap-2">
        <button
          type="button"
          onClick={onClose}
          className="focus-ring rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50"
        >
          Cancel
        </button>
        <button
          type="button"
          disabled={busy || !rationale.trim() || !assignee}
          title={!assignee ? 'Choose who this mission goes to - an unassigned mission reaches nobody' : undefined}
          onClick={create}
          className="focus-ring rounded-lg bg-accent-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-accent-700 disabled:opacity-50"
        >
          {busy ? 'Creating…' : 'Create mission'}
        </button>
      </div>
    </Modal>
  )
}
