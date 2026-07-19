import { useState } from 'react'
import AppShell from '../components/AppShell'
import { Card, CardHeader, EmptyState, ErrorState, Label, Skeleton } from '../components/ui'
import { useAuth } from '../lib/auth'
import { BUILD_INFO } from '../lib/env'
import {
  KNOWN_FEATURE_FLAGS,
  fetchCities,
  fetchPlaybooksForAdmin,
  fetchResponsibilityRegistryForAdmin,
  fetchSlaRulesForAdmin,
  fetchStations,
  fetchSystemHealth,
  getFeatureFlags,
  setCityFeatureFlag,
  setPlaybookActive,
  setRegistryActive,
  setSlaRuleActive,
  setStationActive,
  type CityConfigRow,
  type FeatureFlagName,
} from '../lib/ops'
import { useAsync } from '../lib/useAsync'

/**
 * Operations & pilot administration (Phase 10, plan §10/§18).
 *
 * Deliberately narrow: system health (read-only rollup) + activation
 * toggles for the handful of things a pilot operator genuinely needs to
 * flip without a redeploy (feature flags, stations, responsibility
 * registry, SLA rules, playbooks). Not a general database editor — deeper
 * edits (new playbook fields, registry contact channels, SLA hour values)
 * are still direct SQL, same as the existing "no in-app playbook editor
 * yet" limitation this phase does not attempt to close.
 */

const FEATURE_FLAG_LABEL: Record<FeatureFlagName, string> = {
  anomaly_detection: 'Automated anomaly detection',
  validated_forecasting: 'Validated forecasting',
  source_attribution: 'Source attribution',
  citizen_evidence_missions: 'Citizen evidence missions',
  operational_dispatch: 'Operational dispatch',
  automatic_escalation: 'Automatic escalation',
  notifications_email: 'Email notifications',
  notifications_sms: 'SMS notifications',
  notifications_whatsapp: 'WhatsApp notifications',
}

function StaleBadge({ isStale }: { isStale: boolean }) {
  return (
    <span
      className={`rounded px-1.5 py-0.5 text-[10px] font-bold uppercase ${
        isStale ? 'bg-status-critical/10 text-status-critical' : 'bg-status-success/10 text-status-success'
      }`}
    >
      {isStale ? 'Stale' : 'OK'}
    </span>
  )
}

