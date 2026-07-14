import type { Attribution } from '../lib/data'

const SECTOR_DEG: Record<string, number> = {
  N: 0, NE: 45, E: 90, SE: 135, S: 180, SW: 225, W: 270, NW: 315,
}

/** Compass showing the wind sector currently carrying the highest pollution load
 *  into this ward — the field officer's "look here now" pointer. */
export default function AttributionArrow({ attribution }: { attribution: Attribution | null }) {
  if (!attribution?.direction) {
    return (
      <div className="card p-4">
        <p className="text-sm font-semibold text-slate-700">Source direction</p>
        <p className="mt-1 text-sm text-slate-400">Not enough wind + reading history yet.</p>
      </div>
    )
  }

  const deg = SECTOR_DEG[attribution.direction] ?? 0
  const conf = attribution.confidence ?? 0
  // strongest sectors from the rose, for the caption
  const top = attribution.breakdown
    ? Object.entries(attribution.breakdown)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 3)
        .map(([s]) => s)
    : []

  return (
    <div className="card p-4">
      <p className="text-sm font-semibold text-slate-700">Source direction</p>
      <div className="mt-2 flex items-center gap-4">
        <svg viewBox="0 0 80 80" className="h-20 w-20 flex-shrink-0">
          <circle cx={40} cy={40} r={36} fill="#f9fafb" stroke="#e5e7eb" strokeWidth={1.5} />
          {['N', 'E', 'S', 'W'].map((label, i) => {
            const a = (i * 90 - 90) * (Math.PI / 180)
            return (
              <text
                key={label}
                x={40 + Math.cos(a) * 30}
                y={40 + Math.sin(a) * 30 + 3}
                fontSize={8}
                fill="#9ca3af"
                textAnchor="middle"
              >
                {label}
              </text>
            )
          })}
          {/* arrow points FROM the source direction toward the station (center) */}
          <g transform={`rotate(${deg} 40 40)`}>
            <line x1={40} y1={40} x2={40} y2={12} stroke="#ef4444" strokeWidth={2.5} />
            <polygon points="40,8 36,16 44,16" fill="#ef4444" />
          </g>
          <circle cx={40} cy={40} r={3} fill="#374151" />
        </svg>
        <div className="text-sm">
          <p className="text-slate-800">
            Load arriving from the{' '}
            <span className="font-semibold">{attribution.direction}</span>
          </p>
          {top.length > 0 && (
            <p className="mt-0.5 text-xs text-slate-500">Strongest: {top.join(', ')}</p>
          )}
          <p className="mt-1 text-xs text-slate-400">
            {Math.round(conf * 100)}% confidence · pollution rose
          </p>
        </div>
      </div>
    </div>
  )
}
