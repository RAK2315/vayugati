import { Minus, Plus, Users } from 'lucide-react'
import type { Allocation } from '../../lib/data'
import { Card, CardHeader } from '../ui'

/** Answers "what action should the commander take next" in terms of field
 *  crews - same allocateTeams() LP-weighted split as before, restyled. */
export default function TeamAllocationPanel({
  teams,
  onTeamsChange,
  allocation,
}: {
  teams: number
  onTeamsChange: (teams: number) => void
  allocation: Allocation[]
}) {
  const active = allocation.filter((a) => a.teams > 0)

  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <Users className="h-4 w-4 text-accent-600" aria-hidden />
            Team Allocation
          </span>
        }
        right={
          <div className="flex items-center gap-1 rounded-lg border border-slate-200 px-1 py-1">
            <button
              type="button"
              onClick={() => onTeamsChange(Math.max(1, teams - 1))}
              aria-label="Fewer teams"
              className="focus-ring rounded p-1 text-slate-500 hover:bg-slate-100"
            >
              <Minus className="h-3.5 w-3.5" aria-hidden />
            </button>
            <span className="w-6 text-center text-sm font-semibold tabular-nums text-slate-800">{teams}</span>
            <button
              type="button"
              onClick={() => onTeamsChange(teams + 1)}
              aria-label="More teams"
              className="focus-ring rounded p-1 text-slate-500 hover:bg-slate-100"
            >
              <Plus className="h-3.5 w-3.5" aria-hidden />
            </button>
          </div>
        }
      />
      {active.length === 0 ? (
        <p className="px-4 py-6 text-center text-sm text-slate-400">No local excess to weight allocation against.</p>
      ) : (
        <ul className="flex flex-wrap gap-1.5 px-4 py-3.5">
          {active.map((a) => (
            <li
              key={a.wardId}
              className="inline-flex items-center gap-1.5 rounded-md border border-slate-200 bg-slate-50 px-2 py-1 text-xs"
            >
              <span className="font-medium text-slate-700">{a.wardName}</span>
              <span className="rounded bg-accent-100 px-1.5 py-0.5 font-bold tabular-nums text-accent-700">
                {a.teams}
              </span>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
