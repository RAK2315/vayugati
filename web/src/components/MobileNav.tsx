import { useLocation, useNavigate } from 'react-router-dom'
import type { RailItem } from './AppShell'

/**
 * Mobile bottom navigation — the mobile counterpart to the desktop icon
 * rail (Phase 11 UI redesign). Not a shrunk rail: a distinct, fixed,
 * bottom-anchored bar with icon+label pairs, sized for thumbs. Shares the
 * same `RailItem` list (and therefore the same role-based enable/disable
 * logic) as the desktop rail via `railItemsForRole`, so the two never drift.
 */
export default function MobileBottomNav({
  items,
}: {
  items: RailItem[]
}) {
  const navigate = useNavigate()
  const location = useLocation()

  return (
    <nav
      aria-label="Primary"
      className="z-rail flex flex-shrink-0 items-stretch justify-around border-t border-slate-200 bg-white pb-[env(safe-area-inset-bottom)] sm:hidden"
    >
      {items
        .filter((item) => item.to || item.key === 'overview')
        .slice(0, 5)
        .map((item) => {
          const active = !!item.to && location.pathname === item.to
          const disabled = !item.to
          return (
            <button
              key={item.key}
              type="button"
              disabled={disabled}
              aria-current={active ? 'page' : undefined}
              onClick={() => item.to && navigate(item.to)}
              className={`focus-ring flex min-w-0 flex-1 flex-col items-center gap-0.5 py-2 text-[10px] font-medium transition ${
                active ? 'text-accent-600' : disabled ? 'text-slate-300' : 'text-slate-500 hover:text-accent-600'
              }`}
            >
              <span className={`text-lg leading-none ${active ? 'text-accent-600' : ''}`} aria-hidden>
                {item.icon}
              </span>
              <span className="truncate leading-none">{item.label}</span>
            </button>
          )
        })}
    </nav>
  )
}
