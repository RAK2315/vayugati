import { useState } from 'react'
import { useAuth } from '../lib/auth'
import {
  cleanMissionRationale,
  CLASSIFICATION_LABEL,
  HYPOTHESIS_REVIEW_STATUS_LABEL,
  isHumanConfirmedClassification,
  needsMoreAttributionEvidence,
  parseDataQualityNote,
  PROBABLE_SOURCE_DISCLAIMER,
  sourceCategoryLabel,
  type HypothesisReviewStatus,
} from '../lib/incidentRules'
import {
  recalculateSourceAttribution,
  reviewSourceHypothesis,
  type HypothesisReviewAction,
  type IncidentDetail,
  type SourceHypothesisRow,
} from '../lib/incidents'
import { Label, UnavailableBadge } from './ui'

/**
 * Probable-source attribution panel (Phase 7) — a ranked, evidence-backed set
 * of source hypotheses for the selected incident, with the responsible-
 * authority routing, local/regional classification, data-quality warning and
 * recommended next evidence mission the rule engine itself already computed
 * and stored. This panel reads and reviews; it never scores anything client-
 * side — see `calculate_incident_source_attribution` (SQL) for the actual
 * engine, which is the single source of truth this panel just displays.
 */

function pct(p: number): string {
  return `${Math.round(p * 100)}%`
}

function HypothesisCard({
  h,
  onReview,
  busy,
}: {
  h: SourceHypothesisRow
  onReview: (h: SourceHypothesisRow, action: HypothesisReviewAction) => void
  busy: boolean
}) {
  const supporting = Array.isArray(h.supporting_evidence) ? (h.supporting_evidence as string[]) : []
  const contradicting = Array.isArray(h.contradicting_evidence) ? (h.contradicting_evidence as string[]) : []
  const missing = Array.isArray(h.missing_evidence) ? (h.missing_evidence as string[]) : []
  const reviewStatus = (h.review_status ?? 'pending') as HypothesisReviewStatus
  const isVerified = h.confidence_level === 'officially_verified'
  // The attribution engine stores 'unresolved' with probability=1.0 - it's
  // 100% CERTAIN the source is unresolved, not "100% confident in a source".
  // Rendered as a percentage/progress-bar that reads exactly backwards, so
  // this gets its own honest copy instead of the generic pct()/bar treatment.
  const isUnresolved = h.source_category === 'unresolved'

  return (
    <li className="rounded-lg bg-slate-50 p-2.5">
      <div className="flex items-center justify-between gap-2">
        <span className="text-sm font-semibold capitalize text-slate-800">{sourceCategoryLabel(h.source_category)}</span>
        {!isUnresolved && <span className="tabular-nums text-sm font-semibold text-slate-800">{pct(h.probability)}</span>}
      </div>
      {isUnresolved ? (
        <p className="mt-1 text-xs text-slate-500">
          Insufficient independent evidence - no source category has enough evidence to be assessed as more likely
          than others.
        </p>
      ) : (
        <div className="mt-1 h-1.5 w-full overflow-hidden rounded-full bg-slate-100">
          <div className="h-full rounded-full bg-accent-500" style={{ width: pct(h.probability) }} />
        </div>
      )}
      <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-slate-400">
        <span className="font-semibold uppercase tracking-wide">
          {isUnresolved
            ? 'Insufficient evidence'
            : h.confidence_level === 'officially_verified'
              ? 'Officially verified'
              : h.confidence_level === 'corroborated'
                ? 'Corroborated'
                : 'Suspected'}
        </span>
        {reviewStatus !== 'pending' && <span>· {HYPOTHESIS_REVIEW_STATUS_LABEL[reviewStatus]}</span>}
        {h.model_version && <span>· {h.model_version}</span>}
      </div>
      {h.rationale && <p className="mt-1 text-xs text-slate-500">{h.rationale}</p>}

      {supporting.length > 0 && (
        <div className="mt-1.5">
          <p className="text-[11px] font-semibold text-status-success">Supporting evidence</p>
          <ul className="mt-0.5 list-disc pl-4 text-[11px] text-slate-600">
            {supporting.map((s, i) => (
              <li key={i}>{s}</li>
            ))}
          </ul>
        </div>
      )}
      {contradicting.length > 0 && (
        <div className="mt-1.5">
          <p className="text-[11px] font-semibold text-status-critical">Contradictory evidence</p>
          <ul className="mt-0.5 list-disc pl-4 text-[11px] text-slate-600">
            {contradicting.map((s, i) => (
              <li key={i}>{s}</li>
            ))}
          </ul>
        </div>
      )}
      {missing.length > 0 && (
        <div className="mt-1.5">
          <p className="text-[11px] font-semibold text-slate-500">Missing evidence</p>
          <ul className="mt-0.5 list-disc pl-4 text-[11px] text-slate-400">
            {missing.map((s, i) => (
              <li key={i}>{s}</li>
            ))}
          </ul>
        </div>
      )}
      {h.review_note && <p className="mt-1 text-[11px] italic text-slate-500">Command note: {h.review_note}</p>}

      {!isVerified && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          <button
            type="button"
            disabled={busy || reviewStatus === 'confirmed_corroborated'}
            onClick={() => onReview(h, 'confirmed_corroborated')}
            className="focus-ring rounded border border-slate-200 px-2 py-0.5 text-[11px] font-semibold text-slate-700 hover:bg-white disabled:opacity-50"
          >
            Confirm as corroborated
          </button>
          <button
            type="button"
            disabled={busy || reviewStatus === 'marked_unresolved'}
            onClick={() => onReview(h, 'marked_unresolved')}
            className="focus-ring rounded border border-slate-200 px-2 py-0.5 text-[11px] font-semibold text-slate-700 hover:bg-white disabled:opacity-50"
          >
            Mark unresolved
          </button>
          <button
            type="button"
            disabled={busy || reviewStatus === 'rejected'}
            onClick={() => onReview(h, 'rejected')}
            className="focus-ring rounded border border-status-critical/30 px-2 py-0.5 text-[11px] font-semibold text-status-critical hover:bg-status-critical/10 disabled:opacity-50"
          >
            Reject
          </button>
        </div>
      )}
    </li>
  )
}

