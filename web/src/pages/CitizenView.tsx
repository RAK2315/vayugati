import { useEffect, useState } from 'react'
import { AqiGauge } from '../components/AqiBadge'
import AppShell from '../components/AppShell'
import ForecastChart from '../components/ForecastChart'
import MapView from '../components/MapView'
import { Card, CardHeader, Skeleton } from '../components/ui'
import { useAuth } from '../lib/auth'
import {
  classifyReport,
  fetchCurrentWeather,
  fetchForecast,
  fetchLatestReading,
  fetchMyReports,
  insertReport,
  uploadReportPhoto,
  type ForecastPoint,
  type MyReport,
  type Reading,
  type Weather,
} from '../lib/data'

const STATUS_STYLE: Record<string, { label: string; cls: string }> = {
  submitted: { label: 'Submitted', cls: 'bg-slate-100 text-slate-600' },
  verified: { label: 'Verified', cls: 'bg-blue-100 text-blue-700' },
  assigned: { label: 'Assigned', cls: 'bg-amber-100 text-amber-700' },
  acted: { label: 'Acted', cls: 'bg-orange-100 text-orange-700' },
  resolved: { label: 'Resolved ✓', cls: 'bg-green-100 text-green-700' },
  rejected: { label: 'Rejected', cls: 'bg-red-100 text-red-700' },
}

function windDirLabel(deg: number | null): string {
  if (deg === null) return ''
  return ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][Math.round(deg / 45) % 8]
}

function timeAgo(ts: string | null): string {
  if (!ts) return '—'
  const h = Math.floor((Date.now() - new Date(ts).getTime()) / 3_600_000)
  return h < 1 ? 'just now' : `${h}h ago`
}

function WeatherChip({ children }: { children: React.ReactNode }) {
  return <span className="rounded-lg bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-600">{children}</span>
}

