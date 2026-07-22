/**
 * Pure derivations over LatestReadingReconciliation rows (the CPCB/data.gov
 * vs. OpenAQ reconciliation already fetched from the ingest service - see
 * docs/data/cpcb-data-gov-primary-latest-integration-report.md). No I/O
 * here, unit-tested directly, same convention as overviewRules.ts.
 *
 * Every value below is derived from fields the backend already returns -
 * nothing here adds a new backend concept or fetches anything new.
 */
import type { LatestReadingReconciliation, LatestReadingSource } from './data'

// data.gov.in's real-time feed reports timestamps as a naive
// "DD-MM-YYYY HH:MM:SS" string in IST, not ISO 8601 - the raw string, not a
// converted one, is what the backend returns (see ingest/app/
// latest_readings.py's own _age_minutes, which this mirrors exactly so the
// two stay honest about the same input format). OpenAQ's own timestamp is
// already ISO 8601, so that path just falls through to Date.parse.
const IST_OFFSET_MINUTES = 5.5 * 60
const CPCB_TIMESTAMP_RE = /^(\d{2})-(\d{2})-(\d{4}) (\d{2}):(\d{2}):(\d{2})$/

export function parseFlexibleTimestamp(ts: string): number | null {
  const cpcbMatch = ts.match(CPCB_TIMESTAMP_RE)
  if (cpcbMatch) {
    const [, dd, mm, yyyy, hh, min, ss] = cpcbMatch
    const utcMs = Date.UTC(Number(yyyy), Number(mm) - 1, Number(dd), Number(hh), Number(min), Number(ss))
    return utcMs - IST_OFFSET_MINUTES * 60_000
  }
  const isoMs = Date.parse(ts)
  return Number.isNaN(isoMs) ? null : isoMs
}

/** Minutes between CPCB's and OpenAQ's own last-update for the same
 *  station, when both are present - null (not 0) when either is missing,
 *  since there is nothing real to compare in that case. */
export function timestampMismatchMinutes(cpcbLastUpdate: string | null, openaqLastUpdate: string | null): number | null {
  if (!cpcbLastUpdate || !openaqLastUpdate) return null
  const cpcbMs = parseFlexibleTimestamp(cpcbLastUpdate)
  const openaqMs = parseFlexibleTimestamp(openaqLastUpdate)
  if (cpcbMs == null || openaqMs == null) return null
  return Math.abs(cpcbMs - openaqMs) / 60_000
}

// A station counts as a "timestamp mismatch" once the two sources disagree
// by more than an hour on when the reading was taken - a round, documented
// threshold, not fit to any observed distribution (same convention as
// latest_readings.py's own VALUE_MISMATCH_AQI_THRESHOLD).
export const TIMESTAMP_MISMATCH_MINUTES_THRESHOLD = 60

export type AqSourceLabel = 'CPCB' | 'OpenAQ' | 'Review'

/** Which source is actually behind the displayed reading, in the exact
 *  short vocabulary requested for the Hotspot table. "Review" covers both
 *  an unmatched station and a real value disagreement - both cases where
 *  neither source should be trusted silently. */
export function aqSourceLabel(r: { matched: boolean; sourceUsed: LatestReadingSource; flags: string[] }): AqSourceLabel {
  if (!r.matched || r.flags.includes('value_mismatch')) return 'Review'
  return r.sourceUsed === 'cpcb' ? 'CPCB' : 'OpenAQ'
}

export type DataConfidenceLevel = 'matched' | 'stale' | 'mismatch' | 'no_data'

export const DATA_CONFIDENCE_LABEL: Record<DataConfidenceLevel, string> = {
  matched: 'Matched',
  stale: 'Stale',
  mismatch: 'Mismatch',
  no_data: 'No data',
}

/** One short, honest tier per station - value_mismatch always wins (a
 *  disagreement worth a human's attention, regardless of which source is
 *  currently preferred), then no-data (unmatched, or matched but CPCB had
 *  nothing usable), then staleness of whichever source is ACTUALLY
 *  displayed, then a clean match.
 *
 *  Staleness only ever checks the active source's own flag - `cpcb_stale`
 *  when sourceUsed is 'cpcb', `openaq_stale` when it's 'openaq_fallback' -
 *  never both. Checking the other, unused source's staleness would mark a
 *  perfectly fresh CPCB reading "Stale" just because the OpenAQ fallback
 *  (not what's being shown) happens to be old, which is actively
 *  misleading, not merely imprecise. (By construction, reconcile_latest()
 *  never selects sourceUsed='cpcb' while cpcb_stale is set, so this isn't
 *  just a hypothetical edge case.) */
export function dataConfidenceLevel(r: { matched: boolean; sourceUsed: LatestReadingSource; flags: string[] }): DataConfidenceLevel {
  if (r.flags.includes('value_mismatch')) return 'mismatch'
  if (!r.matched || r.flags.includes('cpcb_missing')) return 'no_data'
  const activeStaleFlag = r.sourceUsed === 'cpcb' ? 'cpcb_stale' : 'openaq_stale'
  if (r.flags.includes(activeStaleFlag)) return 'stale'
  return 'matched'
}

export interface DataSourceTally {
  cpcbMatched: number
  openaqFallback: number
  unmatched: number
  staleOrMismatch: number
}

/** City-wide rollup for Overview's Data Source Confidence strip and
 *  Sensors' station stats - a plain tally of what reconcile_latest() (the
 *  backend) already computed per station, nothing new derived beyond
 *  counting. */
export function tallyDataSourceConfidence(rows: LatestReadingReconciliation[]): DataSourceTally {
  const tally: DataSourceTally = { cpcbMatched: 0, openaqFallback: 0, unmatched: 0, staleOrMismatch: 0 }
  for (const r of rows) {
    if (r.sourceUsed === 'cpcb') tally.cpcbMatched++
    else tally.openaqFallback++
    if (!r.matched) tally.unmatched++
    if (r.flags.some((f) => f === 'cpcb_stale' || f === 'openaq_stale' || f === 'value_mismatch')) {
      tally.staleOrMismatch++
    }
  }
  return tally
}
