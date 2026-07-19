import { useState } from 'react'
import { useAuth } from '../lib/auth'
import {
  DETECTION_STAGE_LABEL,
  FORECAST_DATA_QUALITY_LABEL,
  FORECAST_DISCLAIMER,
  FORECAST_METHOD_LABEL,
  POLLUTANT_LABEL,
  PREDICTION_METHOD_LABEL,
  describeTriggeredRule,
  forecastFallbackStatus,
  isHorizonValidated,
  sensorQualityCaveat,
  type ForecastDataQualityStatus,
  type ForecastMethod,
  type Pollutant,
  type PredictionMethod,
} from '../lib/incidentRules'
import {
  confirmPredictedIncident,
  continueMonitoringPredictedIncident,
  dismissPredictedIncident,
  fetchForecastCurve,
  fetchLatestForecastRun,
  listStationsForWard,
  mergePredictedIncident,
  type IncidentDetail,
} from '../lib/incidents'
import { useAsync } from '../lib/useAsync'
import { Label } from './ui'

/**
 * Automated anomaly-detection summary + command review (Phase 6). Shown only
 * for an incident that originated from `evaluate_station_pollutant_anomaly`
 * (`incident.detection_stage` set) — a citizen-reported or manually-created
 * incident never has this panel.
 *
 * The rule engine itself lives entirely in SQL; this panel only displays
 * what it already computed and stored on the latest linked
 * `anomaly_candidates` row, plus the plain command review actions (confirm /
 * continue monitoring / dismiss / merge). "Request evidence" is deliberately
 * NOT duplicated here — DetailHeader's existing button already works for any
 * incident, predicted or not.
 */

function fmt(n: number | null, digits = 1): string {
  return n == null ? '—' : n.toFixed(digits)
}

/** Compact inline-SVG forecast curve with an uncertainty band — no chart
 *  library, matching ForecastChart.tsx's own approach, generalised to any
 *  pollutant and to the Phase 8 lower/upper bound columns. */
function ForecastCurveChart({
  points,
}: {
  points: { horizon_ts: string; predicted_value: number | null; lower_bound: number | null; upper_bound: number | null }[]
}) {
  const data = points.filter((p) => p.predicted_value != null) as (typeof points[number] & { predicted_value: number })[]
  if (data.length < 2) return <p className="text-xs text-ink-400">No forecast curve yet.</p>

  const W = 320
  const H = 96
  const pad = { top: 8, right: 8, bottom: 16, left: 32 }
  const innerW = W - pad.left - pad.right
  const innerH = H - pad.top - pad.bottom
  const maxV = Math.max(...data.map((p) => p.upper_bound ?? p.predicted_value), 10)
  const x = (i: number) => pad.left + (i / (data.length - 1)) * innerW
  const y = (v: number) => pad.top + innerH - (Math.max(v, 0) / maxV) * innerH

  const line = data.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i)},${y(p.predicted_value)}`).join(' ')
  const hasBand = data.every((p) => p.lower_bound != null && p.upper_bound != null)
  const band = hasBand
    ? `${data.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i)},${y(p.upper_bound as number)}`).join(' ')} ${data
        .map((_p, i) => `L${x(data.length - 1 - i)},${y(data[data.length - 1 - i].lower_bound as number)}`)
        .join(' ')} Z`
    : null

  const peak = data.reduce((a, b) => (b.predicted_value > a.predicted_value ? b : a), data[0])

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full" role="img" aria-label="Forecast curve">
      {band && <path d={band} fill="#7c3aed" fillOpacity={0.12} />}
      <path d={line} fill="none" stroke="#7c3aed" strokeWidth={1.5} />
      <circle cx={x(data.indexOf(peak))} cy={y(peak.predicted_value)} r={2.5} fill="#7c3aed" />
      <text x={x(data.indexOf(peak))} y={y(peak.predicted_value) - 5} fontSize={8} textAnchor="middle" fill="#5b21b6">
        peak {peak.predicted_value.toFixed(0)}
      </text>
    </svg>
  )
}

