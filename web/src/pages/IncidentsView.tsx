import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { MousePointerClick } from 'lucide-react'
import { useSearchParams } from 'react-router-dom'
import AppShell from '../components/AppShell'
import EmptyIncidentState from '../components/incidents/EmptyIncidentState'
import IncidentDetailPanel from '../components/incidents/IncidentDetailPanel'
import IncidentList, { type IncidentListPagination } from '../components/incidents/IncidentList'
import IncidentQueueSidebar from '../components/incidents/IncidentQueueSidebar'
import { fetchAllWardsAqi } from '../lib/data'
import { inQueue, SEVERITY_RANK, type QueueKey, type Severity } from '../lib/incidentRules'
import {
  getIncidentDetail,
  listClosedIncidents,
  listIncidents,
  listLeadingSourceCategories,
  listRecurrenceQueueIncidents,
  type Incident,
  type IncidentsPage,
} from '../lib/incidents'
import { useAsync } from '../lib/useAsync'

/**
 * Command incident queue — the Outlook-style list-detail-action workspace the
 * plan makes the *primary* command surface (§18-19). Redesigned onto the
 * design-token/lucide-icon system introduced for the Overview page: real
 * icons, status.* badges, denser rows with pollutant/reading/likely-source/
 * status. The underlying 3-pane structure, data fetching, and every action's
 * gating logic are unchanged from the prior Phase 11 redesign - only the
 * presentation layer and 2 small, real data joins (leading source category,
 * ward-level current reading) were added. See components/incidents/ for the
 * extracted pieces (IncidentQueueSidebar, IncidentList/IncidentListItem,
 * IncidentDetailPanel/IncidentStatusHeader/IncidentActionBar).
 *
 * Added alongside the existing /command dashboard rather than replacing it: the
 * dashboard still works and is still useful, and the migration rule is to keep
 * the app usable while a new flow is proven.
 */

// The 5 "open" queues are loaded in full (an incomplete view of what's
// currently unresolved is dangerous, not just cosmetically wrong) - only
// `closed` and `recurrence` are paginated, since closed incidents are the
// one historical record that grows unboundedly. See listClosedIncidents'
// own comment in incidents.ts for the offset-vs-keyset trade-off.
const OPEN_QUEUE_ORDER: QueueKey[] = ['active', 'predicted', 'verification', 'assigned', 'escalated']
const PAGE_SIZE = 50
// Comfortably above the project's own forward-looking target (~5,000
// incidents, most of which are closed and excluded here) - if this is ever
// hit, the banner below says so explicitly rather than silently truncating.
const OPEN_QUEUE_CAP = 1000

interface PaginatedQueueState {
  rows: Incident[]
  totalCount: number
  hasMore: boolean
  loading: boolean
  error: string | null
}
const EMPTY_PAGE: PaginatedQueueState = { rows: [], totalCount: 0, hasMore: false, loading: false, error: null }

