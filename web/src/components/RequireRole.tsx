import { Navigate } from 'react-router-dom'
import { roleHome, useAuth, type Role } from '../lib/auth'

// Gates a route by role. Not logged in -> /login. Wrong role -> their own home.
export default function RequireRole({
  allow,
  children,
}: {
  allow: Role[]
  children: React.ReactNode
}) {
  const { session, profile, loading } = useAuth()

  if (loading) {
    return <div className="flex h-screen items-center justify-center text-gray-500">Loading…</div>
  }
  if (!session) return <Navigate to="/login" replace />
  if (!profile) return <Navigate to="/login" replace />
  if (!allow.includes(profile.role)) return <Navigate to={roleHome(profile.role)} replace />

  return <>{children}</>
}
