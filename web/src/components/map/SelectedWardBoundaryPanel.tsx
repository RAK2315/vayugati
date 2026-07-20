import { MapPin, X } from 'lucide-react'

/**
 * Shown when a clicked ward polygon has no monitoring data of its own -
 * true for all 250 Phase 2 municipal-boundary wards (is_hotspot = false,
 * no station/AQI/forecast history). Deliberately minimal: name + ward
 * number only, no fabricated readings. The 13 monitored hotspot wards
 * still use the full SelectedWardPanel via their marker, unaffected.
 */
export default function SelectedWardBoundaryPanel({
  name,
  wardNumber,
  onClose,
}: {
  name: string
  wardNumber: number | null
  onClose: () => void
}) {
  return (
    <div className="p-4">
      <div className="mb-3 flex items-start justify-between gap-2">
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-wide text-slate-400">Ward boundary</p>
          <h2 className="text-sm font-semibold text-slate-800">{name}</h2>
        </div>
        <button type="button" onClick={onClose} className="focus-ring rounded p-1 text-slate-400 hover:bg-slate-100">
          <X className="h-3.5 w-3.5" aria-hidden />
        </button>
      </div>

      <dl className="text-xs">
        <div>
          <dt className="text-slate-400">Ward number</dt>
          <dd className="font-semibold tabular-nums text-slate-800">{wardNumber ?? 'Unknown'}</dd>
        </div>
      </dl>

      <div className="mt-3 flex items-start gap-1.5 rounded-lg bg-slate-50 px-2.5 py-2 text-[11px] text-slate-500">
        <MapPin className="mt-0.5 h-3 w-3 flex-shrink-0 text-slate-400" strokeWidth={2} aria-hidden />
        <span>
          This is a municipal boundary reference (Phase 2 import) - it has no assigned monitoring station, AQI reading, or
          incident history of its own. The 13 hotspot wards with live data are shown as pulsing markers, not polygons.
        </span>
      </div>
    </div>
  )
}