export default function IncidentsView() {
  const [queue, setQueue] = useState<QueueKey>('active')
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [activeTab, setActiveTab] = useState('overview')
  const [searchParams] = useSearchParams()
  const appliedDeepLinkRef = useRef(false)

  // The 5 open queues, loaded in full (capped defensively - see OPEN_QUEUE_CAP).
  const list = useAsync(() => listIncidents({ limit: OPEN_QUEUE_CAP, excludeClosed: true }), [], {
    staleAfterMs: 120_000,
  })
  const openIncidents = useMemo(() => list.data ?? [], [list.data])

  // Ward-level live AQI, for the "current reading" column/fact - fetched once
  // per page load, independent of queue, reused from the Overview page's own
  // data.ts function. Real data, not a new backend endpoint.
  const wardAqi = useAsync(fetchAllWardsAqi, [])
  const wardAqiById = useMemo(() => new Map(wardAqi.data?.map((w) => [w.id, w.aqi]) ?? []), [wardAqi.data])

  // `closed` and `recurrence` are paginated independently of each other and
  // of the open set — see listClosedIncidents/listRecurrenceQueueIncidents
  // in incidents.ts. Lazy-loaded: only fetched once the commander actually
  // opens that tab, not on every page load.
  const [closedState, setClosedState] = useState<PaginatedQueueState>(EMPTY_PAGE)
  const [recurrenceState, setRecurrenceState] = useState<PaginatedQueueState>(EMPTY_PAGE)

  const loadPaginatedQueue = useCallback(
    async (kind: 'closed' | 'recurrence', reset: boolean) => {
      const setState = kind === 'closed' ? setClosedState : setRecurrenceState
      const fetcher = kind === 'closed' ? listClosedIncidents : listRecurrenceQueueIncidents
      const currentRows = kind === 'closed' ? closedState.rows : recurrenceState.rows
      setState((s) => ({ ...s, loading: true, error: null }))
      try {
        const offset = reset ? 0 : currentRows.length
        const page: IncidentsPage = await fetcher({ offset, pageSize: PAGE_SIZE })
        setState({
          rows: reset ? page.rows : [...currentRows, ...page.rows],
          totalCount: page.totalCount,
          hasMore: page.hasMore,
          loading: false,
          error: null,
        })
      } catch (err) {
        setState((s) => ({ ...s, loading: false, error: err instanceof Error ? err.message : 'Could not load' }))
      }
    },
    [closedState.rows, recurrenceState.rows],
  )

  useEffect(() => {
    if (queue === 'closed' && closedState.rows.length === 0 && !closedState.loading) loadPaginatedQueue('closed', true)
    if (queue === 'recurrence' && recurrenceState.rows.length === 0 && !recurrenceState.loading) {
      loadPaginatedQueue('recurrence', true)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queue])

  const counts = useMemo(() => {
    const c = {} as Record<QueueKey, number>
    for (const q of OPEN_QUEUE_ORDER) c[q] = openIncidents.filter((i) => inQueue(i, q)).length
    c.closed = closedState.totalCount
    c.recurrence = recurrenceState.totalCount
    return c
  }, [openIncidents, closedState.totalCount, recurrenceState.totalCount])

  const visibleRows = useMemo(() => {
    if (queue === 'closed') return closedState.rows
    if (queue === 'recurrence') return recurrenceState.rows
    return openIncidents
      .filter((i) => inQueue(i, queue))
      .sort((a, b) => {
        // Worst first, then oldest — the queue is a work order, not a feed.
        // (closed/recurrence are already resolved, so they stay in the
        // server's detected_at-desc order instead - most recently closed first.)
        const sa = SEVERITY_RANK[(a.severity ?? 'low') as Severity] ?? 0
        const sb = SEVERITY_RANK[(b.severity ?? 'low') as Severity] ?? 0
        if (sa !== sb) return sb - sa
        return new Date(a.detected_at).getTime() - new Date(b.detected_at).getTime()
      })
  }, [openIncidents, queue, closedState.rows, recurrenceState.rows])

  // Likely source per visible row - bulk-fetched for whichever queue is on
  // screen (refetches on queue switch / pagination, matching visibleRows).
  const leadingSource = useAsync(
    () => listLeadingSourceCategories(visibleRows.map((i) => i.id)),
    [visibleRows],
  )
  const leadingSourceById = leadingSource.data ?? new Map()

  // Deep-link support (?incident=<id>) — e.g. a Tasks-page row linking
  // straight into this incident's detail workspace instead of the bare
  // queue. Applied once list.data is loaded, and only once per page load:
  // switches to whichever queue actually contains the incident (it may not
  // be in the default 'active' queue), then selects it. Scoped to the open
  // set only — in practice every real deep-link source (the Tasks page)
  // only ever links to incidents with an active dispatch, which are never
  // closed, so this scoping is not a real limitation today.
  useEffect(() => {
    if (appliedDeepLinkRef.current || list.loading) return
    const raw = searchParams.get('incident')
    if (raw == null) return
    const id = Number(raw)
    const target = openIncidents.find((i) => i.id === id)
    if (!target) return
    appliedDeepLinkRef.current = true
    setQueue(OPEN_QUEUE_ORDER.find((q) => inQueue(target, q)) ?? 'active')
    setSelectedId(id)
  }, [searchParams, list.loading, openIncidents])

  const detailId = selectedId != null && visibleRows.some((i) => i.id === selectedId) ? selectedId : null

  const detail = useAsync(
    () => (detailId == null ? Promise.resolve(null) : getIncidentDetail(detailId)),
    [detailId],
    { enabled: detailId != null },
  )

  // A new incident selection always starts on Overview — staying on e.g.
  // "Dispatch" from the previously-viewed incident would be a confusing
  // leftover, not a deliberate choice.
  useEffect(() => {
    setActiveTab('overview')
  }, [detailId])

  const refreshBoth = useCallback(() => {
    list.refresh()
    detail.refresh()
  }, [list, detail])

  const paginatedState = queue === 'closed' ? closedState : queue === 'recurrence' ? recurrenceState : null
  const activeLoading = paginatedState ? paginatedState.loading && visibleRows.length === 0 : list.loading
  const activeError = paginatedState ? paginatedState.error : list.error
  const refreshActiveQueue = () => (paginatedState ? loadPaginatedQueue(queue as 'closed' | 'recurrence', true) : list.refresh())

  const pagination: IncidentListPagination | null = paginatedState
    ? {
        totalCount: paginatedState.totalCount,
        hasMore: paginatedState.hasMore,
        loadingMore: paginatedState.loading,
        onLoadMore: () => loadPaginatedQueue(queue as 'closed' | 'recurrence', false),
      }
    : null

  const selectedWardId = detail.data?.incident.ward_id ?? null
  const selectedWardAqi = selectedWardId != null ? (wardAqiById.get(selectedWardId) ?? null) : null

  return (
    <AppShell
      subtitle="Incidents"
      secondaryNav={<IncidentQueueSidebar counts={counts} active={queue} onSelect={setQueue} />}
    >
      <div className="flex min-h-0 flex-1 flex-col lg:flex-row">
        {/* ── list column: hidden on mobile once an incident is selected ── */}
        <div
          className={`min-h-0 w-full flex-col border-b border-slate-200 bg-white lg:flex lg:w-80 lg:border-b-0 lg:border-r ${
            detailId != null ? 'hidden lg:flex' : 'flex'
          }`}
        >
          <IncidentList
            queue={queue}
            visibleRows={visibleRows}
            detailId={detailId}
            onSelectIncident={setSelectedId}
            wardAqiById={wardAqiById}
            leadingSourceById={leadingSourceById}
            loading={activeLoading}
            error={activeError}
            onRefresh={refreshActiveQueue}
            refreshing={paginatedState ? paginatedState.loading : list.refreshing}
            stale={!paginatedState && list.stale}
            capHit={!paginatedState && openIncidents.length >= OPEN_QUEUE_CAP}
            pagination={pagination}
            showStaleFooter={!paginatedState && !!list.error && !list.loading && (list.data?.length ?? 0) > 0}
          />
        </div>

        {/* ── detail column: hidden on mobile until an incident is selected;
              a full-screen page there, not a squeezed side column ── */}
        <div
          className={`min-h-0 flex-1 flex-col bg-slate-50 lg:flex ${detailId != null ? 'flex' : 'hidden lg:flex'}`}
        >
          {detailId == null ? (
            <EmptyIncidentState icon={MousePointerClick}>
              Select an incident to see its evidence workspace.
            </EmptyIncidentState>
          ) : (
            <IncidentDetailPanel
              detail={detail}
              activeTab={activeTab}
              onTabChange={setActiveTab}
              onRefresh={refreshBoth}
              onBack={() => setSelectedId(null)}
              wardAqi={selectedWardAqi}
            />
          )}
        </div>
      </div>
    </AppShell>
  )
}
