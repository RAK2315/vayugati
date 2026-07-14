import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { LogoMark } from '../components/AppShell'
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
    <div className="relative flex min-h-[100dvh] items-center justify-center overflow-hidden bg-slate-50 px-4">
      {/* soft brand aura */}
      <div className="pointer-events-none absolute -top-40 left-1/2 h-96 w-96 -translate-x-1/2 rounded-full bg-brand-200/40 blur-3xl" />
      <div className="pointer-events-none absolute bottom-0 right-0 h-72 w-72 rounded-full bg-sky-200/30 blur-3xl" />

      <div className="relative w-full max-w-sm animate-fade-in">
        <div className="mb-6 flex flex-col items-center text-center">
          <LogoMark className="h-12 w-12" />
          <h1 className="mt-3 text-2xl font-extrabold tracking-tight text-slate-900">Vayu Gati</h1>
          <p className="mt-1 text-sm text-slate-500">जानकारी से कार्यवाही तक</p>
          <p className="text-xs text-slate-400">from information to action</p>
        </div>

        <form onSubmit={signIn} className="card space-y-4 p-6">
          <div className="space-y-3">
            <div>
              <label className="mb-1 block text-xs font-medium text-slate-500">Email</label>
              <input
                type="email"
                required
                autoComplete="email"
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm outline-none transition focus:border-brand-400 focus:bg-white focus:ring-2 focus:ring-brand-100"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-slate-500">Password</label>
              <input
                type="password"
                required
                minLength={6}
                autoComplete="current-password"
                placeholder="••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm outline-none transition focus:border-brand-400 focus:bg-white focus:ring-2 focus:ring-brand-100"
              />
            </div>
          </div>

          {error && <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-600">{error}</p>}
          {message && <p className="rounded-lg bg-green-50 px-3 py-2 text-sm text-green-700">{message}</p>}

          <div className="flex gap-2">
            <button
              type="submit"
              disabled={busy}
              className="flex-1 rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700 disabled:opacity-50"
            >
              {busy ? 'Please wait…' : 'Sign in'}
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={signUp}
              className="flex-1 rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-semibold text-slate-700 transition hover:bg-slate-50 disabled:opacity-50"
            >
              Sign up
            </button>
          </div>
        </form>

        <p className="mt-4 text-center text-xs text-slate-400">
          Delhi ward-level air quality · forecast · response
        </p>
      </div>
    </div>
  )
}
