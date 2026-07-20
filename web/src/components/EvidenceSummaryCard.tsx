import { FileCheck } from 'lucide-react'
import { CONFIDENCE_LABEL, describeMatchingRule } from '../lib/incidentRules'
import type { IncidentDetail } from '../lib/incidents'

function Tile({ value, label }: { value: React.ReactNode; label: string }) {
  return (
    <div className="rounded-lg bg-slate-50 px-3 py-2 text-center">
      <p className="text-sm font-bold text-slate-800">{value}</p>
      <p className="mt-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-400">{label}</p>
    </div>
  )
}

/**
 * Compact summary opening the Evidence tab — extracted from
 * IncidentEvidencePanel's former inline "Evidence quality" section, same
 * data, same rule (evidence quality is stated as counts of what actually
 * exists, never scored into a fabricated single number).
 */
export default function EvidenceSummaryCard({ detail }: { detail: IncidentDetail }) {
  const { incident, reports, evidence, sensor } = detail
  const independentReporters = new Set(reports.map((r) => r.reporter_id).filter(Boolean)).size
  const hasFieldEvidence = evidence.some((e) => e.evidence_type === 'field_inspection' || e.evidence_type === 'photo')

  return (
    <section className="border-t border-slate-100 px-4 py-3 first:border-t-0">
      <div className="mb-2 flex items-center gap-1.5">
        <FileCheck className="h-3.5 w-3.5 text-accent-600" strokeWidth={2} aria-hidden />
        <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Evidence quality</p>
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Tile value={CONFIDENCE_LABEL[incident.source_confidence]} label="Evidence level" />
        <Tile value={independentReporters || '-'} label="Independent reporters" />
        <Tile value={hasFieldEvidence ? 'Yes' : 'None yet'} label="Officer evidence" />
        <Tile value={sensor ? 'Covers this ward' : 'No station'} label="Monitoring station" />
      </div>
      <p className="mt-2 text-[11px] leading-relaxed text-slate-400">{describeMatchingRule()}</p>
    </section>
  )
}
