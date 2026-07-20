import { useState } from 'react'
import { Info, RotateCcw, Send, ShieldCheck, XCircle } from 'lucide-react'
import { StickyActionBar } from '../ui'
import { useAuth } from '../../lib/auth'
import { taskBlockedReason } from '../../lib/incidentRules'
import { reopenIncident, updateIncidentAssignment, updateIncidentStatus, type Incident } from '../../lib/incidents'
import EvidenceMissionDialog from './EvidenceMissionDialog'

/** Standardized "why is this unavailable" helper line - used for both a
 *  dynamically-computed reason (Route to authority) and a static one (Close
 *  incident, which has no client-side eligibility check - the DB trigger is
 *  the real gate). One consistent visual treatment either way. */
function HelperNote({ children }: { children: React.ReactNode }) {
  return (
    <p className="mt-2 flex items-start gap-1.5 rounded-lg bg-slate-50 px-2.5 py-1.5 text-[11px] leading-relaxed text-slate-600">
      <Info className="mt-0.5 h-3 w-3 flex-shrink-0 text-slate-400" strokeWidth={2} aria-hidden />
      <span>{children}</span>
    </p>
  )
}

/** The action toolbar - sticky at the bottom of the viewport on mobile
 *  (thumb reach), a normal inline row on desktop. Same handlers/gating as
 *  before: which buttons exist is decided by evidence level, and every
 *  unavailable action explains itself with the same helper-note style. */
export default function IncidentActionBar({ incident, onRefresh }: { incident: Incident; onRefresh: () => void }) {
  const { session } = useAuth()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [missionOpen, setMissionOpen] = useState(false)

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

  const assign = () => {
    if (!session) return
    const authority = window.prompt('Refer this incident to which authority?')
    if (!authority?.trim()) return
    void act(() => updateIncidentAssignment(incident.id, authority.trim(), session.user.id))
  }

  const close = () => {
    if (!session) return
    void act(() => updateIncidentStatus(incident.id, 'closed', session.user.id, 'Closed from the command workspace.'))
  }

  const reopen = () => {
    if (!session) return
    const note = window.prompt('Why is this incident being reopened? (e.g. problem recurred)')
    if (!note?.trim()) return
    void act(() => reopenIncident(incident.id, null, session.user.id, note.trim()))
  }

  const inspectionBlocked = taskBlockedReason(incident.source_confidence, 'inspection')
  const closeNote = 'An incident with a completed action and no impact evaluation cannot be closed.'

  return (
    <div className="border-b border-slate-200 bg-white px-4 py-3">
      <StickyActionBar>
        <button
          type="button"
          disabled={busy}
          onClick={() => setMissionOpen(true)}
          className="focus-ring flex items-center gap-1.5 rounded-lg bg-accent-600 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-accent-700 disabled:opacity-50"
        >
          <ShieldCheck className="h-3.5 w-3.5" strokeWidth={2} aria-hidden />
          Request evidence
        </button>
        <button
          type="button"
          disabled={busy || !!inspectionBlocked}
          onClick={assign}
          className="focus-ring flex items-center gap-1.5 rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-700 transition hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <Send className="h-3.5 w-3.5" strokeWidth={2} aria-hidden />
          Route to authority
        </button>
        {incident.status === 'closed' ? (
          <button
            type="button"
            disabled={busy}
            onClick={reopen}
            className="focus-ring flex items-center gap-1.5 rounded-lg border border-status-warning/40 px-3 py-1.5 text-xs font-semibold text-status-warning transition hover:bg-status-warning/10 disabled:opacity-50"
          >
            <RotateCcw className="h-3.5 w-3.5" strokeWidth={2} aria-hidden />
            Reopen (recurrence)
          </button>
        ) : (
          <button
            type="button"
            disabled={busy}
            onClick={close}
            className="focus-ring flex items-center gap-1.5 rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-700 transition hover:bg-slate-50 disabled:opacity-50"
          >
            <XCircle className="h-3.5 w-3.5" strokeWidth={2} aria-hidden />
            Close incident
          </button>
        )}
      </StickyActionBar>

      {inspectionBlocked && <HelperNote>Route to authority is unavailable: {inspectionBlocked}</HelperNote>}
      {incident.status !== 'closed' && <HelperNote>{closeNote}</HelperNote>}
      {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}

      {missionOpen && (
        <EvidenceMissionDialog incident={incident} onClose={() => setMissionOpen(false)} onCreated={onRefresh} />
      )}
    </div>
  )
}
