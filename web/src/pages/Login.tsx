import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { LogoWordmark } from '../components/AppShell'
import { roleHome, useAuth } from '../lib/auth'
import { supabase } from '../lib/supabase'

export default function Login() {
  const { session, profile, loading } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  if (session && profile && !loading) {
    return <Navigate to={roleHome(profile.role)} replace />
  }

  const signIn = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    setMessage(null)
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) setError(error.message)
    setBusy(false)
  }

  const signUp = async () => {
    if (!email || password.length < 6) {
      setError('Enter an email and a password of at least 6 characters.')
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    const { error } = await supabase.auth.signUp({ email, password })
    if (error) setError(error.message)
    else setMessage('Account created. If email confirmation is on, check your inbox, then sign in.')
    setBusy(false)
  }

  return (
    <div className="relative flex min-h-[100dvh] items-center justify-center overflow-hidden bg-cream px-4">
      {/* soft brand aura */}
      <div className="pointer-events-none absolute -top-40 left-1/2 h-96 w-96 -translate-x-1/2 rounded-full bg-ink-200/40 blur-3xl" />
      <div className="pointer-events-none absolute bottom-0 right-0 h-72 w-72 rounded-full bg-sky-200/40 blur-3xl" />

      <div className="relative w-full max-w-sm animate-fade-in">
        <div className="mb-6 flex flex-col items-center text-center">
          <LogoWordmark className="h-24 w-auto sm:h-28" />
          <p className="mt-2 text-sm text-ink-500">जानकारी से कार्यवाही तक</p>
          <p className="text-xs text-ink-400">from information to action</p>
        </div>

        <form onSubmit={signIn} className="card space-y-4 p-6">
          <div className="space-y-3">
            <div>
              <label className="mb-1 block text-xs font-medium text-ink-500">Email</label>
              <input
                type="email"
                required
                autoComplete="email"
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="focus-ring w-full rounded-xl border border-ink-200 bg-ink-50 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400 focus:bg-white"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-ink-500">Password</label>
              <input
                type="password"
                required
                minLength={6}
                autoComplete="current-password"
                placeholder="••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="focus-ring w-full rounded-xl border border-ink-200 bg-ink-50 px-3 py-2.5 text-sm outline-none transition focus:border-sky-400 focus:bg-white"
              />
            </div>
          </div>

          {error && <p className="rounded-lg bg-status-critical/10 px-3 py-2 text-sm text-status-critical">{error}</p>}
          {message && <p className="rounded-lg bg-status-success/10 px-3 py-2 text-sm text-status-success">{message}</p>}

          <div className="flex gap-2">
            <button
              type="submit"
              disabled={busy}
              className="focus-ring flex-1 rounded-xl bg-ink-700 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-ink-800 disabled:opacity-50"
            >
              {busy ? 'Please wait…' : 'Sign in'}
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={signUp}
              className="focus-ring flex-1 rounded-xl border border-ink-200 px-4 py-2.5 text-sm font-semibold text-ink-700 transition hover:bg-ink-50 disabled:opacity-50"
            >
              Sign up
            </button>
          </div>
        </form>

        <p className="mt-4 text-center text-xs text-ink-400">
          Delhi City Pack · pan-India air incident response
        </p>
      </div>
    </div>
  )
}
