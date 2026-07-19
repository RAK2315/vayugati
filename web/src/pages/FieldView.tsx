import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import AqiBadge from '../components/AqiBadge'
import AppShell from '../components/AppShell'
import AttributionArrow from '../components/AttributionArrow'
import ForecastChart from '../components/ForecastChart'
import MapView from '../components/MapView'
import { Card, CardHeader, EmptyState, Skeleton, Stat } from '../components/ui'
import { useAuth } from '../lib/auth'
import { listMissionsForUser } from '../lib/incidents'
import {
  fetchAttribution,
  fetchForecast,
  fetchLatestReading,
  fetchOpenReports,
  fetchWardRollup,
  priorityBand,
  priorityScore,
  updateReportStatus,
  type Attribution,
  type ForecastPoint,
  type Reading,
  type Report,
  type ReportStatus,
  type WardRollup,
} from '../lib/data'

const NEXT_STATUS: Record<string, { label: string; next: ReportStatus; color: string }> = {
  submitted: { label: 'Verify',  next: 'verified', color: 'bg-blue-600 hover:bg-blue-700'    },
  verified:  { label: 'Act',     next: 'acted',    color: 'bg-orange-500 hover:bg-orange-600' },
  assigned:  { label: 'Act',     next: 'acted',    color: 'bg-orange-500 hover:bg-orange-600' },
  acted:     { label: 'Resolve', next: 'resolved', color: 'bg-green-600 hover:bg-green-700'   },
}

function timeAgo(ts: string | null): string {
  if (!ts) return '—'
  const h = Math.floor((Date.now() - new Date(ts).getTime()) / 3_600_000)
  return h < 1 ? 'just now' : `${h}h ago`
}

