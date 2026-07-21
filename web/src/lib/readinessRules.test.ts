import { describe, expect, it } from 'vitest'
import { buildDataReadinessChecklist } from './readinessRules'

const HEALTHY_INPUT = {
  wardBoundaryCount: 252,
  stationCount: 34,
  activeStationCount: 34,
  forecastFreshCount: 93,
  forecastTotalPairs: 93,
  totalReadingsCount: 44123,
}

describe('buildDataReadinessChecklist', () => {
  it('marks every line "ok" when all real counts are healthy', () => {
    const items = buildDataReadinessChecklist(HEALTHY_INPUT)
    expect(items.every((i) => i.status === 'ok')).toBe(true)
    expect(items).toHaveLength(5)
  })

  it('flags ward boundaries as needing attention when the count is zero', () => {
    const items = buildDataReadinessChecklist({ ...HEALTHY_INPUT, wardBoundaryCount: 0 })
    const item = items.find((i) => i.key === 'wardBoundaries')
    expect(item?.status).toBe('attention')
    expect(item?.detail).toBe('Not loaded')
  })

  it('flags the forecast pipeline as needing attention when nothing is fresh, even with historical runs', () => {
    const items = buildDataReadinessChecklist({ ...HEALTHY_INPUT, forecastFreshCount: 0 })
    const item = items.find((i) => i.key === 'forecastPipeline')
    expect(item?.status).toBe('attention')
    expect(item?.detail).toContain('Stalled')
  })

  it('distinguishes "no runs ever" from "stalled" in the forecast pipeline detail text', () => {
    const items = buildDataReadinessChecklist({ ...HEALTHY_INPUT, forecastFreshCount: 0, forecastTotalPairs: 0 })
    const item = items.find((i) => i.key === 'forecastPipeline')
    expect(item?.detail).toBe('No forecast runs yet')
  })

  it('never claims the forecast gate is anything but always active', () => {
    const items = buildDataReadinessChecklist({ ...HEALTHY_INPUT, forecastTotalPairs: 0 })
    const item = items.find((i) => i.key === 'forecastGate')
    expect(item?.status).toBe('ok')
  })

  it('formats large reading counts with thousands separators, not a bare number', () => {
    const items = buildDataReadinessChecklist(HEALTHY_INPUT)
    const item = items.find((i) => i.key === 'historicalData')
    expect(item?.detail).toContain('44,123')
  })
})