export default function PredictedIncidentPanel({ detail, onRefresh }: { detail: IncidentDetail; onRefresh: () => void }) {
  const { session } = useAuth()
  const { incident, anomalyCandidates } = detail
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const stations = useAsync(() => listStationsForWard(incident.ward_id as number), [incident.ward_id], {
    enabled: incident.ward_id != null,
  })

  const latest = anomalyCandidates[0] ?? null
  const pollutant = (incident.primary_pollutant ?? latest?.pollutant ?? null) as Pollutant | null

  const forecastRun = useAsync(
    () => fetchLatestForecastRun(incident.ward_id as number, pollutant as string),
    [incident.ward_id, pollutant],
    { enabled: incident.ward_id != null && pollutant != null },
  )
  const forecastCurve = useAsync(
    () => fetchForecastCurve(incident.ward_id as number, pollutant as string),
    [incident.ward_id, pollutant],
    { enabled: incident.ward_id != null && pollutant != null },
  )

  if (incident.detection_stage == null) return null

  const nearbyStations = (stations.data ?? []).filter((s) => s.id !== latest?.station_id)
  const triggeredRules = (latest?.triggered_rules as string[] | null) ?? []
  const run = forecastRun.data

  const act = async (fn: () => Promise<void>) => {
    if (!session) return
    setBusy(true)
    setError(null)
    try {
      await fn()
      onRefresh()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Action failed.')
    } finally {
      setBusy(false)
    }
  }

  const continueMonitoring = () => {
    if (!session) return
    void act(() => continueMonitoringPredictedIncident(incident.id, session.user.id))
  }

  const confirm = () => {
    if (!session) return
    void act(() => confirmPredictedIncident(incident.id, session.user.id))
  }

  const dismiss = () => {
    if (!session) return
    const reason = window.prompt('Why is this being dismissed as a data anomaly? (kept free of internal sensor detail)')
    if (!reason?.trim()) return
    void act(() => dismissPredictedIncident(incident.id, session.user.id, reason.trim()))
  }

  const merge = () => {
    if (!session) return
    const targetIdRaw = window.prompt('Incident # to merge this into:')
    const targetId = targetIdRaw ? Number(targetIdRaw) : NaN
    if (!Number.isFinite(targetId)) return
    void act(() => mergePredictedIncident(incident.id, targetId, session.user.id))
  }

  const isActionable = incident.status !== 'closed'

  return (
    <section className="border-t border-ink-900/5 px-4 py-3">
      <div className="mb-2 flex items-center gap-2">
        <Label dark>Automated detection</Label>
        <span className="rounded bg-brand-100 px-1.5 py-0.5 text-[10px] font-bold uppercase text-brand-800">
          {DETECTION_STAGE_LABEL[incident.detection_stage]}
        </span>
      </div>

      <dl className="grid grid-cols-2 gap-x-3 gap-y-1.5 text-[11px] sm:grid-cols-4">
        <div>
          <dt className="text-ink-400">Location</dt>
          <dd className="font-semibold text-ink-700">{incident.ward_name ?? 'Unknown ward'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Pollutant</dt>
          <dd className="font-semibold text-ink-700">{pollutant ? POLLUTANT_LABEL[pollutant] : '—'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Current concentration</dt>
          <dd className="font-semibold text-ink-700">{fmt(latest?.current_concentration ?? null)}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Local excess</dt>
          <dd className="font-semibold text-ink-700">{fmt(latest?.local_excess ?? null)}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Rate of increase</dt>
          <dd className="font-semibold text-ink-700">{latest?.rate_of_increase != null ? `${fmt(latest.rate_of_increase)}/h` : '—'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Expected threshold crossing</dt>
          <dd className="font-semibold text-ink-700">
            {latest?.projected_crossing_at ? new Date(latest.projected_crossing_at).toLocaleString() : latest?.detection_stage === 'detected' ? 'Already crossed' : '—'}
          </dd>
        </div>
        <div>
          <dt className="text-ink-400">Data confidence</dt>
          <dd className="font-semibold text-ink-700">{latest?.confidence != null ? `${Math.round(latest.confidence * 100)}%` : '—'}</dd>
        </div>
        <div>
          <dt className="text-ink-400">Sensor</dt>
          <dd className="font-semibold text-ink-700">
            {latest?.sensor_quality ?? '—'}
            {sensorQualityCaveat(latest?.sensor_quality ?? null) && (
              <span className="ml-1 font-normal text-ink-400">({sensorQualityCaveat(latest?.sensor_quality ?? null)})</span>
            )}
          </dd>
        </div>
        {latest?.prediction_method && (
          <div>
            <dt className="text-ink-400">Prediction method</dt>
            <dd className="font-semibold text-ink-700">{PREDICTION_METHOD_LABEL[latest.prediction_method as PredictionMethod]}</dd>
          </div>
        )}
      </dl>

      {triggeredRules.length > 0 && (
        <div className="mt-2">
          <p className="text-[11px] font-semibold text-ink-600">Triggered detection rules</p>
          <ul className="mt-0.5 list-disc pl-4 text-[11px] text-ink-600">
            {triggeredRules.map((r) => (
              <li key={r}>{describeTriggeredRule(r)}</li>
            ))}
          </ul>
        </div>
      )}

      {nearbyStations.length > 0 && (
        <div className="mt-2">
          <p className="text-[11px] font-semibold text-ink-600">Nearby monitoring stations</p>
          <p className="mt-0.5 text-[11px] text-ink-500">{nearbyStations.map((s) => s.name).join(', ')}</p>
        </div>
      )}

      {run && (
        <div className="mt-3 rounded-lg border border-ink-900/10 bg-white p-2.5">
          <div className="flex flex-wrap items-center gap-2">
            <p className="text-[11px] font-semibold text-ink-700">Forecast — {pollutant ? POLLUTANT_LABEL[pollutant] : ''}</p>
            <span className="rounded bg-ink-100 px-1.5 py-0.5 text-[10px] font-bold uppercase text-ink-500">{FORECAST_DISCLAIMER}</span>
          </div>

          <div className="mt-2">
            <ForecastCurveChart points={forecastCurve.data ?? []} />
          </div>

          <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-[11px] sm:grid-cols-3">
            <div>
              <dt className="text-ink-400">Method used</dt>
              <dd className="font-semibold text-ink-700">{FORECAST_METHOD_LABEL[run.method as ForecastMethod]}</dd>
            </div>
            <div>
              <dt className="text-ink-400">Fallback status</dt>
              <dd className="font-semibold text-ink-700">{forecastFallbackStatus(run.method as ForecastMethod, run.beats_persistence)}</dd>
            </div>
            <div>
              <dt className="text-ink-400">Validated up to</dt>
              <dd className="font-semibold text-ink-700">
                {run.max_validated_horizon_hours != null ? `${run.max_validated_horizon_hours}h` : 'Not yet validated'}
              </dd>
            </div>
          </dl>

          {run.validation_metrics && Object.keys(run.validation_metrics as object).length > 0 && (
            <div className="mt-2">
              <p className="text-[11px] font-semibold text-ink-600">Model accuracy by horizon (MAE vs. persistence)</p>
              <div className="mt-1 flex flex-wrap gap-2">
                {Object.entries(run.validation_metrics as Record<string, { mae: number; persistence_mae: number; beats_persistence: boolean }>).map(
                  ([h, m]) => (
                    <span
                      key={h}
                      className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${
                        isHorizonValidated(run.max_validated_horizon_hours, Number(h))
                          ? 'bg-green-100 text-green-800'
                          : 'bg-ink-100 text-ink-500'
                      }`}
                      title={`Persistence MAE ${m.persistence_mae}`}
                    >
                      {h}h: MAE {m.mae}
                    </span>
                  ),
                )}
              </div>
            </div>
          )}

          {run.data_quality_status !== 'ok' && (
            <p className="mt-2 rounded-lg bg-status-warning/10 px-2 py-1 text-[11px] text-status-warning">
              {FORECAST_DATA_QUALITY_LABEL[run.data_quality_status as ForecastDataQualityStatus]}
            </p>
          )}
        </div>
      )}

      {anomalyCandidates.length > 1 && (
        <p className="mt-2 text-[11px] text-ink-400">{anomalyCandidates.length} detection signals recorded for this incident.</p>
      )}

      {isActionable && (
        <div className="mt-3 flex flex-wrap gap-1.5">
          <button type="button" disabled={busy} onClick={continueMonitoring} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Continue monitoring
          </button>
          <button type="button" disabled={busy} onClick={confirm} className="focus-ring rounded-lg bg-brand-700 px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-brand-800 disabled:opacity-50">
            Promote to active incident
          </button>
          <button type="button" disabled={busy} onClick={dismiss} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Dismiss as data anomaly
          </button>
          <button type="button" disabled={busy} onClick={merge} className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-[11px] font-semibold text-ink-700 hover:bg-ink-50 disabled:opacity-50">
            Merge with existing incident
          </button>
        </div>
      )}
      {error && <p className="mt-2 text-xs text-status-critical">{error}</p>}
    </section>
  )
}
