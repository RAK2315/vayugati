import { useState } from 'react'
import { Navigate } from 'react-router-dom'
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
    setBusy(true)
    setError(null)
    setMessage(null)
    const { error } = await supabase.auth.signUp({ email, password })
    if (error) setError(error.message)
    else setMessage('Account created. If email confirmation is on, check your inbox, then sign in.')
    setBusy(false)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-100 px-4">
      <form onSubmit={signIn} className="w-full max-w-sm space-y-4 rounded-lg bg-white p-6 shadow">
        <div>
          <h1 className="text-xl font-semibold text-gray-900">Vayu Gati</h1>
          <p className="text-sm text-gray-500">Jankari se karyavahi tak</p>
        </div>
        <input
          type="email"
          required
          placeholder="Email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="w-full rounded border border-gray-300 px-3 py-2"
        />
        <input
          type="password"
          required
          minLength={6}
          placeholder="Password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="w-full rounded border border-gray-300 px-3 py-2"
        />
        {error && <p className="text-sm text-red-600">{error}</p>}
        {message && <p className="text-sm text-green-700">{message}</p>}
        <div className="flex gap-2">
          <button
            type="submit"
            disabled={busy}
            className="flex-1 rounded bg-gray-900 px-3 py-2 text-white hover:bg-gray-700 disabled:opacity-50"
          >
            Sign in
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={signUp}
            className="flex-1 rounded border border-gray-300 px-3 py-2 text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            Sign up
          </button>
        </div>
      </form>
    </div>
  )
}
