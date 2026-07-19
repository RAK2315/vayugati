import AppShell from '../components/AppShell'
import { Card, CardHeader, EmptyState, ErrorState, Skeleton } from '../components/ui'
import { listCitizenActivity, type CitizenActivity } from '../lib/data'
import { useAsync } from '../lib/useAsync'

/**
 * Citizens — reporter activity across every ward (one of the 5 commander
 * nav items that were previously permanently disabled "coming soon"
 * placeholders). The only page of the five that needed a new migration:
 * profiles_self_read doesn't let commander read another citizen's
 * full_name, so this reads through list_citizen_report_activity(), a
 * narrow SECURITY DEFINER RPC scoped to commander/admin only.
 */

function displayName(c: CitizenActivity): string {
  return c.full_name ?? `Citizen ${c.reporter_id.slice(0, 8)}`
}

function fmtDate(ts: string): string {
  return new Date(ts).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })
}

function CitizenRow({ c }: { c: CitizenActivity }) {
  return (
    <li className="flex items-center justify-between gap-3 px-4 py-2.5">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-800">{displayName(c)}</p>
        <p className="mt-0.5 truncate text-xs text-slate-400">
          Last reported {fmtDate(c.last_report_at)} · {c.ward_count} ward{c.ward_count === 1 ? '' : 's'}
        </p>
      </div>
      <span className="flex-shrink-0 rounded-full bg-slate-100 px-2.5 py-1 text-xs font-bold text-slate-700">
        {c.report_count} report{c.report_count === 1 ? '' : 's'}
      </span>
    </li>
  )
}

export default function CitizensView() {
  const state = useAsync(listCitizenActivity, [])
  const rows = state.data ?? []

  return (
    <AppShell subtitle="Citizens">
      <div className="mx-auto w-full max-w-3xl flex-1 space-y-3 overflow-y-auto bg-slate-50 p-3 sm:p-4">
        <Card>
          <CardHeader
            title="Citizens"
            subtitle={
              rows.length > 0 ? `${rows.length} citizen(s) with at least one report` : 'Citizen reporting activity'
            }
            right={
              <button
                type="button"
                onClick={() => state.refresh()}
                className="focus-ring rounded-lg border border-slate-200 px-2.5 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-50"
              >
                Refresh
              </button>
            }
          />
          {state.loading ? (
            <div className="space-y-2 p-4">
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
            </div>
          ) : state.error ? (
            <ErrorState message={state.error} onRetry={() => state.refresh()} />
          ) : rows.length === 0 ? (
            <EmptyState icon="☺">No citizen reports recorded yet.</EmptyState>
          ) : (
            <ul className="divide-y divide-slate-100">
              {rows.map((c) => (
                <CitizenRow key={c.reporter_id} c={c} />
              ))}
            </ul>
          )}
        </Card>
      </div>
    </AppShell>
  )
}
