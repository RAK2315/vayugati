import { CheckCircle2, ClipboardList, TriangleAlert } from 'lucide-react'
import { buildDataReadinessChecklist, type DataReadinessInput } from '../../lib/readinessRules'
import { Card, CardHeader, Skeleton } from '../ui'

/** Known, honest structural gaps - documented in docs/data/delhi-station-
 *  reconciliation.md and delhi-safe-station-import-report.md, not derived
 *  from live data (there's no "known_gaps" table). Static because these are
 *  real findings from completed audits, not a guess - update this list only
 *  alongside a new audit that changes one of these facts. */
const KNOWN_GAPS = [
  'ITO and both Pusa stations (DPCC + IMD) are verified live on OpenAQ but pending manual ward-boundary review before import.',
  'Pitampura has no matching OpenAQ location - unavailable, not merely stale.',
  'Mayapuri has no official CPCB/DPCC/IMD station - shown as proxy/no-data on the map, nothing fabricated in its place.',
  'Satellite fire detection (FIRMS), OpenStreetMap source layers, and a dedicated wind/weather map view are not part of this launch (Open-Meteo forecast weather is already used internally as a model input, but has no user-facing layer yet).',
]

export default function DataReadinessCard({
  input,
  loading,
}: {
  input: DataReadinessInput | null
  loading: boolean
}) {
  const items = input ? buildDataReadinessChecklist(input) : []

  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <ClipboardList className="h-4 w-4 text-accent-600" aria-hidden />
            Delhi Data Readiness
          </span>
        }
        subtitle="Launch status snapshot - the data foundation every page depends on"
      />
      {loading || !input ? (
        <div className="space-y-2 p-4">
          <Skeleton className="h-6 w-full" />
          <Skeleton className="h-6 w-full" />
          <Skeleton className="h-6 w-full" />
        </div>
      ) : (
        <div className="p-4">
          <ul className="space-y-1.5">
            {items.map((item) => (
              <li key={item.key} className="flex items-start gap-2 text-xs">
                {item.status === 'ok' ? (
                  <CheckCircle2 className="mt-0.5 h-3.5 w-3.5 flex-shrink-0 text-status-success" aria-hidden />
                ) : (
                  <TriangleAlert className="mt-0.5 h-3.5 w-3.5 flex-shrink-0 text-status-warning" aria-hidden />
                )}
                <span>
                  <span className="font-semibold text-slate-800">{item.label}:</span>{' '}
                  <span className="text-slate-600">{item.detail}</span>
                </span>
              </li>
            ))}
          </ul>

          <p className="mb-1.5 mt-3 text-[10px] font-semibold uppercase tracking-wide text-slate-400">
            Remaining known gaps
          </p>
          <ul className="space-y-1.5">
            {KNOWN_GAPS.map((gap) => (
              <li key={gap} className="flex items-start gap-2 text-[11px] text-slate-500">
                <span className="mt-1 h-1 w-1 flex-shrink-0 rounded-full bg-slate-300" aria-hidden />
                <span>{gap}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </Card>
  )
}
