import { useState } from 'react'
import { ChevronDown, ChevronRight, ListTree } from 'lucide-react'
import { sourceCategoryLabel, type Severity, type SourceCategory } from '../../lib/incidentRules'
import { SEVERITY_HEX, SOURCE_CATEGORY_HEX } from '../../lib/mapMarkers'

const SEVERITY_ORDER: Severity[] = ['severe', 'high', 'moderate', 'low']
const PHYSICAL_SOURCES: SourceCategory[] = ['vehicular', 'industrial', 'construction_dust', 'road_dust', 'open_burning', 'waste']

function Swatch({ color, shape = 'circle' }: { color: string; shape?: 'circle' | 'square' | 'diamond' | 'ring' }) {
  const radius = shape === 'circle' ? '50%' : shape === 'square' ? '3px' : shape === 'diamond' ? '2px' : '50%'
  return (
    <span
      className="inline-block h-2.5 w-2.5 flex-shrink-0"
      style={{
        borderRadius: radius,
        background: shape === 'ring' ? 'transparent' : color,
        border: shape === 'ring' ? `1.5px dashed ${color}` : 'none',
        transform: shape === 'diamond' ? 'rotate(45deg)' : undefined,
      }}
      aria-hidden
    />
  )
}

/** Floating legend, paired with MapLayerControl. Collapsed by default -
 *  reference material, looked up less often than the layer toggles, so it
 *  shouldn't cost map real estate until asked for. Only shows keys for
 *  layers that can genuinely appear - no invented categories. */
export default function MapLegend({ sourceAttributionOn }: { sourceAttributionOn: boolean }) {
  const [open, setOpen] = useState(false)

  return (
    <div className="w-48 rounded-lg border border-slate-200 bg-white shadow-card">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="focus-ring flex w-full items-center gap-1.5 px-1.5 py-1"
      >
        <ListTree className="h-3 w-3 text-accent-600" strokeWidth={2} aria-hidden />
        <p className="flex-1 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">Legend</p>
        {open ? (
          <ChevronDown className="h-3 w-3 text-slate-400" aria-hidden />
        ) : (
          <ChevronRight className="h-3 w-3 text-slate-400" aria-hidden />
        )}
      </button>

      {open && (
        <div className="px-1.5 pb-1.5">
          <p className="text-[9px] font-semibold uppercase tracking-wide text-slate-400">Severity</p>
          <ul className="mt-0.5 space-y-0.5">
            {SEVERITY_ORDER.map((s) => (
              <li key={s} className="flex items-center gap-1.5 text-[10px] capitalize text-slate-600">
                <Swatch color={SEVERITY_HEX[s]} shape="diamond" />
                {s}
              </li>
            ))}
          </ul>

          <p className="mt-1.5 text-[9px] font-semibold uppercase tracking-wide text-slate-400">Marker types</p>
          <ul className="mt-0.5 space-y-0.5 text-[10px] text-slate-600">
            <li className="flex items-center gap-1.5">
              <Swatch color="#64748B" shape="circle" />
              Ward
            </li>
            <li className="flex items-center gap-1.5">
              <Swatch color="#64748B" shape="square" />
              Station
            </li>
            <li className="flex items-center gap-1.5">
              <Swatch color="#64748B" shape="diamond" />
              Incident
            </li>
            <li className="flex items-center gap-1.5">
              <Swatch color="#0F6CBD" shape="ring" />
              Citizen report
            </li>
          </ul>

          <p className="mt-1.5 text-[9px] font-semibold uppercase tracking-wide text-slate-400">Sensor state</p>
          <ul className="mt-0.5 space-y-0.5 text-[10px] text-slate-600">
            <li className="flex items-center gap-1.5">
              <Swatch color="#64748B" shape="square" />
              Fresh
            </li>
            <li className="flex items-center gap-1.5">
              <Swatch color="#D97706" shape="ring" />
              Stale
            </li>
          </ul>

          {sourceAttributionOn && (
            <>
              <p className="mt-1.5 text-[9px] font-semibold uppercase tracking-wide text-slate-400">Leading source</p>
              <ul className="mt-0.5 space-y-0.5">
                {PHYSICAL_SOURCES.map((c) => (
                  <li key={c} className="flex items-center gap-1.5 text-[10px] text-slate-600">
                    <Swatch color={SOURCE_CATEGORY_HEX[c]} />
                    {sourceCategoryLabel(c)}
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
      )}
    </div>
  )
}
