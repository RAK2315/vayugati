import { CheckCircle2, RefreshCw } from 'lucide-react'
import { ErrorState, Skeleton, StaleBadge } from '../ui'
import { QUEUE_LABELS, type QueueKey, type SourceCategory, ESCALATION_SLA_HOURS } from '../../lib/incidentRules'
import type { Incident } from '../../lib/incidents'
import EmptyIncidentState from './EmptyIncidentState'
import IncidentListItem from './IncidentListItem'

export interface IncidentListPagination {
  totalCount: number
  hasMore: boolean
  loadingMore: boolean
  onLoadMore: () => void
}

/** The list column - queue header (label/count/stale badge/refresh), the cap
 *  banner, the scrollable row list, load-more (paginated queues only), and
 *  the "refresh failed, showing last data" footer. Extracted from
 *  IncidentsView.tsx's own JSX, restyled - same data, same states. */
export default function IncidentList({
  queue,
  visibleRows,
  detailId,
  onSelectIncident,
  wardAqiById,
  leadingSourceById,
  loading,
  error,
  onRefresh,
  refreshing,
  stale,
  capHit,
  pagination,
  showStaleFooter,
}: {
  queue: QueueKey
  visibleRows: Incident[]
  detailId: number | null
  onSelectIncident: (id: number) => void
  wardAqiById: Map<number, number | null>
  leadingSourceById: Map<number, SourceCategory>
  loading: boolean
  error: string | null
  onRefresh: () => void
  refreshing: boolean
  stale: boolean
  capHit: boolean
  pagination: IncidentListPagination | null
  showStaleFooter: boolean
}) {
  return (
    <>
      <div className="flex items-center gap-2 border-b border-slate-100 px-3 py-2">
        <h2 className="text-xs font-semibold uppercase tracking-wide text-slate-500">{QUEUE_LABELS[queue]}</h2>
        <span className="rounded bg-slate-100 px-1.5 text-[10px] font-bold text-slate-600">
          {pagination ? `${visibleRows.length} of ${pagination.totalCount}` : visibleRows.length}
        </span>
        {stale && <StaleBadge />}
        <button
          type="button"
          onClick={onRefresh}
          className="focus-ring ml-auto flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-semibold text-accent-700 hover:bg-slate-50"
        >
          <RefreshCw className={`h-3 w-3 ${refreshing ? 'animate-spin' : ''}`} aria-hidden />
          Refresh
        </button>
      </div>

      {capHit && (
        <p className="border-b border-status-warning/30 bg-status-warning/10 px-3 py-1.5 text-[11px] text-slate-700">
          Showing the highest-priority open incidents only — more may exist.
        </p>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto">
        {loading ? (
          <div className="space-y-2 p-3">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-20 w-full" />
            ))}
          </div>
        ) : error ? (
          <ErrorState message={error} onRetry={onRefresh} />
        ) : visibleRows.length === 0 ? (
          <EmptyIncidentState icon={CheckCircle2}>
            {queue === 'escalated'
              ? `No incident has been open longer than ${ESCALATION_SLA_HOURS}h without action.`
              : queue === 'predicted'
                ? 'No incidents are currently trending toward a threshold crossing. The automated detection engine re-evaluates every monitoring station on each ingest cycle.'
                : `Nothing in ${QUEUE_LABELS[queue].toLowerCase()}.`}
          </EmptyIncidentState>
        ) : (
          <>
            <ul>
              {visibleRows.map((i) => (
                <IncidentListItem
                  key={i.id}
                  incident={i}
                  wardAqi={i.ward_id != null ? (wardAqiById.get(i.ward_id) ?? null) : null}
                  leadingSource={leadingSourceById.get(i.id) ?? null}
                  selected={i.id === detailId}
                  onSelect={() => onSelectIncident(i.id)}
                />
              ))}
            </ul>
            {pagination?.hasMore && (
              <div className="p-2">
                <button
                  type="button"
                  disabled={pagination.loadingMore}
                  onClick={pagination.onLoadMore}
                  className="focus-ring w-full rounded-lg border border-slate-200 py-1.5 text-[11px] font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
                >
                  {pagination.loadingMore
                    ? 'Loading…'
                    : `Load more (${pagination.totalCount - visibleRows.length} remaining)`}
                </button>
              </div>
            )}
          </>
        )}
      </div>

      {showStaleFooter && (
        <p className="border-t border-slate-100 bg-status-warning/10 px-3 py-1.5 text-[11px] text-slate-600">
          Showing the last data loaded - refresh failed.
        </p>
      )}
    </>
  )
}
