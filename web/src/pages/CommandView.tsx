import { useEffect, useState } from 'react'
import { aqiLevel } from '../components/AqiBadge'
import AppShell from '../components/AppShell'
import MapView, { type WardMarker } from '../components/MapView'
import { Card, CardHeader, EmptyState, Skeleton, Stat } from '../components/ui'
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
  if (!ts) return '-'
  const h = Math.floor((Date.now() - new Date(ts).getTime()) / 3_600_000)
  return h < 1 ? '<1h' : `${h}h`
}

function AqiPill({ aqi }: { aqi: number | null }) {
  const level = aqiLevel(aqi)
  return (
    <span
      className="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-bold tabular-nums"
      style={{ backgroundColor: `${level.hex}1f`, color: level.hex }}
    >
      {aqi ?? '-'}
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
  const activeAllocation = allocation.filter((a) => a.teams > 0)

  return (
    <AppShell subtitle="Overview">
      <div className="flex-1 space-y-4 overflow-y-auto bg-slate-50 p-3 sm:p-4">
        {/* ── KPI summary row ── */}
        <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-4 sm:gap-3">
          <Stat
            value={metrics?.medianHours != null ? `${metrics.medianHours.toFixed(1)}h` : '-'}
            label="Median time to action"
            accent="text-accent-700"
          />
          <Stat value={metrics?.openCount ?? 0} label="Open incidents" />
          <Stat value={metrics?.resolvedCount ?? 0} label="Resolved" accent="text-status-success" />
          <Stat
            value={grapAlerts.length}
            label="Severe within 36h"
            accent={grapAlerts.length > 0 ? 'text-status-critical' : 'text-slate-900'}
          />
        </div>

        {/* ── Predictive alerts ── */}
        <Card>
          <CardHeader title="Predictive alerts" subtitle="Wards forecast to cross severe within 36 hours" />
          {loading ? (
            <div className="space-y-2 p-4">
              <Skeleton className="h-8 w-full" />
              <Skeleton className="h-8 w-full" />
            </div>
          ) : grapAlerts.length === 0 ? (
            <EmptyState icon="✅">No wards are currently trending toward severe within 36h.</EmptyState>
          ) : (
            <ul className="divide-y divide-slate-100">
              {grapAlerts.map((a) => (
                <li key={a.wardId} className="flex items-center justify-between px-4 py-2.5 text-sm">
                  <span className="flex items-center gap-2 font-medium text-slate-800">
                    <span className="h-1.5 w-1.5 flex-shrink-0 animate-pulse rounded-full bg-status-critical" />
                    {a.name}
                  </span>
                  <span className="tabular-nums text-slate-400">
                    peak {Math.round(a.peakPred ?? 0)} · in {a.hoursToSevere}h
                  </span>
                </li>
              ))}
            </ul>
          )}
        </Card>

        {/* ── Team allocation ── */}
        <Card>
          <CardHeader
            title="Team allocation"
            subtitle="Weighted by predicted local excess"
            right={
              <div className="flex items-center gap-2 text-sm">
                <label htmlFor="teams" className="text-xs font-medium text-slate-500">
                  Teams
                </label>
                <input
                  id="teams"
                  type="number"
                  min={1}
                  max={50}
                  value={teams}
                  onChange={(e) => setTeams(Math.max(1, Number(e.target.value) || 1))}
                  className="focus-ring w-16 rounded-lg border border-slate-200 px-2 py-1 text-center text-sm text-slate-800"
                />
              </div>
            }
          />
          <div className="flex flex-wrap gap-2 p-4">
            {activeAllocation.length === 0 ? (
              <p className="text-sm text-slate-400">No forecast excess to allocate against yet.</p>
            ) : (
              activeAllocation.map((a) => (
                <div key={a.wardId} className="flex items-center gap-2 rounded-lg bg-slate-50 px-3 py-1.5 text-sm ring-1 ring-slate-200">
                  <span className="font-medium text-slate-800">{a.wardName}</span>
                  <span className="rounded bg-accent-100 px-1.5 text-xs font-bold text-accent-700">×{a.teams}</span>
                  {a.peakExcess != null && <span className="text-xs text-slate-400">+{Math.round(a.peakExcess)}</span>}
                </div>
              ))
            )}
          </div>
        </Card>

        {/* ── Hotspots: table on desktop, cards on mobile - intentionally distinct, not a shrunk table ── */}
        <Card>
          <CardHeader title="Hotspots" subtitle="Current reading and 48h forecast peak, worst first" />
          {loading ? (
            <div className="space-y-2 p-4">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10 w-full" />)}</div>
          ) : (
            <>
              {/* Mobile: stacked cards */}
              <ul className="divide-y divide-slate-100 sm:hidden">
                {wards.map((ward, i) => {
                  const fc = forecasts.get(ward.id)
                  return (
                    <li key={ward.id} className="flex items-center justify-between px-4 py-3">
                      <div className="min-w-0">
                        <p className="flex items-center gap-1.5 text-sm font-medium text-slate-800">
                          <span className="text-xs text-slate-400">#{i + 1}</span>
                          {ward.name}
                        </p>
                        <p className="mt-0.5 text-xs capitalize text-slate-400">
                          {ward.dominant_source?.replace(/_/g, ' ') ?? 'source unknown'} · {timeAgo(ward.ts)} ago
                        </p>
                      </div>
                      <div className="flex flex-shrink-0 items-center gap-2">
                        <AqiPill aqi={ward.aqi} />
                        {fc?.peakPred != null && (
                          <span className="text-xs text-slate-400">→ {Math.round(fc.peakPred)}</span>
                        )}
                      </div>
                    </li>
                  )
                })}
              </ul>

              {/* Desktop: table */}
              <div className="hidden overflow-x-auto sm:block">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-slate-100 text-left text-xs uppercase text-slate-400">
                      <th className="px-4 py-2 font-medium">#</th>
                      <th className="px-4 py-2 font-medium">Ward</th>
                      <th className="px-4 py-2 font-medium">Now</th>
                      <th className="px-4 py-2 font-medium">Peak 48h</th>
                      <th className="px-4 py-2 font-medium">Source</th>
                      <th className="px-4 py-2 font-medium">Age</th>
                    </tr>
                  </thead>
                  <tbody>
                    {wards.map((ward, i) => {
                      const fc = forecasts.get(ward.id)
                      return (
                        <tr key={ward.id} className="border-b border-slate-50 last:border-0 hover:bg-slate-50">
                          <td className="px-4 py-2 text-slate-400">{i + 1}</td>
                          <td className="px-4 py-2 font-medium text-slate-800">{ward.name}</td>
                          <td className="px-4 py-2"><AqiPill aqi={ward.aqi} /></td>
                          <td className="px-4 py-2">
                            {fc?.peakPred != null ? (
                              <span className="inline-flex items-center gap-1">
                                <AqiPill aqi={Math.round(fc.peakPred)} />
                                {fc.peakExcess != null && <span className="text-xs text-slate-400">+{Math.round(fc.peakExcess)}</span>}
                              </span>
                            ) : <span className="text-slate-300">-</span>}
                          </td>
                          <td className="px-4 py-2 capitalize text-slate-500">{ward.dominant_source?.replace(/_/g, ' ') ?? '-'}</td>
                          <td className="px-4 py-2 text-slate-400">{timeAgo(ward.ts)}</td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </Card>

        {/* ── Map ── */}
        <Card className="overflow-hidden">
          <CardHeader title="Map" subtitle="Ward AQI, current readings" />
          <div className="h-64 sm:h-80"><MapView markers={markers} /></div>
        </Card>
      </div>
    </AppShell>
  )
}
