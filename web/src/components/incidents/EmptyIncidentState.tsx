import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'

/** Compact, serious empty state for the Incidents workspace - lucide icon in
 *  place of an emoji glyph, matching the rest of the redesigned page. Distinct
 *  from the shared EmptyState (ui.tsx), which other not-yet-redesigned pages
 *  keep using with string glyphs. */
export default function EmptyIncidentState({
  icon: Icon,
  title,
  children,
}: {
  icon: LucideIcon
  title?: string
  children: ReactNode
}) {
  return (
    <div className="flex flex-col items-center justify-center gap-1.5 px-4 py-8 text-center">
      <Icon className="h-5 w-5 text-slate-300" strokeWidth={1.75} aria-hidden />
      {title && <p className="text-sm font-semibold text-slate-600">{title}</p>}
      <p className="max-w-sm text-xs text-slate-400">{children}</p>
    </div>
  )
}
