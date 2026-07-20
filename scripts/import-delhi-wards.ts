#!/usr/bin/env tsx
/**
 * Phase 2 (Delhi City Pack): import the 250 real MCD ward boundaries
 * (validated in docs/data/delhi-ward-251-review.md) into Supabase.
 *
 * Reads data/delhi/processed/delhi_wards.geojson, keeps only features with
 * Ward_No 1-250 (excludes Ward_No 0 / FID=53, the known attribute-join
 * artifact - see delhi-ward-251-review.md), and upserts them as NEW rows
 * in `wards`, keyed by (city_id, ward_number) - a key the 13 existing
 * seeded hotspot wards never populate, so this can never touch them.
 *
 * Imported rows get is_hotspot = false. This is deliberate: every existing
 * page that reads wards (Overview, Incidents ward filter, the admin
 * Registry form) goes through fetchAllWardsAqi(), which after this phase
 * filters is_hotspot = true - so importing 250 boundary-only wards changes
 * nothing about what those pages show. The Map's new boundary layer reads
 * ALL wards (via fetchAllWardBoundaries()) specifically to include these.
 *
 * Usage:
 *   npm run import:delhi-wards -- --dry-run   (no writes, prints a report)
 *   npm run import:delhi-wards                (writes, same report after)
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createClient } from '@supabase/supabase-js'
import dotenv from 'dotenv'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '..')
const GEOJSON_PATH = path.join(REPO_ROOT, 'data/delhi/processed/delhi_wards.geojson')
const SOURCE_DOCUMENT = 'data/delhi/processed/delhi_wards.geojson (from delhi_wards_opencity_archive.zip)'
const CITY_CODE = 'delhi'
const MIN_WARD_NO = 1
const MAX_WARD_NO = 250
const KNOWN_EXCLUDED_WARD_NO = 0 // FID=53 - see docs/data/delhi-ward-251-review.md

// Load real credentials from ingest/.env if not already in the environment
// (that's where this repo's hosted-project service_role key already lives -
// see ingest/.env.example - rather than requiring a second copy).
if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
  dotenv.config({ path: path.join(REPO_ROOT, 'ingest/.env') })
}

interface RawFeature {
  type: 'Feature'
  properties: Record<string, string | null>
  geometry: { type: 'Polygon' | 'MultiPolygon'; coordinates: unknown }
}

interface MappedRow {
  city_id: number
  ward_number: number
  name: string
  is_hotspot: false
  zone: null
  boundary: RawFeature['geometry']
  metadata: {
    source_fid: string | null
    total_pop: number | null
    sc_pop: number | null
    ac_no: string | null
    ac_name: string | null
    source_document: string
  }
}

interface RejectedRow {
  reason: 'missing_ward_no' | 'non_numeric_ward_no' | 'out_of_range_ward_no' | 'duplicate_ward_no' | 'missing_ward_name'
  fid: string | null
  wardNoRaw: string | null
  wardName: string | null
}

function parseIntOrNull(v: string | null | undefined): number | null {
  if (v == null || v.trim() === '') return null
  const n = Number(v)
  return Number.isInteger(n) ? n : null
}

function classifyFeatures(features: RawFeature[]) {
  const excludedZero: RawFeature[] = []
  const rejected: RejectedRow[] = []
  const candidatesByWardNo = new Map<number, RawFeature[]>()

  for (const f of features) {
    const p = f.properties
    const fid = p.FID ?? null
    const wardNoRaw = p.Ward_No ?? null
    const wardName = p.WardName ?? null

    if (wardNoRaw == null || wardNoRaw.trim() === '') {
      rejected.push({ reason: 'missing_ward_no', fid, wardNoRaw, wardName })
      continue
    }
    const wardNo = parseIntOrNull(wardNoRaw)
    if (wardNo == null) {
      rejected.push({ reason: 'non_numeric_ward_no', fid, wardNoRaw, wardName })
      continue
    }
    if (wardNo === KNOWN_EXCLUDED_WARD_NO) {
      excludedZero.push(f)
      continue
    }
    if (wardNo < MIN_WARD_NO || wardNo > MAX_WARD_NO) {
      rejected.push({ reason: 'out_of_range_ward_no', fid, wardNoRaw, wardName })
      continue
    }
    if (wardName == null || wardName.trim() === '') {
      rejected.push({ reason: 'missing_ward_name', fid, wardNoRaw, wardName })
      continue
    }
    const bucket = candidatesByWardNo.get(wardNo) ?? []
    bucket.push(f)
    candidatesByWardNo.set(wardNo, bucket)
  }

  const duplicateWardNos: number[] = []
  const included: RawFeature[] = []
  for (const [wardNo, feats] of candidatesByWardNo) {
    if (feats.length > 1) {
      duplicateWardNos.push(wardNo)
      for (const f of feats) {
        rejected.push({ reason: 'duplicate_ward_no', fid: f.properties.FID ?? null, wardNoRaw: f.properties.Ward_No ?? null, wardName: f.properties.WardName ?? null })
      }
    } else {
      included.push(feats[0])
    }
  }

  return { included, excludedZero, rejected, duplicateWardNos: duplicateWardNos.sort((a, b) => a - b) }
}

function mapRow(f: RawFeature, cityId: number): MappedRow {
  const p = f.properties
  return {
    city_id: cityId,
    ward_number: Number(p.Ward_No),
    name: (p.WardName ?? '').trim(),
    is_hotspot: false,
    zone: null, // no real zone field in the source - see delhi-ward-251-review.md; never fabricated
    boundary: f.geometry,
    metadata: {
      source_fid: p.FID ?? null,
      total_pop: parseIntOrNull(p.TotalPop),
      sc_pop: parseIntOrNull(p.SC_Pop),
      ac_no: p.AC_No ?? null,
      ac_name: p.AC_Name ?? null,
      source_document: SOURCE_DOCUMENT,
    },
  }
}

async function main() {
  const dryRun = process.argv.includes('--dry-run')

  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error(
      'Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY. Set them in the environment or in ingest/.env (never committed).',
    )
  }
  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  })

  const raw = fs.readFileSync(GEOJSON_PATH, 'utf8')
  const fc = JSON.parse(raw) as { features: RawFeature[] }
  const totalRead = fc.features.length

  const { included, excludedZero, rejected, duplicateWardNos } = classifyFeatures(fc.features)

  const { data: city, error: cityError } = await supabase
    .from('city_config')
    .select('id, city_code, name')
    .eq('city_code', CITY_CODE)
    .single()
  if (cityError || !city) {
    throw new Error(`Could not resolve city_config row for city_code='${CITY_CODE}': ${cityError?.message ?? 'not found'}`)
  }

  // Case-sensitive collision check against wards.name's global unique
  // constraint - reported, never silently worked around. Scoped to the
  // is_hotspot=true seed wards only: colliding with a PREVIOUS run of this
  // same import (is_hotspot=false rows already carrying these exact names)
  // is expected and is exactly what the upsert below is for - re-running
  // this script must be a true no-op, not a false-positive abort.
  const { data: existingHotspotNames, error: namesError } = await supabase
    .from('wards')
    .select('name')
    .eq('is_hotspot', true)
  if (namesError) throw new Error(`Could not read existing hotspot ward names: ${namesError.message}`)
  const existingNameSet = new Set((existingHotspotNames ?? []).map((r) => r.name))
  const nameCollisions = included
    .map((f) => (f.properties.WardName ?? '').trim())
    .filter((name) => existingNameSet.has(name))

  const mapped = included.map((f) => mapRow(f, city.id))

  const missingNameCount = rejected.filter((r) => r.reason === 'missing_ward_name').length

  console.log('=== Delhi ward boundary import ===')
  console.log(`Mode: ${dryRun ? 'DRY RUN (no writes)' : 'LIVE IMPORT'}`)
  console.log(`Delhi city_id: ${city.id} (city_code='${city.city_code}', name='${city.name}')`)
  console.log(`Total features read: ${totalRead}`)
  console.log(`Included (Ward_No 1-${MAX_WARD_NO}, clean): ${mapped.length}`)
  console.log(`Excluded (Ward_No = ${KNOWN_EXCLUDED_WARD_NO}, known artifact): ${excludedZero.length}`)
  console.log(`Rejected (other validation failures): ${rejected.length}`)
  console.log(`  - missing_ward_no: ${rejected.filter((r) => r.reason === 'missing_ward_no').length}`)
  console.log(`  - non_numeric_ward_no: ${rejected.filter((r) => r.reason === 'non_numeric_ward_no').length}`)
  console.log(`  - out_of_range_ward_no: ${rejected.filter((r) => r.reason === 'out_of_range_ward_no').length}`)
  console.log(`  - duplicate_ward_no: ${rejected.filter((r) => r.reason === 'duplicate_ward_no').length}`)
  console.log(`  - missing_ward_name: ${missingNameCount}`)
  console.log(`Duplicate Ward_No values found: ${duplicateWardNos.length ? duplicateWardNos.join(', ') : '(none)'}`)
  console.log(`Name collisions against existing wards.name: ${nameCollisions.length ? nameCollisions.join(', ') : '(none)'}`)
  console.log('Sample mapped row:')
  console.log(JSON.stringify(mapped[0], null, 2))

  if (nameCollisions.length > 0) {
    throw new Error(
      `Aborting: ${nameCollisions.length} imported ward name(s) exactly match an existing wards.name value, which is globally unique. Resolve manually before importing.`,
    )
  }

  if (dryRun) {
    console.log('\nDry run only - no rows written. Re-run without --dry-run to import.')
    return
  }

  const BATCH_SIZE = 100
  let written = 0
  for (let i = 0; i < mapped.length; i += BATCH_SIZE) {
    const batch = mapped.slice(i, i + BATCH_SIZE)
    const { error } = await supabase.from('wards').upsert(batch, { onConflict: 'city_id,ward_number' })
    if (error) throw new Error(`Upsert failed on batch starting at index ${i}: ${error.message}`)
    written += batch.length
  }
  console.log(`\nWrote ${written} ward rows (upserted by city_id + ward_number).`)
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err)
  process.exit(1)
})
