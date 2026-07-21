import { describe, expect, it } from 'vitest'
import {
  FORECAST_RUN_STALE_HOURS,
  forecastEngineStatusLine,
  modelSelectionExplainer,
  strongestBaselineLabel,
  summarizeBaselineWinners,
  summarizeForecastCoverage,
  summarizeForecastMethodMix,
} from './forecastTrustRules'

// ── method mix ────────────────────────────────────────────────────────────

describe('summarizeForecastMethodMix', () => {
  it('counts lightgbm and diurnal_persistence separately', () => {
    const rows = [
      { method: 'lightgbm' },
      { method: 'lightgbm' },
      { method: 'diurnal_persistence' },
      { method: 'diurnal_persistence' },
      { method: 'diurnal_persistence' },
    ]
    const mix = summarizeForecastMethodMix(rows)
    expect(mix).toEqual({ lightgbmCount: 2, diurnalPersistenceCount: 3, otherCount: 0, total: 5 })
  })

  it('buckets an unexpected method value into otherCount rather than dropping it', () => {
    const mix = summarizeForecastMethodMix([{ method: 'lightgbm' }, { method: 'some_future_method' }])
    expect(mix.otherCount).toBe(1)
    expect(mix.total).toBe(2)
  })

  it('handles an empty array without crashing', () => {
    expect(summarizeForecastMethodMix([])).toEqual({ lightgbmCount: 0, diurnalPersistenceCount: 0, otherCount: 0, total: 0 })
  })
})

// ── baseline winners ─────────────────────────────────────────────────────

describe('summarizeBaselineWinners', () => {
  it('tallies best_baseline across every horizon entry in every row', () => {
    const rows = [
      {
        validation_metrics: {
          '6': { best_baseline: 'same_hour_yesterday' },
          '12': { best_baseline: 'same_hour_yesterday' },
          '24': { best_baseline: 'rolling_24h_avg' },
          '48': { best_baseline: 'persistence' },
        },
      },
      {
        validation_metrics: {
          '6': { best_baseline: 'diurnal' },
        },
      },
    ]
    const tally = summarizeBaselineWinners(rows)
    expect(tally.counts).toEqual({ persistence: 1, diurnal: 1, same_hour_yesterday: 2, rolling_24h_avg: 1 })
    expect(tally.totalHorizonEntries).toBe(5)
    expect(tally.rowsWithBaselineData).toBe(2)
    expect(tally.rowsWithoutBaselineData).toBe(0)
  })

  it('treats an empty validation_metrics object as no-data, not a crash', () => {
    const tally = summarizeBaselineWinners([{ validation_metrics: {} }])
    expect(tally.rowsWithoutBaselineData).toBe(1)
    expect(tally.rowsWithBaselineData).toBe(0)
    expect(tally.totalHorizonEntries).toBe(0)
  })

  it('treats a pre-upgrade row (no best_baseline key at all) as no-data, not a crash', () => {
    // the exact shape written before the baseline-gate upgrade shipped -
    // real fields, just none of the new ones.
    const rows = [
      {
        validation_metrics: {
          '6': { mae: 10.01, rmse: 10.36, bias: 3.24, persistence_mae: 8.97, beats_persistence: false },
          '24': { mae: 12.53, rmse: 14.64, bias: -1.99, persistence_mae: 15.74, beats_persistence: true },
        },
      },
    ]
    const tally = summarizeBaselineWinners(rows)
    expect(tally.rowsWithoutBaselineData).toBe(1)
    expect(tally.rowsWithBaselineData).toBe(0)
    expect(tally.counts).toEqual({ persistence: 0, diurnal: 0, same_hour_yesterday: 0, rolling_24h_avg: 0 })
  })

  it('handles a mixed fleet of old and new rows correctly, not just one or the other', () => {
    const rows = [
      { validation_metrics: { '6': { best_baseline: 'persistence' } } }, // new
      { validation_metrics: { '6': { mae: 5, persistence_mae: 6, beats_persistence: true } } }, // old
      { validation_metrics: {} }, // empty
    ]
    const tally = summarizeBaselineWinners(rows)
    expect(tally.rowsWithBaselineData).toBe(1)
    expect(tally.rowsWithoutBaselineData).toBe(2)
    expect(tally.counts.persistence).toBe(1)
  })

  it('ignores an unrecognized best_baseline value defensively rather than crashing', () => {
    const tally = summarizeBaselineWinners([{ validation_metrics: { '6': { best_baseline: 'some_new_baseline_later' } } }])
    expect(tally.totalHorizonEntries).toBe(0)
    expect(tally.rowsWithoutBaselineData).toBe(1)
  })

  it('handles a null-ish validation_metrics value without crashing', () => {
    // jsonb columns default to {} in this schema, but defend against a raw
    // null slipping through (e.g. a hand-inserted test row) anyway.
    const tally = summarizeBaselineWinners([{ validation_metrics: null as unknown as Record<string, never> }])
    expect(tally.rowsWithoutBaselineData).toBe(1)
  })
})

// ── coverage & staleness ─────────────────────────────────────────────────

