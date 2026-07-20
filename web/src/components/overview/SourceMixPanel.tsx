import { Layers } from 'lucide-react'
import type { SourceMixEntry } from '../../lib/overviewRules'
import { Card, CardHeader } from '../ui'

/** Answers "what source is likely responsible" city-wide - a tally of
 *  wards[].dominant_source, not a new attribution model. */
export default function SourceMixPanel({ mix }: { mix: SourceMixEntry[] }) {
  const total = mix.reduce((s, m) => s + m.count, 0)
  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <Layers className="h-4 w-4 text-accent-600" aria-hidden />
            Source Mix
          </span>
        }
        subtitle="Dominant source by ward, city-wide"
      />
      {mix.length === 0 ? (
        <p className="px-4 py-6 text-center text-sm text-slate-400">No source data available.</p>
      ) : (
        <ul className="space-y-2.5 px-4 py-3.5">
          {mix.map((m) => (
            <li key={m.source}>
              <div className="mb-1 flex items-baseline justify-between gap-2 text-xs">
                <span className="truncate font-medium text-slate-700">{m.source}</span>
                <span className="flex-shrink-0 tabular-nums text-slate-400">{m.count}</span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-accent-100">
                <div
                  className="h-full rounded-full bg-accent-500"
                  style={{ width: `${total > 0 ? (m.count / total) * 100 : 0}%` }}
                />
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
