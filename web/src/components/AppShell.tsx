import type { ReactNode } from 'react'
import { useAuth } from '../lib/auth'

// Wind-motion logo mark — a stylized gust, echoing "Vayu Gati" (air in motion).
export function LogoMark({ className = 'h-7 w-7' }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" className={className} aria-hidden fill="none">
      <rect width="32" height="32" rx="9" fill="url(#vg)" />
      <path
        d="M7 12.5h11.5a3 3 0 1 0-3-3M7 16h15a3.2 3.2 0 1 1-3.2 3.2M7 19.5h7.5"
        stroke="#fff"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <defs>
        <linearGradient id="vg" x1="0" y1="0" x2="32" y2="32" gradientUnits="userSpaceOnUse">
          <stop stopColor="#6366f1" />
          <stop offset="1" stopColor="#4338ca" />
        </linearGradient>
      </defs>
    </svg>
  )
}

const ROLE_LABEL: Record<string, string> = {
  citizen: 'Citizen',
  field_officer: 'Field Officer',
  commander: 'Commander',
  admin: 'Admin',
}

/**
 * Shared app frame. `dark` switches to the command-room palette.
 * Children fill the area below the header.
 */
export default function AppShell({
  subtitle,
  dark = false,
  children,
}: {
  subtitle?: string
  dark?: boolean
  children: ReactNode
}) {
  const { profile, signOut } = useAuth()

  return (
    <div className={`flex h-[100dvh] flex-col ${dark ? 'bg-slate-950 text-slate-100' : 'bg-slate-50 text-slate-900'}`}>
      <header
        className={`flex items-center justify-between gap-3 px-4 py-2.5 ${
          dark ? 'bg-slate-900/80 backdrop-blur' : 'border-b border-slate-200 bg-white/80 backdrop-blur'
        }`}
      >
        <div className="flex items-center gap-2.5">
          <LogoMark />
          <div className="leading-tight">
            <div className="flex items-baseline gap-2">
              <span className="text-[15px] font-bold tracking-tight">Vayu Gati</span>
              {subtitle && (
                <span className={`text-xs font-medium ${dark ? 'text-slate-400' : 'text-slate-400'}`}>
                  {subtitle}
                </span>
              )}
            </div>
            {profile && (
              <div className="flex items-center gap-1.5 text-[11px]">
                <span
                  className={`rounded px-1.5 py-px font-medium ${
                    dark ? 'bg-brand-500/20 text-brand-200' : 'bg-brand-50 text-brand-700'
                  }`}
                >
                  {ROLE_LABEL[profile.role] ?? profile.role}
                </span>
                {profile.wardName && (
                  <span className={dark ? 'text-slate-400' : 'text-slate-500'}>· {profile.wardName}</span>
                )}
              </div>
            )}
          </div>
        </div>
        <button
          onClick={signOut}
          className={`rounded-lg px-3 py-1.5 text-sm font-medium transition ${
            dark
              ? 'bg-slate-800 text-slate-200 hover:bg-slate-700'
              : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
          }`}
        >
          Sign out
        </button>
      </header>
      <main className="flex min-h-0 flex-1 flex-col">{children}</main>
    </div>
  )
}
