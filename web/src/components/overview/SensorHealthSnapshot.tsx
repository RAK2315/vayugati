import { Radio } from 'lucide-react'
import { Link } from 'react-router-dom'
import type { StationHealthRollup } from '../../lib/overviewRules'
import { Card, CardHeader, Stat } from '../ui'

/** Read-only summary of station freshness - per-station activate/deactivate
 *  actions stay on /sensors (SensorsView.tsx), not duplicated here. */
export default function SensorHealthSnapshot({ rollup }: { rollup: StationHealthRollup }) {
  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <Radio className="h-4 w-4 text-accent-600" aria-hidden />
            Sensor Health
          </span>
        }
        right={
          <Link to="/sensors" className="focus-ring rounded text-xs font-semibold text-accent-600 hover:text-accent-700">
            View all →
          </Link>
        }
      />
      <div className="space-y-3.5 px-4 py-3.5">
        <div className="grid grid-cols-3 gap-2">
          <Stat value={rollup.active - rollup.stale} label="Fresh" accent="text-status-success" />
          <Stat value={rollup.stale} label="Stale" accent="text-status-warning" />
          <Stat value={rollup.inactive} label="Inactive" accent="text-slate-500" />
        </div>
        {rollup.topStale.length > 0 && (
          <div>
            <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-slate-400">Stalest active</p>
            <ul className="space-y-1">
              {rollup.topStale.map((s) => (
                <li key={s.name} className="flex items-center justify-between gap-2 text-xs">
                  <span className="truncate text-slate-600">
                    {s.name}
                    {s.wardName ? ` · ${s.wardName}` : ''}
                  </span>
                  <span className="flex-shrink-0 tabular-nums font-semibold text-status-warning">
                    {s.ageMinutes != null ? `${Math.round(s.ageMinutes / 60)}h` : '—'}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </Card>
  )
}
