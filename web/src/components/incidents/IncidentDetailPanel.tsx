import { FileCheck, LayoutList, Radar, SearchX, Truck, Wrench } from 'lucide-react'
import IncidentEvidencePanel from '../IncidentEvidencePanel'
import InterventionPanel from '../InterventionPanel'
import PredictedIncidentPanel from '../PredictedIncidentPanel'
import RecurrencePanel from '../RecurrencePanel'
import SourceAttributionPanel from '../SourceAttributionPanel'
import TaskDispatchPanel from '../TaskDispatchPanel'
import { ErrorState, Skeleton, TabPanel, Tabs, type TabItem } from '../ui'
import type { AsyncState } from '../../lib/useAsync'
import type { IncidentDetail } from '../../lib/incidents'
import EmptyIncidentState from './EmptyIncidentState'
import IncidentActionBar from './IncidentActionBar'
import IncidentStatusHeader from './IncidentStatusHeader'

const DETAIL_TABS: TabItem[] = [
  { key: 'overview', label: 'Overview', icon: LayoutList },
  { key: 'evidence', label: 'Evidence', icon: FileCheck },
  { key: 'attribution', label: 'Source attribution', icon: Radar },
  { key: 'intervention', label: 'Intervention', icon: Wrench },
  { key: 'dispatch', label: 'Dispatch', icon: Truck },
]

/** The right pane: loading/error/empty states, then the status header, action
 *  bar, and the 5 existing tab-body panels - all unchanged imports/props, so
 *  every action/gating condition inside them behaves exactly as before. */
export default function IncidentDetailPanel({
  detail,
  activeTab,
  onTabChange,
  onRefresh,
  onBack,
  wardAqi,
}: {
  detail: AsyncState<IncidentDetail | null>
  activeTab: string
  onTabChange: (key: string) => void
  onRefresh: () => void
  onBack?: () => void
  wardAqi: number | null
}) {
  if (detail.loading) {
    return (
      <div className="space-y-3 p-4">
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-40 w-full" />
      </div>
    )
  }
  if (detail.error) {
    return <ErrorState message={detail.error} onRetry={() => detail.refresh()} />
  }
  if (!detail.data) {
    return <EmptyIncidentState icon={SearchX}>This incident is no longer available.</EmptyIncidentState>
  }

  return (
    <>
      <IncidentStatusHeader
        incident={detail.data.incident}
        wardAqi={wardAqi}
        detectionPollutant={detail.data.anomalyCandidates[0]?.pollutant ?? null}
        onBack={onBack}
      />
      <IncidentActionBar incident={detail.data.incident} onRefresh={onRefresh} />
      <Tabs tabs={DETAIL_TABS} active={activeTab} onChange={onTabChange} />
      <div className="min-h-0 flex-1 overflow-y-auto">
        <TabPanel active={activeTab === 'overview'}>
          <PredictedIncidentPanel detail={detail.data} onRefresh={onRefresh} />
          <RecurrencePanel detail={detail.data} onRefresh={onRefresh} />
        </TabPanel>
        <TabPanel active={activeTab === 'evidence'}>
          <IncidentEvidencePanel detail={detail.data} />
        </TabPanel>
        <TabPanel active={activeTab === 'attribution'}>
          <SourceAttributionPanel detail={detail.data} onRefresh={onRefresh} />
        </TabPanel>
        <TabPanel active={activeTab === 'intervention'}>
          <InterventionPanel detail={detail.data} onRefresh={onRefresh} />
        </TabPanel>
        <TabPanel active={activeTab === 'dispatch'}>
          <TaskDispatchPanel detail={detail.data} onRefresh={onRefresh} />
        </TabPanel>
      </div>
    </>
  )
}
