import { ClipboardCheck } from 'lucide-react'

export default function EmptyDispatchState({ filtered = false }: { filtered?: boolean }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-4 py-14 text-center">
      <ClipboardCheck className="h-6 w-6 text-slate-300" strokeWidth={1.75} aria-hidden />
      <p className="max-w-sm text-sm text-slate-500">
        {filtered
          ? 'No active dispatches match this filter. Routed enforcement actions will appear here once incidents are assigned to an authority.'
          : 'No active dispatches right now. Routed enforcement actions will appear here once incidents are assigned to an authority.'}
      </p>
    </div>
  )
}
