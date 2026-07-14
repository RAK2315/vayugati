import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import RequireRole from './components/RequireRole'
import { AuthProvider, roleHome, useAuth } from './lib/auth'
import CitizenView from './pages/CitizenView'
import CommandView from './pages/CommandView'
import FieldView from './pages/FieldView'
import Login from './pages/Login'

// "/" -> the logged-in user's home view, or /login
function Home() {
  const { session, profile, loading } = useAuth()
  if (loading) {
    return <div className="flex h-screen items-center justify-center text-gray-500">Loading…</div>
  }
  if (!session || !profile) return <Navigate to="/login" replace />
  return <Navigate to={roleHome(profile.role)} replace />
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/login" element={<Login />} />
          <Route
            path="/citizen"
            element={
              <RequireRole allow={['citizen', 'admin']}>
                <CitizenView />
              </RequireRole>
            }
          />
          <Route
            path="/field"
            element={
              <RequireRole allow={['field_officer', 'admin']}>
                <FieldView />
              </RequireRole>
            }
          />
          <Route
            path="/command"
            element={
              <RequireRole allow={['commander', 'admin']}>
                <CommandView />
              </RequireRole>
            }
          />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
