import { ChevronLeft } from 'lucide-react'
import { allowedTaskKinds, CONFIDENCE_LABEL, currentReading, type Severity } from '../../lib/incidentRules'
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

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-[10px] font-semibold uppercase tracking-wide text-slate-400">{label}</dt>
      <dd className="mt-0.5 font-semibold text-slate-800">{children}</dd>
    </div>
  )
}

/** The right pane's document header: title, status, and the facts grid the
 *  brief requires (location, pollutant, current reading, local excess,
 *  severity, evidence level, assigned authority, classification, permitted
 *  next actions). Purely presentational - no data fetching, no mutations. */
export default function IncidentStatusHeader({
  incident,
  wardAqi,
  onBack,
}: {
  incident: Incident
  wardAqi: number | null
  onBack?: () => void
}) {
  const severity = (incident.severity ?? null) as Severity | null
  const kinds = allowedTaskKinds(incident.source_confidence)
  const reading = currentReading(wardAqi, incident.local_excess)

  return (
    <div className="flex-shrink-0 border-b border-slate-200 bg-white px-4 py-3">
      {onBack && (
        <button
          type="button"
          onClick={onBack}
          className="focus-ring mb-2 flex items-center gap-1 text-xs font-semibold text-accent-700 lg:hidden"
        >
          <ChevronLeft className="h-3.5 w-3.5" strokeWidth={2.5} aria-hidden />
          Back to queue
        </button>
      )}
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <h1 className="text-base font-semibold text-slate-900">{incident.summary ?? `Incident #${incident.id}`}</h1>
          <p className="mt-0.5 text-xs text-slate-400">
            #{incident.id} · detected {new Date(incident.detected_at).toLocaleString()} · via{' '}
            {incident.detection_method.replace(/_/g, ' ')}
          </p>
        </div>
        <span className="rounded-lg bg-slate-100 px-2 py-1 text-xs font-semibold capitalize text-slate-700">
          {incident.status.replace(/_/g, ' ')}
        </span>
      </div>

      <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2.5 text-xs sm:grid-cols-4">
        <Fact label="Location">
          {incident.ward_name ?? 'Unknown ward'}
          {incident.lat != null && incident.lng != null && (
            <span className="ml-1 font-normal text-slate-400">
              {incident.lat.toFixed(3)}, {incident.lng.toFixed(3)}
            </span>
          )}
        </Fact>
        <Fact label="Pollutant">
          <span className="uppercase">{incident.primary_pollutant ?? '-'}</span>
        </Fact>
        <Fact label="Current reading">
          {reading.kind === 'live' ? (
            <span className="tabular-nums">AQI {reading.aqi}</span>
          ) : reading.kind === 'forecast' ? (
            <span className="font-normal text-slate-400" title="No live station reading - showing the forecast excess instead">
              No live reading
            </span>
          ) : (
            <span className="font-normal text-slate-400">Unavailable</span>
          )}
        </Fact>
        <Fact label="Local excess">
          {incident.local_excess != null ? (
            <span className="tabular-nums">+{Math.round(incident.local_excess)} µg/m³</span>
          ) : (
            <span className="font-normal text-slate-400" title="No forecast available for this ward">
              Unavailable
            </span>
          )}
        </Fact>
        <Fact label="Severity">
          {severity ? (
            <span
              className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ring-1 ring-inset ${SEVERITY_TONE[severity]}`}
            >
              <span className="h-1.5 w-1.5 rounded-full bg-current" aria-hidden />
              {severity}
            </span>
          ) : (
            <span className="font-normal text-slate-400">Unavailable</span>
          )}
        </Fact>
        <Fact label="Evidence level">
          <span
            className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ring-1 ring-inset ${
              EVIDENCE_TONE[incident.source_confidence] ?? 'text-slate-500 ring-slate-300'
            }`}
          >
            {CONFIDENCE_LABEL[incident.source_confidence]}
          </span>
        </Fact>
        <Fact label="Assigned authority">
          {incident.assigned_authority ?? <span className="font-normal text-slate-400">Not routed yet</span>}
        </Fact>
        <Fact label="Classification">
          <span className="capitalize">
            {incident.classification ?? <span className="font-normal text-slate-400">Not classified</span>}
          </span>
        </Fact>
        <Fact label="Permitted next actions">{kinds.join(', ')}</Fact>
      </dl>
    </div>
  )
}
