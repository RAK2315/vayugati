import { useEffect, useState } from 'react'
import { citizenSafeErrorMessage } from '../lib/errors'
import { fetchCitizenIncidentView, type CitizenIncidentView } from '../lib/incidents'
import CitizenActionVerificationCard from './CitizenActionVerificationCard'
import CitizenRecurrenceCard from './CitizenRecurrenceCard'
import IncidentTimeline from './IncidentTimeline'
import { ErrorState, Skeleton } from './ui'

/**
 * The citizen's window onto the incident their report was attached to.
 *
 * Deliberately plain-language and deliberately thin: it shows status, the
 * authority handling it, and the public timeline. It does not show source
 * probabilities, evidence confidence, internal notes or enforcement actions —
 * RLS blocks those, and this component doesn't ask for them either.
 */

/** Public wording for each internal status. Citizens see plain language, and
 *  several internal states collapse to one public step on purpose — the exact
 *  stage of an enforcement process is not public information. */
const PUBLIC_STATUS: Record<string, { label: string; hint: string; cls: string }> = {
  detected: { label: 'Reported', hint: 'We have your report and are looking at it.', cls: 'bg-ink-100 text-ink-700' },
  under_review: { label: 'Under review', hint: 'The team is assessing what is causing this.', cls: 'bg-ink-100 text-ink-700' },
  evidence_gathering: { label: 'Checking', hint: 'We are gathering evidence to confirm the source.', cls: 'bg-sky-100 text-sky-800' },
  routed: { label: 'With the authority', hint: 'It has been referred to the responsible authority.', cls: 'bg-sky-100 text-sky-800' },
  action_approved: { label: 'Action planned', hint: 'An action has been approved.', cls: 'bg-sky-100 text-sky-800' },
  action_dispatched: { label: 'Action underway', hint: 'A team has been sent.', cls: 'bg-sky-100 text-sky-800' },
  in_progress: { label: 'Action underway', hint: 'Work is in progress.', cls: 'bg-sky-100 text-sky-800' },
  verifying: { label: 'Checking the result', hint: 'We are measuring whether the air actually improved.', cls: 'bg-sky-100 text-sky-800' },
  closed: { label: 'Closed', hint: 'This incident has been closed.', cls: 'bg-green-100 text-green-800' },
}

export default function CitizenIncidentCard({ incidentId }: { incidentId: number }) {
  const [view, setView] = useState<CitizenIncidentView | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)
    fetchCitizenIncidentView(incidentId)
      .then((v) => {
        if (!cancelled) setView(v)
      })
      .catch((e: unknown) => {
        if (!cancelled) setError(citizenSafeErrorMessage(e, 'Could not load this incident.'))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [incidentId])

  if (loading) return <Skeleton className="h-20 w-full" />
  if (error) return <ErrorState message={error} />
  if (!view) {
    return (
      <p className="rounded-lg bg-ink-50 px-3 py-2 text-xs text-ink-500">
        This incident is no longer visible to you.
      </p>
    )
  }

  const status = PUBLIC_STATUS[view.status] ?? {
    label: 'In progress',
    hint: 'This report is being handled.',
    cls: 'bg-ink-100 text-ink-700',
  }

  return (
    <div className="rounded-xl border border-ink-900/10 bg-white p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className={`rounded px-2 py-0.5 text-[11px] font-bold uppercase tracking-wide ${status.cls}`}>
          {status.label}
        </span>
        <span className="text-xs text-ink-400">Incident #{view.id}</span>
        {view.ward_name && <span className="text-xs text-ink-400">· {view.ward_name}</span>}
      </div>
      <p className="mt-1.5 text-xs text-ink-600">{status.hint}</p>

      {view.assigned_authority && (
        <p className="mt-1.5 text-xs text-ink-600">
          <span className="font-semibold text-ink-700">Handled by:</span> {view.assigned_authority}
        </p>
      )}

      {/* Phase 4: "did the action actually happen?" - shown outside the
          collapsed timeline since it is actionable, not just informational. */}
      <CitizenActionVerificationCard view={view} />

      {/* Phase 5.1: for a closed incident, the final outcome and a way to
          report that the problem returned - shown outside the collapsed
          timeline for the same reason as the card above. */}
      <CitizenRecurrenceCard view={view} />

      <details className="group mt-2">
        <summary className="focus-ring cursor-pointer list-none text-xs font-semibold text-brand-700 hover:underline">
          <span className="group-open:hidden">Show what has happened →</span>
          <span className="hidden group-open:inline">Hide details</span>
        </summary>
        <div className="mt-2.5 border-t border-ink-900/5 pt-2.5">
          <IncidentTimeline
            events={view.timeline}
            emptyMessage="No public updates yet. You will see progress here as the team works on it."
          />
        </div>
      </details>
    </div>
  )
}
