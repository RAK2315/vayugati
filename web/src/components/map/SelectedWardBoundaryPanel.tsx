import { MapPin, X } from 'lucide-react'

type JurisdictionType = 'mcd' | 'ndmc' | 'cantonment'

const JURISDICTION_LABEL: Record<JurisdictionType, string> = {
  mcd: 'Ward boundary',
  ndmc: 'Non-MCD jurisdiction',
  cantonment: 'Non-MCD jurisdiction',
}

const JURISDICTION_NOTE: Record<JurisdictionType, string> = {
  mcd: 'This is a municipal boundary reference (Phase 2 import) - it has no assigned monitoring station, AQI reading, or incident history of its own. The 13 hotspot wards with live data are shown as pulsing markers, not polygons.',
  ndmc: 'New Delhi Municipal Council (NDMC) - a separate civic body from MCD, so it has no MCD ward number. Shown here for map completeness (OpenStreetMap boundary import) - it has no assigned monitoring station, AQI reading, or incident history in this app.',
  cantonment: 'Delhi Cantonment Board - administered by the Ministry of Defence, a separate civic body from MCD, so it has no MCD ward number. Shown here for map completeness (OpenStreetMap boundary import) - it has no assigned monitoring station, AQI reading, or incident history in this app.',
}

/**
 * Shown when a clicked boundary polygon has no monitoring data of its own -
 * true for all 250 Phase 2 municipal-boundary wards (is_hotspot = false, no
 * station/AQI/forecast history) and for the two non-MCD jurisdictions
 * (NDMC, Delhi Cantonment) imported from OpenStreetMap to fill the two real
 * gaps those areas left in the ward mesh. Deliberately minimal: name +
 * ward number (MCD only) + an honest note, no fabricated readings. The 13
 * monitored hotspot wards still use the full SelectedWardPanel via their
 * marker, unaffected.
 */
export default function SelectedWardBoundaryPanel({
  name,
  wardNumber,
  jurisdictionType,
  onClose,
}: {
  name: string
  wardNumber: number | null
  jurisdictionType: JurisdictionType
  onClose: () => void
}) {
  return (
    <div className="p-4">
      <div className="mb-3 flex items-start justify-between gap-2">
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-wide text-slate-400">{JURISDICTION_LABEL[jurisdictionType]}</p>
          <h2 className="text-sm font-semibold text-slate-800">{name}</h2>
        </div>
        <button type="button" onClick={onClose} className="focus-ring rounded p-1 text-slate-400 hover:bg-slate-100">
          <X className="h-3.5 w-3.5" aria-hidden />
        </button>
      </div>

      {jurisdictionType === 'mcd' && (
        <dl className="text-xs">
          <div>
            <dt className="text-slate-400">Ward number</dt>
            <dd className="font-semibold tabular-nums text-slate-800">{wardNumber ?? 'Unknown'}</dd>
          </div>
        </dl>
      )}

      <div className="mt-3 flex items-start gap-1.5 rounded-lg bg-slate-50 px-2.5 py-2 text-[11px] text-slate-500">
        <MapPin className="mt-0.5 h-3 w-3 flex-shrink-0 text-slate-400" strokeWidth={2} aria-hidden />
        <span>{JURISDICTION_NOTE[jurisdictionType]}</span>
      </div>
    </div>
  )
}
