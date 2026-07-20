import { Fragment } from 'react'
import { ChevronDown, ChevronRight, Flame } from 'lucide-react'
import { aqiLevel } from '../AqiBadge'
import type { WardForecastSummary, WardSummary } from '../../lib/data'
import {
  confidenceAtPeak,
  hotspotStatus,
  HOTSPOT_STATUS_LABEL,
  type HotspotStatus,
  type TimeWindowHours,
} from '../../lib/overviewRules'
import { Card, CardHeader } from '../ui'

export type Pollutant = 'aqi' | 'pm25'

function timeAgo(ts: string | null): string {
  if (!ts) return '—'
  const h = Math.floor((Date.now() - new Date(ts).getTime()) / 3_600_000)
  return h < 1 ? '<1h' : `${h}h`
}

const STATUS_TONE: Record<HotspotStatus, string> = {
  severe: 'text-status-critical ring-status-critical/40',
  watch: 'text-status-warning ring-status-warning/40',
  stable: 'text-status-success ring-status-success/40',
  no_data: 'text-slate-500 ring-slate-300',
}

const STATUS_DOT: Record<HotspotStatus, string> = {
  severe: 'bg-status-critical',
  watch: 'bg-status-warning',
  stable: 'bg-status-success',
  no_data: 'bg-slate-400',
}

function StatusBadge({ status }: { status: HotspotStatus }) {
  return (
    <span
      className={`inline-flex items-center gap-1 whitespace-nowrap rounded px-1.5 py-0.5 text-[11px] font-semibold ring-1 ring-inset ${STATUS_TONE[status]}`}
    >
      <span className={`h-1.5 w-1.5 rounded-full ${STATUS_DOT[status]}`} aria-hidden />
      {HOTSPOT_STATUS_LABEL[status]}
    </span>
  )
}

function CurrentReadingBadge({ ward, pollutant }: { ward: WardSummary; pollutant: Pollutant }) {
  if (pollutant === 'pm25') {
    return (
      <span className="inline-flex items-center rounded-md bg-slate-100 px-2 py-0.5 text-xs font-bold tabular-nums text-slate-700">
        {ward.pm25 != null ? `${Math.round(ward.pm25)} µg/m³` : '—'}
      </span>
    )
  }
  const level = aqiLevel(ward.aqi)
  return (
    <span
      className="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-bold tabular-nums"
      style={{ backgroundColor: `${level.hex}1f`, color: level.hex }}
    >
      {ward.aqi ?? '—'}
    </span>
  )
}

export default function HotspotsRiskTable({
  wards,
  forecasts,
  pollutant,
  windowHours,
  selectedWardId,
  onSelectWard,
}: {
  wards: WardSummary[]
  forecasts: Map<number, WardForecastSummary>
  pollutant: Pollutant
  windowHours: TimeWindowHours
  selectedWardId: number | null
  onSelectWard: (wardId: number) => void
}) {
  return (
    <Card className="flex min-h-0 flex-col overflow-hidden">
      <CardHeader
        title={
          <span className="flex items-center gap-1.5">
            <Flame className="h-4 w-4 text-status-warning" aria-hidden />
            Hotspots &amp; Forecast Risk
          </span>
        }
        subtitle="Ranked by current reading, city-wide - click a row for detail"
      />
      <div className="overflow-x-auto">
        <table className="w-full min-w-[880px] border-collapse text-sm">
          <thead>
            <tr className="border-b border-slate-200 bg-slate-50 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-400">
              <th className="px-3 py-2 font-semibold">#</th>
              <th className="px-3 py-2 font-semibold">Ward</th>
              <th className="px-3 py-2 font-semibold">Current</th>
              <th className="px-3 py-2 font-semibold">Forecast Peak</th>
              <th className="px-3 py-2 font-semibold">Local Excess</th>
              <th className="px-3 py-2 font-semibold">Likely Source</th>
              <th className="px-3 py-2 font-semibold">Confidence</th>
              <th className="px-3 py-2 font-semibold">Status</th>
              <th className="px-3 py-2 font-semibold">Age</th>
              <th className="w-8 px-2 py-2" />
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {wards.map((ward, i) => {
              const forecast = forecasts.get(ward.id)
              const status = hotspotStatus(
                { hoursToSevere: forecast?.hoursToSevere ?? null, peakExcess: forecast?.peakExcess ?? null, aqi: ward.aqi },
                windowHours,
              )
              const confidence = confidenceAtPeak(forecast)
              const selected = ward.id === selectedWardId
              return (
                <Fragment key={ward.id}>
                  <tr
                    onClick={() => onSelectWard(ward.id)}
                    className={`cursor-pointer transition ${selected ? 'bg-accent-50' : 'hover:bg-slate-50'}`}
                  >
                    <td className="px-3 py-2 tabular-nums text-slate-400">{i + 1}</td>
                    <td className="px-3 py-2 font-medium text-slate-800">{ward.name}</td>
                    <td className="px-3 py-2">
                      <CurrentReadingBadge ward={ward} pollutant={pollutant} />
                    </td>
                    <td className="px-3 py-2 tabular-nums text-slate-600">
                      {forecast?.peakPred != null ? `${Math.round(forecast.peakPred)} µg/m³` : '—'}
                    </td>
                    <td className="px-3 py-2 tabular-nums text-slate-600">
                      {forecast?.peakExcess != null
                        ? `${forecast.peakExcess > 0 ? '+' : ''}${Math.round(forecast.peakExcess)}`
                        : '—'}
                    </td>
                    <td className="px-3 py-2 text-slate-600">{ward.dominant_source ?? 'Unknown'}</td>
                    <td className="px-3 py-2 tabular-nums text-slate-600">
                      {confidence != null ? `${Math.round(confidence * 100)}%` : '—'}
                    </td>
                    <td className="px-3 py-2">
                      <StatusBadge status={status} />
                    </td>
                    <td className="px-3 py-2 tabular-nums text-slate-500">{timeAgo(ward.ts)}</td>
                    <td className="px-2 py-2 text-slate-300">
                      {selected ? <ChevronDown className="h-4 w-4" aria-hidden /> : <ChevronRight className="h-4 w-4" aria-hidden />}
                    </td>
                  </tr>
                  {selected && (
                    <tr className="bg-accent-50/60">
                      <td colSpan={10} className="px-3 py-3">
                        <div className="flex flex-wrap gap-x-8 gap-y-2 text-xs text-slate-600">
                          <span>
                            <span className="font-semibold text-slate-500">PM2.5 now:</span>{' '}
                            {ward.pm25 != null ? `${Math.round(ward.pm25)} µg/m³` : 'no reading'}
                          </span>
                          <span>
                            <span className="font-semibold text-slate-500">Predicted severe in:</span>{' '}
                            {forecast?.hoursToSevere != null ? `${forecast.hoursToSevere}h` : 'not predicted'}
                          </span>
                          <span>
                            <span className="font-semibold text-slate-500">Last reading:</span>{' '}
                            {ward.ts ? new Date(ward.ts).toLocaleString() : 'unavailable'}
                          </span>
                        </div>
                      </td>
                    </tr>
                  )}
                </Fragment>
              )
            })}
          </tbody>
        </table>
      </div>
      {wards.length === 0 && <p className="px-4 py-6 text-center text-sm text-slate-400">No ward data available.</p>}
      <p className="border-t border-slate-100 px-4 py-2 text-[11px] text-slate-400">
        {pollutant === 'aqi'
          ? 'Current reading is colour-coded on the India NAQI scale.'
          : 'PM2.5 shown in µg/m³ — colour bands apply to the AQI view only.'}
      </p>
    </Card>
  )
}
