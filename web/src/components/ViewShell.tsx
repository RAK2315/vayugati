import MapView from './MapView'
import WardCard from './WardCard'
import { useAuth } from '../lib/auth'

// Phase 0 layout shared by all three role views: ward card + placeholder map.
export default function ViewShell({ title }: { title: string }) {
  const { profile, signOut } = useAuth()
  if (!profile) return null

  return (
    <div className="flex h-screen flex-col bg-gray-100">
      <header className="flex items-center justify-between bg-gray-900 px-4 py-3 text-white">
        <h1 className="text-lg font-semibold">Vayu Gati — {title}</h1>
        <button onClick={signOut} className="rounded bg-gray-700 px-3 py-1 text-sm hover:bg-gray-600">
          Sign out
        </button>
      </header>
      <div className="p-4">
        <WardCard profile={profile} />
      </div>
      <div className="min-h-0 flex-1 px-4 pb-4">
        <div className="h-full overflow-hidden rounded-lg shadow">
          <MapView />
        </div>
      </div>
    </div>
  )
}
