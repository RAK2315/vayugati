import { useEffect, useState } from 'react'
import { aqiLevel } from '../components/AqiBadge'
import AppShell from '../components/AppShell'
import MapView, { type WardMarker } from '../components/MapView'
import { Skeleton } from '../components/ui'
import {
  allocateTeams,
  fetchAllForecasts,
  fetchAllWardsAqi,
  fetchGatiMetrics,
  type Allocation,
  type GatiMetrics,
  type WardForecastSummary,
  type WardSummary,
} from '../lib/data'

function timeAgo(ts: string | null): string {
  if (!ts) return '—'
  const h = Math.floor((Date.now() - new Date(ts).getTime()) / 3_600_000)
  return h < 1 ? '<1h' : `${h}h`
}

function Panel({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <div className={`rounded-2xl bg-slate-900 ring-1 ring-white/5 ${className}`}>{children}</div>
}

function AqiPill({ aqi }: { aqi: number | null }) {
  const level = aqiLevel(aqi)
  return (
    <span
      className="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-bold tabular-nums"
      style={{ backgroundColor: `${level.hex}26`, color: level.hex }}
    >
      {aqi ?? '—'}
    </span>
  )
}

export default function CommandView() {
  const [wards, setWards] = useState<WardSummary[]>([])
  const [markers, setMarkers] = useState<WardMarker[]>([])
  const [forecasts, setForecasts] = useState<Map<number, WardForecastSummary>>(new Map())
  const [metrics, setMetrics] = useState<GatiMetrics | null>(null)
  const [teams, setTeams] = useState(6)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    Promise.all([fetchAllWardsAqi(), fetchAllForecasts(), fetchGatiMetrics()]).then(([wardData, fc, m]) => {
      const sorted = [...wardData].sort((a, b) => {
        if (a.aqi === null && b.aqi === null) return 0
        if (a.aqi === null) return 1
        if (b.aqi === null) return -1
        return b.aqi - a.aqi
      })
      setWards(sorted)
      setMarkers(
        wardData.filter((w) => w.lat != null && w.lng != null)
          .map((w) => ({ id: w.id, name: w.name, lat: w.lat!, lng: w.lng!, aqi: w.aqi })),
      )
      setForecasts(fc); setMetrics(m); setLoading(false)
    })
  }, [])

  const grapAlerts = [...forecasts.values()]
    .filter((f) => f.hoursToSevere != null && f.hoursToSevere <= 36)
    .map((f) => ({ ...f, name: wards.find((w) => w.id === f.wardId)?.name ?? `Ward ${f.wardId}` }))
    .sort((a, b) => (a.hoursToSevere ?? 99) - (b.hoursToSevere ?? 99))

  const allocation: Allocation[] = allocateTeams(
    wards.map((w) => ({ id: w.id, name: w.name })), forecasts, teams,
  )

  return (
    <AppShell subtitle="Command" dark>
      <div className="flex-1 space-y-3 overflow-y-auto p-4">
        {/* KPI row */}
        <div className="grid gap-3 md:grid-cols-3">
          <Panel className="p-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Gati · signal → action</p>
            <p className="mt-1 text-3xl font-bold tabular-nums text-white">
              {metrics?.medianHours != null ? `${metrics.medianHours.toFixed(1)}h` : '—'}
            </p>
            <p className="mt-1 text-xs text-slate-400">
              median · {metrics?.resolvedCount ?? 0} resolved · {metrics?.openCount ?? 0} open
            </p>
          </Panel>

          <Panel className="p-4 md:col-span-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Predictive-GRAP · severe within 36h
            </p>
            {loading ? (
              <Skeleton className="mt-2 h-10 w-full bg-slate-800" />
            ) : grapAlerts.length === 0 ? (
              <p className="mt-2 text-sm text-slate-400">No wards crossing severe in the next 36h.</p>
            ) : (
              <ul className="mt-2 space-y-1">
                {grapAlerts.map((a) => (
                  <li key={a.wardId} className="flex items-center justify-between text-sm">
                    <span className="flex items-center gap-2 font-medium text-red-300">
                      <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-red-400" />
                      {a.name}
                    </span>
                    <span className="tabular-nums text-slate-400">peak {Math.round(a.peakPred ?? 0)} · in {a.hoursToSevere}h</span>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        </div>

        {/* Allocation */}
        <Panel className="p-4">
          <div className="flex items-center justify-between">
            <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Team allocation · weighted by predicted local excess
            </p>
            <div className="flex items-center gap-2 text-sm">
              <span className="text-slate-400">Teams</span>
              <input
                type="number" min={1} max={50} value={teams}
                onChange={(e) => setTeams(Math.max(1, Number(e.target.value) || 1))}
                className="w-16 rounded-lg bg-slate-800 px-2 py-1 text-center text-white outline-none ring-1 ring-white/10 focus:ring-brand-400"
              />
            </div>
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            {allocation.filter((a) => a.teams > 0).length === 0 ? (
              <p className="text-sm text-slate-400">No forecast excess to allocate against yet.</p>
            ) : (
              allocation.filter((a) => a.teams > 0).map((a) => (
                <div key={a.wardId} className="flex items-center gap-2 rounded-xl bg-slate-800 px-3 py-1.5 text-sm">
                  <span className="font-medium text-white">{a.wardName}</span>
                  <span className="rounded bg-brand-500/20 px-1.5 text-xs font-bold text-brand-200">×{a.teams}</span>
                  {a.peakExcess != null && <span className="text-xs text-slate-500">+{Math.round(a.peakExcess)}</span>}
                </div>
              ))
            )}
          </div>
        </Panel>

        {/* Hotspot table */}
        <Panel>
          <div className="border-b border-white/5 px-4 py-3">
            <h2 className="text-sm font-semibold text-slate-200">Hotspots · current & forecast peak</h2>
          </div>
          {loading ? (
            <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-8 w-full bg-slate-800" />)}</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-white/5 text-left text-xs uppercase text-slate-500">
                    <th className="px-4 py-2 font-medium">#</th>
                    <th className="px-4 py-2 font-medium">Ward</th>
                    <th className="px-4 py-2 font-medium">Now</th>
                    <th className="px-4 py-2 font-medium">Peak 48h</th>
                    <th className="hidden px-4 py-2 font-medium sm:table-cell">Source</th>
                    <th className="hidden px-4 py-2 font-medium sm:table-cell">Age</th>
                  </tr>
                </thead>
                <tbody>
                  {wards.map((ward, i) => {
                    const fc = forecasts.get(ward.id)
                    return (
                      <tr key={ward.id} className="border-b border-white/5 last:border-0 hover:bg-white/5">
                        <td className="px-4 py-2 text-slate-500">{i + 1}</td>
                        <td className="px-4 py-2 font-medium text-slate-100">{ward.name}</td>
                        <td className="px-4 py-2"><AqiPill aqi={ward.aqi} /></td>
                        <td className="px-4 py-2">
                          {fc?.peakPred != null ? (
                            <span className="inline-flex items-center gap-1">
                              <AqiPill aqi={Math.round(fc.peakPred)} />
                              {fc.peakExcess != null && <span className="text-xs text-slate-500">+{Math.round(fc.peakExcess)}</span>}
                            </span>
                          ) : <span className="text-slate-600">—</span>}
                        </td>
                        <td className="hidden px-4 py-2 capitalize text-slate-400 sm:table-cell">{ward.dominant_source?.replace(/_/g, ' ') ?? '—'}</td>
                        <td className="hidden px-4 py-2 text-slate-500 sm:table-cell">{timeAgo(ward.ts)}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
        </Panel>

        {/* Map */}
        <Panel className="overflow-hidden">
          <div className="h-72"><MapView markers={markers} /></div>
        </Panel>
      </div>
    </AppShell>
  )
}
