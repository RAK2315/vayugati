import { useEffect, useState } from 'react'
import { useAuth } from '../lib/auth'
import { citizenSafeErrorMessage } from '../lib/errors'
import { citizenVerificationSafety, type MissionOutcome, type Severity } from '../lib/incidentRules'
import { fetchCitizenMissions, submitCitizenVerification, type CitizenMission } from '../lib/incidents'
import { Card, CardHeader, ErrorState, Skeleton } from './ui'

/**
 * Targeted citizen verification (plan §11).
 *
 * Two things this component is careful about:
 *
 * 1. Safety. The rule runs before anything renders: an unsafe or irrelevant
 *    request is never shown as a task, it is shown as an explanation of why we
 *    are not asking. A citizen is never asked to approach a fire or an
 *    industrial site, or to go outside when the air is severe.
 *
 * 2. Disclosure. The data comes from an RPC that returns only citizen-safe
 *    fields — the internal rationale is not merely hidden here, it is
 *    unreachable from a citizen's session. This component cannot leak what it
 *    was never given.
 */

const ANSWERS: { outcome: MissionOutcome; label: string; cls: string }[] = [
  { outcome: 'confirmed', label: 'Yes, still happening', cls: 'bg-brand-700 text-white hover:bg-brand-800' },
  { outcome: 'rejected', label: 'No, it has stopped', cls: 'border border-ink-200 text-ink-700 hover:bg-ink-50' },
  { outcome: 'unresolved', label: "Can't tell", cls: 'border border-ink-200 text-ink-500 hover:bg-ink-50' },
]

export default function CitizenVerificationCard() {
  const { session } = useAuth()
  const [missions, setMissions] = useState<CitizenMission[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState<number | null>(null)
  const [done, setDone] = useState<Record<number, MissionOutcome>>({})

  useEffect(() => {
    if (!session) return
    let cancelled = false
    fetchCitizenMissions()
      .then((m) => {
        if (!cancelled) setMissions(m)
      })
      .catch((e: unknown) => {
        if (!cancelled) setError(citizenSafeErrorMessage(e, 'Could not load verification requests.'))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [session])

  const answer = async (m: CitizenMission, outcome: MissionOutcome) => {
    setSubmitting(m.mission_id)
    setError(null)
    try {
      await submitCitizenVerification(m.mission_id, outcome)
      setDone((d) => ({ ...d, [m.mission_id]: outcome }))
    } catch (e: unknown) {
      setError(citizenSafeErrorMessage(e, 'Could not send your answer.'))
    } finally {
      setSubmitting(null)
    }
  }

  if (!session) return null
  if (loading) return <Skeleton className="h-16 w-full" />
  if (error && !missions.length) return <ErrorState message={error} />

  const open = missions.filter((m) => m.status !== 'completed' && m.status !== 'cancelled')
  if (!open.length) return null

  return (
    <Card>
      <CardHeader title="Can you help check something?" subtitle="Only if it is safe and nearby" />
      <ul className="divide-y divide-ink-900/5">
        {open.map((m) => {
          const safety = citizenVerificationSafety({
            missionType: m.mission_type,
            missionStatus: m.status,
            incidentStatus: m.incident_status,
            leadingCategory: m.leading_category,
            severity: (m.severity ?? null) as Severity | null,
          })
          const answered = done[m.mission_id]

          return (
            <li key={m.mission_id} className="px-4 py-3">
              {!safety.safe ? (
                // Not a task — an explanation. The citizen is told why we are not
                // asking them, rather than shown a dead control.
                <div className="flex gap-2.5">
                  <span aria-hidden className="text-base">🛡️</span>
                  <div>
                    <p className="text-sm font-medium text-ink-700">We are not asking you to check this one</p>
                    <p className="mt-0.5 text-xs text-ink-500">{safety.reason}</p>
                  </div>
                </div>
              ) : answered ? (
                <p className="text-sm text-green-700">✓ Thank you - your answer was sent to the team.</p>
              ) : (
                <>
                  <p className="text-sm text-ink-800">
                    {m.public_prompt ?? 'Is the pollution you reported still happening?'}
                  </p>
                  <p className="mt-0.5 text-xs text-ink-400">
                    Incident #{m.incident_id}
                    {m.ward_name && ` · ${m.ward_name}`}
                  </p>
                  <p className="mt-1.5 text-[11px] text-ink-400">
                    Answer from where you are. Please do not go closer to check.
                  </p>
                  <div className="mt-2 flex flex-wrap gap-2">
                    {ANSWERS.map(({ outcome, label, cls }) => (
                      <button
                        key={outcome}
                        type="button"
                        disabled={submitting === m.mission_id}
                        onClick={() => answer(m, outcome)}
                        className={`focus-ring rounded-lg px-3 py-1.5 text-xs font-semibold transition disabled:opacity-50 ${cls}`}
                      >
                        {submitting === m.mission_id ? '…' : label}
                      </button>
                    ))}
                  </div>
                </>
              )}
            </li>
          )
        })}
      </ul>
      {error && <p className="border-t border-ink-900/5 px-4 py-2 text-xs text-status-critical">{error}</p>}
    </Card>
  )
}