function SystemHealthSection() {
  const state = useAsync(fetchSystemHealth, [])
  const rows = state.data ?? []

  return (
    <Card>
      <CardHeader
        title="System health"
        subtitle="Last run of every scheduled job — reads the same rollup the ingest service's /health endpoint uses"
        right={
          <button
            type="button"
            onClick={() => state.refresh()}
            className="focus-ring rounded-lg border border-ink-200 px-2.5 py-1 text-xs font-semibold text-ink-700 hover:bg-ink-50"
          >
            Refresh
          </button>
        }
      />
      {state.loading ? (
        <div className="space-y-2 p-4">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-full" />
        </div>
      ) : state.error ? (
        <ErrorState message={state.error} onRetry={() => state.refresh()} />
      ) : rows.length === 0 ? (
        <EmptyState icon="🩺">No job runs recorded yet — jobs record themselves the first time they run.</EmptyState>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-xs">
            <thead className="text-ink-400">
              <tr>
                <th className="px-4 py-2 font-medium">Job</th>
                <th className="px-2 py-2 font-medium">City</th>
                <th className="px-2 py-2 font-medium">Status</th>
                <th className="px-2 py-2 font-medium">Last run</th>
                <th className="px-2 py-2 font-medium">Error</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-ink-900/5">
              {rows.map((r) => (
                <tr key={`${r.job_name}:${r.city_code ?? ''}`}>
                  <td className="px-4 py-2 font-semibold text-ink-800">{r.job_name}</td>
                  <td className="px-2 py-2 text-ink-500">{r.city_code ?? 'all'}</td>
                  <td className="px-2 py-2">
                    <StaleBadge isStale={r.is_stale} />
                    <span className="ml-1.5 text-ink-400">{r.last_status}</span>
                  </td>
                  <td className="px-2 py-2 text-ink-500">
                    {r.last_completed_at ? new Date(r.last_completed_at).toLocaleString() : '—'}
                  </td>
                  <td className="max-w-xs truncate px-2 py-2 text-status-critical" title={r.last_error_message ?? ''}>
                    {r.last_error_message ?? ''}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

function FeatureFlagsSection({ city, onChanged }: { city: CityConfigRow; onChanged: () => void }) {
  const [busy, setBusy] = useState<string | null>(null)
  const flags = getFeatureFlags(city)

  const toggle = async (flag: FeatureFlagName) => {
    setBusy(flag)
    try {
      await setCityFeatureFlag(city, flag, !flags[flag])
      onChanged()
    } finally {
      setBusy(null)
    }
  }

  return (
    <Card>
      <CardHeader title="Feature flags" subtitle={`${city.name} — pause a risky pilot feature without a redeploy`} />
      <ul className="divide-y divide-ink-900/5">
        {KNOWN_FEATURE_FLAGS.map((flag) => (
          <li key={flag} className="flex items-center justify-between px-4 py-2.5">
            <span className="text-sm text-ink-700">{FEATURE_FLAG_LABEL[flag]}</span>
            <button
              type="button"
              disabled={busy === flag}
              onClick={() => toggle(flag)}
              className={`focus-ring rounded-full px-3 py-1 text-xs font-bold uppercase transition disabled:opacity-50 ${
                flags[flag] ? 'bg-status-success/10 text-status-success' : 'bg-ink-100 text-ink-500'
              }`}
            >
              {flags[flag] ? 'On' : 'Off'}
            </button>
          </li>
        ))}
      </ul>
    </Card>
  )
}

function ActivationList<T extends { id: number; is_active: boolean | null }>({
  title,
  subtitle,
  items,
  label,
  onToggle,
}: {
  title: string
  subtitle: string
  items: T[]
  label: (item: T) => string
  onToggle: (item: T) => Promise<void>
}) {
  const [busyId, setBusyId] = useState<number | null>(null)

  const handleToggle = async (item: T) => {
    setBusyId(item.id)
    try {
      await onToggle(item)
    } finally {
      setBusyId(null)
    }
  }

  return (
    <Card>
      <CardHeader title={title} subtitle={subtitle} />
      {items.length === 0 ? (
        <EmptyState icon="—">Nothing configured yet for this city.</EmptyState>
      ) : (
        <ul className="divide-y divide-ink-900/5">
          {items.map((item) => (
            <li key={item.id} className="flex items-center justify-between px-4 py-2.5">
              <span className="text-sm text-ink-700">{label(item)}</span>
              <button
                type="button"
                disabled={busyId === item.id}
                onClick={() => handleToggle(item)}
                className={`focus-ring rounded-full px-3 py-1 text-xs font-bold uppercase transition disabled:opacity-50 ${
                  item.is_active ? 'bg-status-success/10 text-status-success' : 'bg-ink-100 text-ink-500'
                }`}
              >
                {item.is_active ? 'Active' : 'Inactive'}
              </button>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}

function PilotAdminSections({ city }: { city: CityConfigRow }) {
  const { session } = useAuth()
  const stations = useAsync(() => fetchStations(city.id), [city.id])
  const registry = useAsync(() => fetchResponsibilityRegistryForAdmin(city.id), [city.id])
  const slaRules = useAsync(() => fetchSlaRulesForAdmin(city.id), [city.id])
  const playbooks = useAsync(() => fetchPlaybooksForAdmin(city.id), [city.id])

  if (!session) return null

  return (
    <>
      <ActivationList
        title="Stations"
        subtitle="Deactivate a station known to be faulty/offline — anomaly detection skips it immediately; ingestion's own fetch loop is unaffected in this pass"
        items={stations.data ?? []}
        label={(s) => s.name}
        onToggle={async (s) => {
          await setStationActive(s.id, !s.is_active, session.user.id)
          stations.refresh()
        }}
      />
      <ActivationList
        title="Responsibility registry"
        subtitle="An inactive row is skipped by routing resolution entirely"
        items={registry.data ?? []}
        label={(r) => `${r.regulating_authority ?? 'Unnamed unit'}${r.division_zone ? ` · ${r.division_zone}` : ''}`}
        onToggle={async (r) => {
          await setRegistryActive(r.id, !r.is_active)
          registry.refresh()
        }}
      />
      <ActivationList
        title="SLA rules"
        subtitle="An inactive rule is never matched — dispatch falls through to the next most-specific active rule, or the documented default"
        items={slaRules.data ?? []}
        label={(r) => r.slug ?? `Rule #${r.id}`}
        onToggle={async (r) => {
          await setSlaRuleActive(r.id, !r.is_active)
          slaRules.refresh()
        }}
      />
      <ActivationList
        title="Playbooks"
        subtitle="An inactive playbook no longer appears in the field-officer picker"
        items={playbooks.data ?? []}
        label={(p) => p.title}
        onToggle={async (p) => {
          await setPlaybookActive(p.id, !p.is_active)
          playbooks.refresh()
        }}
      />
    </>
  )
}

export default function OpsView() {
  const citiesState = useAsync(fetchCities, [])
  const cities = citiesState.data ?? []
  const [selectedCityId, setSelectedCityId] = useState<number | null>(null)
  const activeCity = cities.find((c) => c.id === selectedCityId) ?? cities[0] ?? null

  return (
    <AppShell subtitle="Operations & pilot admin">
      <div className="mx-auto w-full max-w-3xl flex-1 space-y-3 overflow-y-auto p-4">
        <SystemHealthSection />

        {citiesState.loading ? (
          <Skeleton className="h-24 w-full" />
        ) : citiesState.error ? (
          <ErrorState message={citiesState.error} onRetry={() => citiesState.refresh()} />
        ) : cities.length === 0 ? (
          <EmptyState icon="🏙">No cities configured yet.</EmptyState>
        ) : (
          <>
            {cities.length > 1 && (
              <div className="flex items-center gap-2">
                <Label>City</Label>
                <select
                  value={activeCity?.id ?? ''}
                  onChange={(e) => setSelectedCityId(Number(e.target.value))}
                  className="focus-ring rounded-lg border border-ink-200 px-2 py-1 text-sm"
                >
                  {cities.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </div>
            )}
            {activeCity && (
              <>
                <FeatureFlagsSection city={activeCity} onChanged={() => citiesState.refresh()} />
                <PilotAdminSections city={activeCity} />
              </>
            )}
          </>
        )}

        <p className="pb-2 text-center text-[11px] text-ink-300">
          Build {BUILD_INFO.sha} · {BUILD_INFO.environment}
        </p>
      </div>
    </AppShell>
  )
}
