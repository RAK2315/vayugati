// India NAQI scale — shared source of truth for label, colors, and guidance.
const LEVELS = [
  { max: 50,       label: 'Good',         hex: '#22c55e', bg: 'bg-green-100',  text: 'text-green-800',  advice: 'Air is clean — enjoy the outdoors.' },
  { max: 100,      label: 'Satisfactory', hex: '#84cc16', bg: 'bg-lime-100',   text: 'text-lime-800',   advice: 'Acceptable. Sensitive people take minor care.' },
  { max: 200,      label: 'Moderate',     hex: '#eab308', bg: 'bg-yellow-100', text: 'text-yellow-800', advice: 'Sensitive groups should limit prolonged exertion.' },
  { max: 300,      label: 'Poor',         hex: '#f97316', bg: 'bg-orange-100', text: 'text-orange-800', advice: 'Reduce outdoor exertion; mask up outside.' },
  { max: 400,      label: 'Very Poor',    hex: '#ef4444', bg: 'bg-red-100',    text: 'text-red-800',    advice: 'Avoid outdoor activity; keep windows shut.' },
  { max: Infinity, label: 'Severe',       hex: '#9333ea', bg: 'bg-purple-100', text: 'text-purple-900', advice: 'Health emergency — stay indoors, use a purifier.' },
]

const UNKNOWN = { label: 'No data', hex: '#94a3b8', bg: 'bg-slate-100', text: 'text-slate-500', advice: 'Waiting for the next station reading.' }

export function aqiLevel(aqi: number | null) {
  if (aqi === null) return UNKNOWN
  return LEVELS.find((l) => aqi <= l.max) ?? LEVELS[LEVELS.length - 1]
}

// ── Hero gauge for the citizen view ──────────────────────────────────────────
export function AqiGauge({ aqi }: { aqi: number | null }) {
  const level = aqiLevel(aqi)
  const pos = aqi === null ? 0 : Math.min(aqi / 500, 1) // marker position on the 0–500 scale

  return (
    <div>
      <div className="flex items-end gap-4">
        <div
          className="flex h-24 w-24 flex-shrink-0 flex-col items-center justify-center rounded-2xl"
          style={{ backgroundColor: `${level.hex}1a` }}
        >
          <span className="text-4xl font-extrabold tabular-nums leading-none" style={{ color: level.hex }}>
            {aqi ?? '—'}
          </span>
          <span className="mt-1 text-[10px] font-semibold uppercase tracking-wide" style={{ color: level.hex }}>
            AQI
          </span>
        </div>
        <div className="min-w-0 flex-1 pb-1">
          <p className="text-lg font-bold" style={{ color: level.hex }}>
            {level.label}
          </p>
          <p className="mt-0.5 text-sm text-slate-600">{level.advice}</p>
        </div>
      </div>

      {/* NAQI scale bar with a marker at the current position */}
      <div className="relative mt-4">
        <div className="flex h-2 overflow-hidden rounded-full">
          {LEVELS.map((l) => (
            <div key={l.label} className="flex-1" style={{ backgroundColor: l.hex }} />
          ))}
        </div>
        {aqi !== null && (
          <div
            className="absolute -top-1 h-4 w-1 -translate-x-1/2 rounded-full bg-slate-900 ring-2 ring-white"
            style={{ left: `${pos * 100}%` }}
          />
        )}
        <div className="mt-1 flex justify-between text-[10px] text-slate-400">
          <span>0</span>
          <span>250</span>
          <span>500</span>
        </div>
      </div>
    </div>
  )
}

// ── Compact badge (field / small contexts) ───────────────────────────────────
export default function AqiBadge({ aqi }: { aqi: number | null }) {
  const level = aqiLevel(aqi)
  return (
    <div
      className="flex h-16 w-16 flex-shrink-0 flex-col items-center justify-center rounded-xl"
      style={{ backgroundColor: `${level.hex}1a` }}
    >
      <span className="text-2xl font-bold tabular-nums leading-none" style={{ color: level.hex }}>
        {aqi ?? '—'}
      </span>
      <span className="mt-0.5 text-[9px] font-semibold uppercase tracking-wide" style={{ color: level.hex }}>
        AQI
      </span>
    </div>
  )
}