describe('summarizeForecastCoverage', () => {
  const now = new Date('2026-07-21T12:00:00Z')

  it('splits fresh vs. stale using FORECAST_RUN_STALE_HOURS', () => {
    const rows = [
      { generated_at: '2026-07-21T11:30:00Z' }, // 30 min ago - fresh
      { generated_at: '2026-07-21T05:00:00Z' }, // 7h ago - stale
    ]
    const summary = summarizeForecastCoverage(rows, now)
    expect(summary.totalPairs).toBe(2)
    expect(summary.freshCount).toBe(1)
    expect(summary.staleCount).toBe(1)
    expect(summary.latestGeneratedAt).toBe('2026-07-21T11:30:00.000Z')
  })

  it('returns zeroed-out, non-crashing output for an empty array', () => {
    const summary = summarizeForecastCoverage([], now)
    expect(summary).toEqual({ totalPairs: 0, staleCount: 0, freshCount: 0, latestGeneratedAt: null })
  })

  it('is exactly on the FORECAST_RUN_STALE_HOURS boundary at the configured constant, not a magic number', () => {
    const boundaryMs = now.getTime() - FORECAST_RUN_STALE_HOURS * 3_600_000 - 1000 // 1s past the boundary
    const rows = [{ generated_at: new Date(boundaryMs).toISOString() }]
    expect(summarizeForecastCoverage(rows, now).staleCount).toBe(1)
  })
})

// ── plain-language framing ───────────────────────────────────────────────

describe('forecastEngineStatusLine', () => {
  it('says nothing recorded yet when there are no pairs at all', () => {
    expect(forecastEngineStatusLine({ totalPairs: 0, staleCount: 0, freshCount: 0, latestGeneratedAt: null })).toMatch(/no forecast/i)
  })

  it('flags a fully-stuck pipeline distinctly from a partially-stale one', () => {
    const stuck = forecastEngineStatusLine({ totalPairs: 5, staleCount: 5, freshCount: 0, latestGeneratedAt: null })
    expect(stuck).toMatch(/may be stuck/i)
  })

  it('reports a clean bill of health when nothing is stale', () => {
    const line = forecastEngineStatusLine({ totalPairs: 31, staleCount: 0, freshCount: 31, latestGeneratedAt: null })
    expect(line).toContain('31')
    expect(line).not.toMatch(/stuck/i)
  })

  it('never uses alarmist language for a partially-stale (but mostly fresh) state', () => {
    const line = forecastEngineStatusLine({ totalPairs: 93, staleCount: 3, freshCount: 90, latestGeneratedAt: null })
    expect(line.toLowerCase()).not.toContain('fail')
    expect(line.toLowerCase()).not.toContain('broken')
  })
})

describe('modelSelectionExplainer', () => {
  it('never claims a low LightGBM rate means the system failed', () => {
    const mix = { lightgbmCount: 1, diurnalPersistenceCount: 92, otherCount: 0, total: 93 }
    const line = modelSelectionExplainer(mix)
    expect(line.toLowerCase()).not.toContain('fail')
    expect(line.toLowerCase()).not.toContain('broken')
    expect(line.toLowerCase()).not.toContain('error')
  })

  it('never claims the baseline fallback is bad', () => {
    const mix = { lightgbmCount: 0, diurnalPersistenceCount: 10, otherCount: 0, total: 10 }
    const line = modelSelectionExplainer(mix)
    expect(line.toLowerCase()).not.toContain('bad')
    expect(line.toLowerCase()).not.toContain('poor')
  })

  it('never claims ML is always better than the baseline', () => {
    const mix = { lightgbmCount: 5, diurnalPersistenceCount: 5, otherCount: 0, total: 10 }
    const line = modelSelectionExplainer(mix)
    expect(line.toLowerCase()).not.toMatch(/ml is (always|better)/)
  })

  it('reports the real count and percentage honestly, not rounded away to nothing', () => {
    const mix = { lightgbmCount: 4, diurnalPersistenceCount: 275, otherCount: 0, total: 279 }
    const line = modelSelectionExplainer(mix)
    expect(line).toContain('4')
    expect(line).toContain('279')
  })

  it('handles zero total without crashing or dividing by zero into NaN', () => {
    const line = modelSelectionExplainer({ lightgbmCount: 0, diurnalPersistenceCount: 0, otherCount: 0, total: 0 })
    expect(line).not.toContain('NaN')
  })
})

describe('strongestBaselineLabel', () => {
  it('returns null when there is no baseline data at all (pre-upgrade rows only)', () => {
    expect(strongestBaselineLabel({ counts: { persistence: 0, diurnal: 0, same_hour_yesterday: 0, rolling_24h_avg: 0 }, totalHorizonEntries: 0, rowsWithBaselineData: 0, rowsWithoutBaselineData: 10 })).toBeNull()
  })

  it('names the baseline with the most wins, human-readable, not the raw key', () => {
    const label = strongestBaselineLabel({
      counts: { persistence: 38, diurnal: 32, same_hour_yesterday: 17, rolling_24h_avg: 37 },
      totalHorizonEntries: 124,
      rowsWithBaselineData: 31,
      rowsWithoutBaselineData: 0,
    })
    expect(label).toContain('Persistence')
    expect(label).not.toContain('persistence_mae') // never leaks a raw field name
  })
})
