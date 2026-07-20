#!/usr/bin/env tsx
/**
 * Imports the two non-MCD jurisdictions inside Delhi's Map viewport - NDMC
 * (New Delhi Municipal Council) and Delhi Cantonment - as real boundary-only
 * `wards` rows, so the Map's ward-boundary layer no longer shows two blank
 * gaps where these areas are. Neither is an MCD ward (no ward_number), so
 * they're upserted by name instead of (city_id, ward_number).
 *
 * Source: OpenStreetMap, via the Overpass API, fetched once and saved to
 * data/delhi/processed/delhi_non_mcd_jurisdictions.geojson (relation 2763541
 * "New Delhi" / operator=New Delhi Municipal Council, and relation 3492183
 * "Delhi Cantonment"). Real, published, ODbL-licensed boundaries - not
 * approximated or hand-drawn. Delhi Cantonment's OSM data carries its own
 * `fixme` tag noting a discrepancy against an official MCD map; preserved
 * honestly in metadata rather than silently dropped.
 *
 * Usage:
 *   npm run import:osm-jurisdictions -- --dry-run
 *   npm run import:osm-jurisdictions
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createClient } from '@supabase/supabase-js'
import dotenv from 'dotenv'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '..')
const GEOJSON_PATH = path.join(REPO_ROOT, 'data/delhi/processed/delhi_non_mcd_jurisdictions.geojson')
const SOURCE_DOCUMENT = 'data/delhi/processed/delhi_non_mcd_jurisdictions.geojson (OpenStreetMap via Overpass API)'
const CITY_CODE = 'delhi'
const DELHI_BOUNDS = { minLng: 76.7, maxLng: 77.7, minLat: 28.2, maxLat: 29.0 }

if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
  dotenv.config({ path: path.join(REPO_ROOT, 'ingest/.env') })
}

interface RawFeature {
  type: 'Feature'
  properties: {
    name: string
    jurisdiction_type: string
    osm_relation_id: number
    osm_name: string | null
    osm_official_name: string | null
    osm_admin_level: string | null
    osm_wikidata: string | null
    osm_fixme: string | null
  }
  geometry: { type: 'Polygon' | 'MultiPolygon'; coordinates: unknown }
}

function coordsInBounds(coords: unknown): boolean {
  if (Array.isArray(coords) && typeof coords[0] === 'number') {
    const [lon, lat] = coords as [number, number]
    return lon >= DELHI_BOUNDS.minLng && lon <= DELHI_BOUNDS.maxLng && lat >= DELHI_BOUNDS.minLat && lat <= DELHI_BOUNDS.maxLat
  }
  return Array.isArray(coords) && coords.every(coordsInBounds)
}

async function main() {
  const dryRun = process.argv.includes('--dry-run')

  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY. Set them in the environment or in ingest/.env.')
  }
  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  })

  const fc = JSON.parse(fs.readFileSync(GEOJSON_PATH, 'utf8')) as { features: RawFeature[] }

  const { data: city, error: cityError } = await supabase
    .from('city_config')
    .select('id, city_code, name')
    .eq('city_code', CITY_CODE)
    .single()
  if (cityError || !city) {
    throw new Error(`Could not resolve city_config row for city_code='${CITY_CODE}': ${cityError?.message ?? 'not found'}`)
  }

  const rows = fc.features.map((f) => {
    if (!coordsInBounds(f.geometry.coordinates)) {
      throw new Error(`Aborting: ${f.properties.name} has coordinates outside the Delhi/NCR bounds - refusing to import.`)
    }
    return {
      city_id: city.id,
      name: f.properties.name,
      is_hotspot: false,
      ward_number: null,
      zone: null,
      boundary: f.geometry,
      metadata: {
        jurisdiction_type: f.properties.jurisdiction_type,
        osm_relation_id: f.properties.osm_relation_id,
        osm_name: f.properties.osm_name,
        osm_official_name: f.properties.osm_official_name,
        osm_admin_level: f.properties.osm_admin_level,
        osm_wikidata: f.properties.osm_wikidata,
        osm_fixme: f.properties.osm_fixme,
        source_document: SOURCE_DOCUMENT,
      },
    }
  })

  const { data: existingByName } = await supabase
    .from('wards')
    .select('name')
    .in(
      'name',
      rows.map((r) => r.name),
    )
  const existingNames = new Set((existingByName ?? []).map((r) => r.name))

  console.log('=== NDMC / Delhi Cantonment jurisdiction import ===')
  console.log(`Mode: ${dryRun ? 'DRY RUN (no writes)' : 'LIVE IMPORT'}`)
  console.log(`Delhi city_id: ${city.id}`)
  console.log(`Features to import: ${rows.length}`)
  for (const r of rows) {
    console.log(`  - ${r.name}: ${existingNames.has(r.name) ? 'will UPDATE existing row' : 'will INSERT new row'}`)
  }

  if (dryRun) {
    console.log('\nDry run only - no rows written. Re-run without --dry-run to import.')
    return
  }

  const { error } = await supabase.from('wards').upsert(rows, { onConflict: 'name' })
  if (error) throw new Error(`Upsert failed: ${error.message}`)
  console.log(`\nWrote ${rows.length} row(s) (upserted by name).`)
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err)
  process.exit(1)
})