export default function CitizenView() {
  const { profile, session } = useAuth()
  const [reading, setReading] = useState<Reading | null>(null)
  const [weather, setWeather] = useState<Weather | null>(null)
  const [forecast, setForecast] = useState<ForecastPoint[]>([])
  const [myReports, setMyReports] = useState<MyReport[]>([])
  const [loading, setLoading] = useState(true)

  const [formOpen, setFormOpen] = useState(false)
  const [description, setDescription] = useState('')
  const [geoLoading, setGeoLoading] = useState(false)
  const [coords, setCoords] = useState<{ lat: number; lng: number } | null>(null)
  const [photo, setPhoto] = useState<File | null>(null)
  const [photoPreview, setPhotoPreview] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [submitMsg, setSubmitMsg] = useState<string | null>(null)

  useEffect(() => {
    if (!profile?.wardId || !session) { setLoading(false); return }
    Promise.all([
      fetchLatestReading(profile.wardId),
      fetchCurrentWeather(profile.wardId),
      fetchForecast(profile.wardId),
      fetchMyReports(session.user.id),
    ]).then(([r, w, fc, rpts]) => {
      setReading(r); setWeather(w); setForecast(fc); setMyReports(rpts); setLoading(false)
    })
  }, [profile?.wardId, session])

  const detectLocation = () => {
    setGeoLoading(true)
    navigator.geolocation.getCurrentPosition(
      (pos) => { setCoords({ lat: pos.coords.latitude, lng: pos.coords.longitude }); setGeoLoading(false) },
      () => setGeoLoading(false),
      { timeout: 8000 },
    )
  }

  const onPhotoPick = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0] ?? null
    setPhoto(file)
    setPhotoPreview(file ? URL.createObjectURL(file) : null)
  }

  const resetForm = () => {
    setDescription(''); setCoords(null); setPhoto(null); setPhotoPreview(null); setFormOpen(false)
  }

  const submitReport = async () => {
    if (!description.trim() || !profile?.wardId || !session) return
    setSubmitting(true); setSubmitMsg(null)
    try {
      let photoUrl: string | null = null
      if (photo) {
        try { photoUrl = await uploadReportPhoto(photo, session.user.id) }
        catch { setSubmitMsg('Photo upload failed — submitting without it.') }
      }
      const id = await insertReport({
        wardId: profile.wardId, reporterId: session.user.id,
        description: description.trim(), lat: coords?.lat ?? null, lng: coords?.lng ?? null, photoUrl,
      })
      classifyReport({ reportId: id, description: description.trim(), wardName: profile.wardName ?? '', photoUrl })
      resetForm()
      setSubmitMsg('Report submitted — track it below.')
      fetchMyReports(session.user.id).then(setMyReports)
    } catch (e: unknown) {
      setSubmitMsg(e instanceof Error ? e.message : 'Submission failed.')
    } finally {
      setSubmitting(false)
    }
  }

  if (!profile) return null

  return (
    <AppShell subtitle="My Air">
      <div className="mx-auto w-full max-w-lg flex-1 space-y-3 overflow-y-auto p-4">
        {/* AQI hero */}
        <Card className="p-5">
          <div className="mb-3 flex items-center justify-between">
            <p className="text-sm font-semibold text-slate-700">{profile.wardName ?? 'No ward assigned'}</p>
            <span className="text-xs text-slate-400">{timeAgo(reading?.ts ?? null)}</span>
          </div>
          {loading ? (
            <div className="space-y-3">
              <div className="flex gap-4"><Skeleton className="h-24 w-24" /><div className="flex-1 space-y-2 pt-2"><Skeleton className="h-5 w-24" /><Skeleton className="h-4 w-full" /></div></div>
              <Skeleton className="h-2 w-full" />
            </div>
          ) : (
            <>
              <AqiGauge aqi={reading?.aqi ?? null} />
              <div className="mt-4 flex flex-wrap items-center gap-2">
                {reading?.pm25 != null && <WeatherChip>PM2.5 {reading.pm25}</WeatherChip>}
                {reading?.pm10 != null && <WeatherChip>PM10 {reading.pm10}</WeatherChip>}
                {weather?.temp_c != null && <WeatherChip>🌡 {weather.temp_c.toFixed(0)}°C</WeatherChip>}
                {weather?.humidity != null && <WeatherChip>💧 {weather.humidity.toFixed(0)}%</WeatherChip>}
                {weather?.wind_speed != null && (
                  <WeatherChip>🌬 {weather.wind_speed.toFixed(0)} km/h {windDirLabel(weather.wind_dir)}</WeatherChip>
                )}
              </div>
            </>
          )}
        </Card>

        {/* Forecast */}
        <Card className="p-5">
          <p className="mb-3 text-sm font-semibold text-slate-700">Next 48 hours</p>
          {loading ? <Skeleton className="h-24 w-full" /> : <ForecastChart points={forecast} />}
        </Card>

        {/* Report flow */}
        <Card className="overflow-hidden">
          {!formOpen ? (
            <button
              onClick={() => setFormOpen(true)}
              className="flex w-full items-center gap-3 px-5 py-4 text-left transition hover:bg-slate-50"
            >
              <span className="flex h-10 w-10 items-center justify-center rounded-full bg-brand-600 text-lg text-white">＋</span>
              <span>
                <span className="block text-sm font-semibold text-slate-800">Report a pollution source</span>
                <span className="block text-xs text-slate-400">Photo + location · classified by AI in seconds</span>
              </span>
            </button>
          ) : (
            <div className="p-5">
              <div className="mb-3 flex items-center justify-between">
                <p className="text-sm font-semibold text-slate-700">Report a source</p>
                <button onClick={resetForm} className="text-xs text-slate-400 hover:text-slate-600">Cancel</button>
              </div>
              <textarea
                rows={3}
                autoFocus
                placeholder="What's the source? Location, type, rough scale…"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm outline-none transition focus:border-brand-400 focus:bg-white focus:ring-2 focus:ring-brand-100"
              />
              {photoPreview && (
                <img src={photoPreview} alt="Preview" className="mt-3 h-40 w-full rounded-xl object-cover" />
              )}
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <label className="cursor-pointer rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-medium text-slate-600 transition hover:bg-slate-50">
                  {photo ? '📷 Photo added' : '📷 Add photo'}
                  <input type="file" accept="image/*" capture="environment" onChange={onPhotoPick} className="hidden" />
                </label>
                <button
                  type="button"
                  onClick={detectLocation}
                  disabled={geoLoading}
                  className="rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-medium text-slate-600 transition hover:bg-slate-50 disabled:opacity-50"
                >
                  {geoLoading ? 'Locating…' : coords ? '📍 Location added' : '📍 Add location'}
                </button>
                <button
                  type="button"
                  onClick={submitReport}
                  disabled={submitting || !description.trim()}
                  className="ml-auto rounded-lg bg-brand-600 px-4 py-1.5 text-xs font-semibold text-white transition hover:bg-brand-700 disabled:opacity-50"
                >
                  {submitting ? 'Submitting…' : 'Submit'}
                </button>
              </div>
            </div>
          )}
          {submitMsg && <p className="border-t border-slate-100 bg-green-50/50 px-5 py-2 text-xs text-green-700">{submitMsg}</p>}
        </Card>

        {/* My reports */}
        {myReports.length > 0 && (
          <Card>
            <CardHeader title="My reports" />
            <ul className="divide-y divide-slate-100">
              {myReports.map((r) => (
                <li key={r.id} className="px-4 py-3">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="truncate text-sm text-slate-800">{r.description ?? '(no description)'}</p>
                      {r.ai_meta?.hindi_advisory && (
                        <p className="mt-0.5 text-xs text-slate-500">{r.ai_meta.hindi_advisory}</p>
                      )}
                      <p className="mt-0.5 text-xs text-slate-400">{timeAgo(r.created_at)}</p>
                    </div>
                    <span className={`flex-shrink-0 rounded-lg px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[r.status]?.cls ?? 'bg-slate-100 text-slate-600'}`}>
                      {STATUS_STYLE[r.status]?.label ?? r.status}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
          </Card>
        )}

        {/* Map */}
        <Card className="overflow-hidden">
          <div className="h-56"><MapView /></div>
        </Card>
      </div>
    </AppShell>
  )
}
