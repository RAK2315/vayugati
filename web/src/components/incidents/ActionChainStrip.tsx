import { ChevronRight } from 'lucide-react'
import { actionChainStages, type ActionChainInput } from '../../lib/incidentRules'

/** Compact "what stage is this incident at" strip - makes the product's own
 *  Monitor→Detect→Predict→Attribute→Verify→Dispatch→Track→Evaluate loop
 *  concrete for this one incident (a launch-positioning aid: incidents
 *  should read as a tracked action chain, not just a records list). Every
 *  stage's done/pending state is real, derived from data IncidentDetail
 *  already fetched - see actionChainStages in incidentRules.ts. */
export default function ActionChainStrip({ input }: { input: ActionChainInput }) {
  const stages = actionChainStages(input)
  return (
    <div className="flex flex-wrap items-center gap-x-1 gap-y-1.5 border-b border-slate-100 bg-slate-50/60 px-4 py-2">
      {stages.map((stage, i) => (
        <span key={stage.key} className="flex items-center gap-1">
          <span
            className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${
              stage.done ? 'bg-status-success/10 text-status-success' : 'bg-slate-100 text-slate-400'
            }`}
          >
            {stage.label}
          </span>
          {i < stages.length - 1 && <ChevronRight className="h-3 w-3 flex-shrink-0 text-slate-300" aria-hidden />}
        </span>
      ))}
    </div>
  )
}
