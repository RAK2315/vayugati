import { ChevronRight, type LucideIcon } from 'lucide-react'

export interface ActionLoopStage {
  key: string
  label: string
  icon: LucideIcon
  /** A live count already fetched elsewhere on this page, formatted by the
   *  caller - or '—' when this city-wide view has no live count for that
   *  stage yet (no new query added to get one). */
  value: string
}

/** The product's own Monitor→Detect→Predict→Attribute→Verify→Dispatch→
 *  Evaluate loop, made concrete city-wide (the incident-level equivalent is
 *  ActionChainStrip on the Incidents page) - a compact strip, not a new
 *  panel, so Overview stays a dashboard-plus-context rather than growing a
 *  second dashboard. */
export default function ActionLoopStrip({ stages }: { stages: ActionLoopStage[] }) {
  return (
    <div
      role="list"
      aria-label="Vayu Gati action loop"
      className="flex flex-wrap items-center gap-x-1 gap-y-2 rounded-xl border border-slate-200 bg-white px-3 py-2.5 shadow-card"
    >
      {stages.map((stage, i) => {
        const Icon = stage.icon
        return (
          <div key={stage.key} role="listitem" className="flex items-center gap-1">
            <div className="flex items-center gap-1.5 rounded-lg bg-slate-50 px-2.5 py-1.5">
              <Icon className="h-3.5 w-3.5 text-accent-600" aria-hidden />
              <span className="text-xs font-semibold text-slate-700">{stage.label}</span>
              <span className="rounded bg-white px-1.5 py-0.5 text-xs font-bold tabular-nums text-slate-900 ring-1 ring-inset ring-slate-200">
                {stage.value}
              </span>
            </div>
            {i < stages.length - 1 && (
              <ChevronRight className="h-3.5 w-3.5 flex-shrink-0 text-slate-300" aria-hidden />
            )}
          </div>
        )
      })}
    </div>
  )
}
