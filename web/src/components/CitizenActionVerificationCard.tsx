import { useState } from 'react'
import { citizenSafeErrorMessage } from '../lib/errors'
import { CITIZEN_ACTION_ANSWER_LABEL, citizenActionVerificationSafety, type CitizenActionAnswer, type Severity } from '../lib/incidentRules'
import { submitCitizenActionVerification, type CitizenIncidentView } from '../lib/incidents'

/**
 * "Did the action actually happen?" — the citizen half of plan §15's
 * operational/environmental split. Shown underneath CitizenIncidentCard, only
 * once the incident's public status suggests an action has been taken.
 *
 * Reuses the exact same safety gate as evidence-mission verification
 * (citizenActionVerificationSafety → citizenVerificationSafety): closed
 * incidents and severe-air conditions are refused the same way. The one
 * category check that gate applies (never approach a hazardous source) is
 * passed `null` here deliberately — citizens cannot read `source_category`
 * hypotheses at all under RLS (verified in Phase 3), and this question only
 * ever asks "what do you see from where you are", never to approach anything,
 * so treating the category as unknown is the correct, RLS-consistent choice,
 * not a workaround.
 *
 * A citizen's answer is recorded as supporting evidence only — it never sets
 * `impact_evaluations.outcome` (see submit_citizen_action_verification in SQL).
 */

const ANSWERS: CitizenActionAnswer[] = ['completed', 'partial', 'not_completed', 'problem_remains', 'problem_returned']

const ANSWER_STYLE: Record<CitizenActionAnswer, string> = {
  completed: 'bg-brand-700 text-white hover:bg-brand-800',
  partial: 'border border-ink-200 text-ink-700 hover:bg-ink-50',
  not_completed: 'border border-ink-200 text-ink-700 hover:bg-ink-50',
  problem_remains: 'border border-status-warning/40 text-status-warning hover:bg-status-warning/10',
  problem_returned: 'border border-status-critical/40 text-status-critical hover:bg-status-critical/10',
}

/** Only offer this once the public timeline suggests something was actually
 *  done — asking "was the action completed?" before any action exists would
 *  be confusing, not merely unsafe. */
const ACTIONABLE_STATUSES = ['action_dispatched', 'in_progress', 'verifying']

export default function CitizenActionVerificationCard({ view }: { view: CitizenIncidentView }) {
  const [answered, setAnswered] = useState<CitizenActionAnswer | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!ACTIONABLE_STATUSES.includes(view.status)) return null

  const safety = citizenActionVerificationSafety({
    incidentStatus: view.status,
    leadingCategory: null,
    severity: (view.severity ?? null) as Severity | null,
  })

  const answer = async (a: CitizenActionAnswer) => {
    setSubmitting(true)
    setError(null)
    try {
      await submitCitizenActionVerification(view.id, a)
      setAnswered(a)
    } catch (e: unknown) {
      setError(citizenSafeErrorMessage(e, 'Could not send your answer.'))
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="mt-2 rounded-xl border border-ink-900/10 bg-white p-3">
      {!safety.safe ? (
        <div className="flex gap-2.5">
          <span aria-hidden className="text-base">🛡️</span>
          <div>
            <p className="text-sm font-medium text-ink-700">We are not asking you to confirm this right now</p>
            <p className="mt-0.5 text-xs text-ink-500">{safety.reason}</p>
          </div>
        </div>
      ) : answered ? (
        <p className="text-sm text-green-700">✓ Thank you - recorded as {CITIZEN_ACTION_ANSWER_LABEL[answered].toLowerCase()}.</p>
      ) : (
        <>
          <p className="text-sm font-semibold text-ink-800">Has the action been completed?</p>
          <p className="mt-0.5 text-xs text-ink-500">Answer only from where you are - this supports the result, it does not decide it.</p>
          <div className="mt-2 flex flex-wrap gap-1.5">
            {ANSWERS.map((a) => (
              <button
                key={a}
                type="button"
                disabled={submitting}
                onClick={() => answer(a)}
                className={`focus-ring rounded-lg px-2.5 py-1.5 text-[11px] font-semibold transition disabled:opacity-50 ${ANSWER_STYLE[a]}`}
              >
                {submitting ? '…' : CITIZEN_ACTION_ANSWER_LABEL[a]}
              </button>
            ))}
          </div>
          {error && <p className="mt-1.5 text-[11px] text-status-critical">{error}</p>}
        </>
      )}
    </div>
  )
}
