import type { Profile } from '../lib/auth'

// Shared ward card. Phase 0: just proves auth + role + ward wiring.
export default function WardCard({ profile }: { profile: Profile }) {
  return (
    <div className="rounded-lg bg-white p-4 shadow">
      <p className="text-lg font-medium text-gray-900">
        Logged in as {profile.role} — ward: {profile.wardName ?? 'not assigned'}
      </p>
    </div>
  )
}
