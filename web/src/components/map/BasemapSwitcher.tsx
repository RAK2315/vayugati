import { useState } from 'react'
import { Check, ChevronUp, Layers, Lock } from 'lucide-react'
import { BASEMAP_OPTIONS, isBasemapAvailable, maptilerKey, type BasemapMode } from '../../lib/basemaps'

/** Floating basemap switcher (bottom-left over the map canvas, a standard
 *  GIS-console placement). Every mode is always visible; unavailable ones
 *  (no VITE_MAPTILER_KEY configured) are shown disabled with the reason,
 *  never silently hidden or faked. Compact popover - one line per mode, one
 *  shared helper line instead of per-row explanations. */
export default function BasemapSwitcher({ mode, onChange }: { mode: BasemapMode; onChange: (mode: BasemapMode) => void }) {
  const [open, setOpen] = useState(false)
  const current = BASEMAP_OPTIONS.find((o) => o.mode === mode) ?? BASEMAP_OPTIONS[0]
  const hasKey = maptilerKey() != null

  return (
    <div className="absolute bottom-3 left-3 z-10">
      {open && (
        <div className="mb-1.5 w-44 rounded-lg border border-slate-200 bg-white p-1 shadow-card-lg">
          {BASEMAP_OPTIONS.map((option) => {
            const available = isBasemapAvailable(option.mode)
            const selected = option.mode === mode
            return (
              <button
                key={option.mode}
                type="button"
                disabled={!available}
                title={available ? option.description : 'Add VITE_MAPTILER_KEY to enable this basemap'}
                onClick={() => {
                  onChange(option.mode)
                  setOpen(false)
                }}
                className={`focus-ring flex w-full items-center justify-between gap-1.5 rounded-md px-2 py-1 text-left text-xs transition ${
                  selected ? 'bg-accent-50 font-semibold text-accent-800' : available ? 'text-slate-700 hover:bg-slate-50' : 'cursor-not-allowed text-slate-300'
                }`}
              >
                <span className="truncate">{option.label}</span>
                {selected ? (
                  <Check className="h-3 w-3 flex-shrink-0" strokeWidth={2.5} aria-hidden />
                ) : !available ? (
                  <Lock className="h-2.5 w-2.5 flex-shrink-0" strokeWidth={2} aria-hidden />
                ) : null}
              </button>
            )
          })}
          {!hasKey && (
            <p className="mt-0.5 border-t border-slate-100 px-2 pt-1 text-[10px] leading-snug text-slate-400">
              Add <code className="rounded bg-slate-100 px-0.5">VITE_MAPTILER_KEY</code> to enable premium basemaps.
            </p>
          )}
        </div>
      )}
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="focus-ring flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-2 py-1 text-[11px] font-semibold text-slate-700 shadow-card hover:bg-slate-50"
      >
        <Layers className="h-3 w-3 text-slate-400" strokeWidth={2} aria-hidden />
        {current.label}
        <ChevronUp className={`h-2.5 w-2.5 text-slate-400 transition-transform ${open ? '' : 'rotate-180'}`} aria-hidden />
      </button>
    </div>
  )
}