export default function SourceAttributionPanel({ detail, onRefresh }: { detail: IncidentDetail; onRefresh: () => void }) {
  const { session } = useAuth()
  const { incident, hypotheses, missions, responsibleAuthority, unavailable } = detail
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const current = hypotheses.filter((h) => h.is_current)
  const ranked = [...current].sort((a, b) => b.probability - a.probability)
  const top = ranked[0] ?? null
  const second = ranked[1] ?? null
  const lastCalculated = current.reduce<string | null>(
    (latest, h) => (latest == null || h.computed_at > latest ? h.computed_at : latest),
    null,
  )
  const dataQualityWarning = top?.data_quality_note ?? null
  const recommendedMission = missions
    .filter((m) => m.status === 'proposed' && m.rationale?.startsWith('Automated attribution:'))
    .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())[0]

  if (unavailable.includes('Source hypotheses')) return null
  if (current.length === 0) return null

  // top?.probability is 1.0 for an 'unresolved' hypothesis (the engine is
  // certain it's unresolved, not confident in a source) - the probability-
  // threshold check alone would read that as "confident enough", which is
  // backwards for exactly the case that most needs an evidence
  // recommendation. Checked explicitly here rather than inside
  // needsMoreAttributionEvidence, which has no other reason to know about
  // this one category's special meaning.
  const needsEvidence = top?.source_category === 'unresolved' || needsMoreAttributionEvidence(top?.probability ?? null, second?.probability ?? null)

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

  const handleReview = (h: SourceHypothesisRow, action: HypothesisReviewAction) => {
    if (!session) return
    let note: string | null = null
    if (action === 'rejected') {
      note = window.prompt('Why is this hypothesis being rejected?')
      if (!note?.trim()) return
    }
    void act(() => reviewSourceHypothesis(h.id, action, session.user.id, note))
  }

  const recalculate = () => {
    void act(() => recalculateSourceAttribution(incident.id, true))
  }

  return (
    <section className="border-t border-slate-100 px-4 py-3">
      <div className="mb-1 flex items-center gap-2">
        <Label dark>Source attribution</Label>
        <span className="rounded bg-status-warning/10 px-1.5 py-0.5 text-[10px] font-bold uppercase text-status-warning">
          {PROBABLE_SOURCE_DISCLAIMER}
        </span>
      </div>

      <dl className="mb-2 grid grid-cols-2 gap-x-3 gap-y-1 text-[11px] sm:grid-cols-3">
        <div>
          <dt className="text-slate-400">Local / regional classification</dt>
          <dd className="font-semibold text-slate-700">
            {incident.classification ? CLASSIFICATION_LABEL[incident.classification] : 'Not yet classified'}
            {isHumanConfirmedClassification(incident.classification_source) && (
              <span className="ml-1 font-normal text-slate-400">(human-confirmed)</span>
            )}
          </dd>
        </div>
        <div>
          <dt className="text-slate-400">Probable responsible authority</dt>
          <dd className="font-semibold text-slate-700">
            {incident.classification === 'regional' ? (
              <span className="font-normal text-slate-400">Not applicable - regional</span>
            ) : responsibleAuthority?.regulating_authority ? (
              <>
                {responsibleAuthority.regulating_authority}
                <span className="ml-1 font-normal text-slate-400">
                  ({Math.round((responsibleAuthority.routing_confidence ?? 0) * 100)}% routing confidence)
                </span>
              </>
            ) : (
              <span className="font-normal text-slate-400">
                {responsibleAuthority?.note ?? 'Unresolved jurisdiction'}
              </span>
            )}
          </dd>
        </div>
        <div>
          <dt className="text-slate-400">Last calculated</dt>
          <dd className="font-semibold text-slate-700">
            {lastCalculated ? new Date(lastCalculated).toLocaleString() : '-'}
          </dd>
        </div>
      </dl>

      {dataQualityWarning &&
        (() => {
          const parsed = parseDataQualityNote(dataQualityWarning)
          return (
            <div className="mb-2 flex items-start gap-2 rounded-lg bg-status-warning/10 px-2.5 py-1.5">
              <UnavailableBadge label="Data-quality note" />
              {parsed ? (
                <div className="text-[11px] text-slate-600">
                  {parsed.available.length > 0 && (
                    <p>
                      <span className="font-semibold">Available:</span> {parsed.available.join(', ')}
                    </p>
                  )}
                  {parsed.missing.length > 0 && (
                    <p>
                      <span className="font-semibold">Missing:</span> {parsed.missing.join(', ')}
                    </p>
                  )}
                </div>
              ) : (
                // Fallback for a note shape this parser doesn't recognize -
                // never hide the raw text, just don't fail to show it.
                <p className="text-[11px] text-slate-600">{dataQualityWarning}</p>
              )}
            </div>
          )
        })()}

      <ul className="space-y-2">
        {ranked.map((h) => (
          <HypothesisCard key={h.id} h={h} onReview={handleReview} busy={busy} />
        ))}
      </ul>

      {needsEvidence && (
        <div className="mt-2 rounded-lg bg-slate-50 px-2.5 py-1.5 text-[11px] text-slate-600">
          <span className="font-semibold">Recommended next evidence:</span>{' '}
          {recommendedMission ? (
            <>
              {recommendedMission.mission_type.replace(/_/g, ' ')} - {cleanMissionRationale(recommendedMission.rationale)?.replace(/\.$/, '')}. Use
              "Request evidence" above to dispatch it.
            </>
          ) : (
            'The leading hypothesis is ambiguous or below the confidence threshold, but no recommendation has been generated yet - recalculate to generate one.'
          )}
        </div>
      )}

      <div className="mt-2">
        <button
          type="button"
          disabled={busy}
          onClick={recalculate}
          className="focus-ring rounded-lg border border-slate-200 px-2.5 py-1 text-[11px] font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-50"
        >
          Request recalculation
        </button>
      </div>

      {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}
    </section>
  )
}