export default function FieldView() {
  const { profile, session } = useAuth()
  const [missionCount, setMissionCount] = useState<number | null>(null)
  const [reading, setReading] = useState<Reading | null>(null)
  const [forecast, setForecast] = useState<ForecastPoint[]>([])
  const [attribution, setAttribution] = useState<Attribution | null>(null)
  const [reports, setReports] = useState<Report[]>([])
  const [rollup, setRollup] = useState<WardRollup | null>(null)
  const [loading, setLoading] = useState(true)
  const [updating, setUpdating] = useState<number | null>(null)

  useEffect(() => {
    if (!profile?.wardId) { setLoading(false); return }
    Promise.all([
      fetchLatestReading(profile.wardId),
      fetchForecast(profile.wardId),
      fetchAttribution(profile.wardId),
      fetchOpenReports(profile.wardId),
      fetchWardRollup(profile.wardId),
    ]).then(([r, fc, attr, rpts, rup]) => {
      setReading(r); setForecast(fc); setAttribution(attr); setReports(rpts); setRollup(rup); setLoading(false)
    })
  }, [profile?.wardId])

  // Evidence missions live on their own screen; surface the count here so the
  // officer's home still tells them work is waiting. Best-effort: on failure the
  // banner stays hidden rather than breaking the ward view.
  useEffect(() => {
    if (!session) return
    let cancelled = false
    listMissionsForUser(session.user.id)
      .then((ms) => {
        if (cancelled) return
        setMissionCount(
          ms.filter((m) => m.mission.status !== 'completed' && m.mission.status !== 'cancelled').length,
        )
      })
      .catch(() => {
        if (!cancelled) setMissionCount(null)
      })
    return () => {
      cancelled = true
    }
  }, [session])

  const peakExcess = forecast.reduce<number | null>(
    (max, p) => (p.local_excess != null && (max == null || p.local_excess > max) ? p.local_excess : max),
    null,
  )
  const rankedReports = [...reports]
    .map((r) => ({ report: r, score: priorityScore(r, peakExcess) }))
    .sort((a, b) => b.score - a.score)

  const advance = async (report: Report) => {
    if (!session) return
    const transition = NEXT_STATUS[report.status]
    if (!transition) return
    setUpdating(report.id)
    try {
      await updateReportStatus(report.id, transition.next, session.user.id)
      setReports((prev) =>
        prev
          .map((r) => (r.id === report.id ? { ...r, status: transition.next } : r))
          .filter((r) => r.status !== 'resolved'),
      )
    } finally {
      setUpdating(null)
    }
  }

  if (!profile) return null

  return (
    <AppShell subtitle="Field Ops">
      <div className="mx-auto w-full max-w-2xl flex-1 space-y-3 overflow-y-auto p-4">
        {/* Evidence missions (Phase 3) — a distinct task type from the report
            action queue below, so it gets its own entry point rather than being
            mixed into a single undifferentiated list. */}
        {missionCount != null && missionCount > 0 && (
          <Link
            to="/missions"
            className="focus-ring flex items-center gap-3 rounded-2xl border border-sky-300 bg-sky-50 px-4 py-3 transition hover:bg-sky-100"
          >
            <span className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-full bg-sky-200 text-base">
              🔍
            </span>
            <span className="min-w-0">
              <span className="block text-sm font-semibold text-ink-800">
                {missionCount} evidence mission{missionCount > 1 ? 's' : ''} assigned to you
              </span>
              <span className="block text-xs text-ink-500">Checklist + geotagged proof · open them →</span>
            </span>
          </Link>
        )}

        {/* AQI + roll-up row */}
        <div className="grid gap-3 sm:grid-cols-2">
          <Card className="flex items-center gap-4 p-4">
            {loading ? <Skeleton className="h-16 w-16" /> : <AqiBadge aqi={reading?.aqi ?? null} />}
            <div className="text-sm text-slate-600">
              <p className="font-medium text-slate-800">{profile.wardName}</p>
              <p>PM2.5 {reading?.pm25 ?? '—'} µg/m³</p>
              <p className="mt-0.5 text-xs text-slate-400">{timeAgo(reading?.ts ?? null)}</p>
            </div>
          </Card>
          <Card className="p-4">
            {rollup ? (
              <div className="grid grid-cols-3 gap-2">
                <Stat value={rollup.open} label="open" />
                <Stat value={rollup.resolved} label="resolved" accent="text-green-600" />
                <Stat value={rollup.medianGatiHours != null ? `${rollup.medianGatiHours.toFixed(1)}h` : '—'} label="gati" accent="text-brand-600" />
              </div>
            ) : (
              <Skeleton className="h-16 w-full" />
            )}
          </Card>
        </div>

        {/* Forecast + attribution */}
        <div className="grid gap-3 sm:grid-cols-2">
          <Card className="p-4">
            <p className="mb-2 text-sm font-semibold text-slate-700">48h forecast</p>
            <p className="mb-3 text-xs text-slate-400">Local excess is the part you control.</p>
            {loading ? <Skeleton className="h-24 w-full" /> : <ForecastChart points={forecast} />}
          </Card>
          <AttributionArrow attribution={attribution} />
        </div>

        {/* Ranked action queue */}
        <Card>
          <CardHeader
            title="Action queue"
            subtitle="Ranked by predicted impact"
            right={<span className="rounded-lg bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-500">{reports.length} open</span>}
          />
          {loading ? (
            <div className="space-y-3 p-4">
              {[0, 1].map((i) => <Skeleton key={i} className="h-16 w-full" />)}
            </div>
          ) : rankedReports.length === 0 ? (
            <EmptyState icon="✅">No open reports — all clear.</EmptyState>
          ) : (
            <ul className="divide-y divide-slate-100">
              {rankedReports.map(({ report: r, score }, i) => {
                const transition = NEXT_STATUS[r.status]
                const band = priorityBand(score)
                return (
                  <li key={r.id} className="px-4 py-3">
                    <div className="flex items-start gap-3">
                      <span className="w-5 pt-1 text-center text-sm font-bold text-slate-300">{i + 1}</span>
                      {r.photo_url && (
                        <a href={r.photo_url} target="_blank" rel="noreferrer" className="flex-shrink-0">
                          <img src={r.photo_url} alt="Report" className="h-16 w-16 rounded-xl object-cover" />
                        </a>
                      )}
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-2">
                          <span className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${band.cls}`}>{band.label}</span>
                          {r.ai_category && (
                            <span className="text-xs capitalize text-slate-500">
                              {r.ai_category.replace(/_/g, ' ')}
                              {r.ai_meta?.confidence != null && <span className="text-slate-400"> · {Math.round(r.ai_meta.confidence * 100)}%</span>}
                            </span>
                          )}
                        </div>
                        <p className="mt-1 text-sm text-slate-800">{r.description || '(no description)'}</p>
                        {r.ai_meta?.note_draft && (
                          <p className="mt-1.5 rounded-lg bg-brand-50 px-2.5 py-1.5 text-xs italic text-brand-800">
                            📝 {r.ai_meta.note_draft}
                          </p>
                        )}
                        <p className="mt-1 text-xs text-slate-400">{r.status} · {timeAgo(r.created_at)}</p>
                      </div>
                      {transition && (
                        <button
                          disabled={updating === r.id}
                          onClick={() => advance(r)}
                          className={`flex-shrink-0 rounded-lg px-3 py-1.5 text-xs font-semibold text-white transition ${transition.color} disabled:opacity-50`}
                        >
                          {updating === r.id ? '…' : transition.label}
                        </button>
                      )}
                    </div>
                  </li>
                )
              })}
            </ul>
          )}
        </Card>

        {/* Map */}
        <Card className="overflow-hidden">
          <div className="h-56"><MapView /></div>
        </Card>
      </div>
    </AppShell>
  )
}
