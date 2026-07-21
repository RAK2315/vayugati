import { AlertTriangle } from 'lucide-react'
import {
  CONFIDENCE_LABEL,
  currentReading,
  ESCALATION_SLA_HOURS,
  isEscalated,
  sourceCategoryLabel,
  type Severity,
  type SourceCategory,
} from '../../lib/incidentRules'
import type { Incident } from '../../lib/incidents'

const SEVERITY_TONE: Record<Severity, string> = {
  severe: 'text-status-critical ring-status-critical/40',
  high: 'text-status-warning ring-status-warning/40',
  moderate: 'text-status-warning ring-status-warning/30',
  low: 'text-slate-500 ring-slate-300',
}

const EVIDENCE_TONE: Record<string, string> = {
  suspected: 'text-slate-500 ring-slate-300',
  corroborated: 'text-accent-700 ring-accent-300',
  officially_verified: 'text-status-success ring-status-success/40',
}

function ageHours(ts: string): number {
  return (Date.now() - new Date(ts).getTime()) / 3_600_000
}

function fmtAge(ts: string): string {
  const h = ageHours(ts)
  if (h < 1) return '<1h'
  if (h < 48) return `${Math.floor(h)}h`
  return `${Math.floor(h / 24)}d`
}

function ReadingBadge({ wardAqi, localExcess }: { wardAqi: number | null; localExcess: number | null }) {
  const reading = currentReading(wardAqi, localExcess)
  if (reading.kind === 'live') {
    return <span className="tabular-nums text-slate-700">AQI {reading.aqi}</span>
  }
  if (reading.kind === 'forecast') {
    return <span className="tabular-nums text-slate-500">+{Math.round(reading.excess)} µg/m³ excess</span>
  }
  return <span className="text-slate-300">No reading</span>
}

export default function IncidentListItem({
  incident,
  wardAqi,
  leadingSource,
  selected,
  onSelect,
}: {
  incident: Incident
  wardAqi: number | null
  leadingSource: SourceCategory | null
  selected: boolean
  onSelect: () => void
}) {
  const severity = (incident.severity ?? null) as Severity | null
  const escalated = isEscalated(incident)

  return (
    <li>
      <button
        type="button"
        onClick={onSelect}
        aria-current={selected ? 'true' : undefined}
        className={`focus-ring w-full border-l-2 px-3 py-2.5 text-left transition ${
          selected ? 'border-accent-600 bg-accent-50' : 'border-transparent hover:bg-slate-50'
        }`}
      >
        <div className="flex items-center gap-1.5">
          {severity ? (
            <span
              className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ring-1 ring-inset ${SEVERITY_TONE[severity]}`}
            >
              <span className="h-1.5 w-1.5 rounded-full bg-current" aria-hidden />
              {severity}
            </span>
          ) : (
            <span
              className="rounded px-1.5 py-0.5 text-[10px] font-bold uppercase text-slate-400 ring-1 ring-inset ring-slate-200"
              title="No forecast for this ward, so severity could not be derived"
            >
              Severity unavailable
            </span>
          )}
          {escalated && (
            <span
              className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase text-status-critical ring-1 ring-inset ring-status-critical/40"
              title={`Escalated by rule: open longer than ${ESCALATION_SLA_HOURS}h with nothing dispatched - independent of severity`}
            >
              <AlertTriangle className="h-2.5 w-2.5" strokeWidth={2.5} aria-hidden />
              Escalated by rule
            </span>
          )}
          <span className="ml-auto text-[11px] tabular-nums text-slate-400">{fmtAge(incident.detected_at)}</span>
        </div>

        <p className="mt-1 line-clamp-2 text-sm font-medium text-slate-800">
          {incident.summary ?? `Incident #${incident.id}`}
        </p>

        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-slate-400">
          <span>#{incident.id}</span>
          {incident.ward_name && <span>· {incident.ward_name}</span>}
          {incident.primary_pollutant && <span className="uppercase">· {incident.primary_pollutant}</span>}
          <span>· {sourceCategoryLabel(leadingSource)}</span>
        </div>

        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px]">
          <ReadingBadge wardAqi={wardAqi} localExcess={incident.local_excess} />
          <span
            className={`rounded px-1 font-semibold ring-1 ring-inset ${EVIDENCE_TONE[incident.source_confidence] ?? 'text-slate-500 ring-slate-300'}`}
          >
            {CONFIDENCE_LABEL[incident.source_confidence]}
          </span>
          <span className="capitalize text-slate-400">{incident.status.replace(/_/g, ' ')}</span>
        </div>
      </button>
    </li>
  )
}
