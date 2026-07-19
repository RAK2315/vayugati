# Delhi Data Gap Report

Last updated: 2026-07-25 (Phase 11 - Delhi pilot validation).

An honest audit of Delhi's ACTUAL configured data (verified against the
disposable local Postgres rebuilt from every migration - the same schema
the hosted project would have once migrated, per
[DEPLOYMENT.md](DEPLOYMENT.md)), not aspirational documentation.

## Current state (measured, not assumed)

| Item | Count | Detail |
|---|---|---|
| Wards | 13 | The full seeded Delhi hotspot set (`schema.sql`) |
| Stations configured | 13 | `ingest/stations.yaml` |
| Stations resolved to a real OpenAQ location | 11 of 13 | R.K. Puram and Mayapuri are `openaq_location_id: null` - explicitly marked "DO NOT GUESS" in the file's own comment, never fabricated |
| `responsibility_registry` rows (Delhi) | 4 | All city-wide (`ward_id` null or generic), none with `team_name`, `contact_channel`, or `working_hours` filled in; **0 of 4 are `mapping_confidence = 'verified'`** (all `estimated`) |
| `sla_rules` rows (Delhi) | 3 | Severe-severity fast lane, penalty-type fast lane, one default - all from the Phase 9/10 seed, none pilot-tuned |
| `intervention_playbooks` rows (Delhi) | 6 | Seeded in Phase 5, all `is_active = true` |
| `field_officer` profiles | **0** | No real field officer accounts exist anywhere in the seed data - role/profile creation is manual SQL/Supabase Auth signup, never fabricated by a migration |
| Pollutant coverage | PM2.5, PM10, NO2 (city `pollutant_priority`) | SO2/CO/O3 columns exist in `readings` but are not in Delhi's priority list - not actively monitored for anomaly detection |
| Reading freshness / historical completeness | Not assessable from seed data alone | Depends entirely on the ingest service actually running against real OpenAQ stations - see [HISTORICAL_REPLAY_REPORT.md](HISTORICAL_REPLAY_REPORT.md) for what REAL historical Delhi station data looks like (real gaps of 4-6+ consecutive days are common) |
| Weather availability | Real Open-Meteo integration exists (`ingest/app/open_meteo.py`) | Not per-station - one coordinate's forecast/archive applied per ward at ingest time, an existing, already-documented simplification (see [DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md)) |
| Station sensor type | All seeded as `regulatory` (test fixtures) / unspecified in `stations.yaml` itself | `sensor_type` is a real column (`regulatory`/`indicative`/`low_cost`) used to caveat confidence, but the REAL 11 resolved Delhi stations' actual sensor type has not been individually confirmed against OpenAQ metadata in this pass |

## Gap table

| Gap | Classification | Why |
|---|---|---|
| 2 of 13 stations unresolved (R.K. Puram, Mayapuri) | **Acceptable during limited pilot** | 11 of 13 is a workable starting footprint; resolving the remaining 2 needs a human to find the correct OpenAQ location id, not a code change |
| `responsibility_registry` has zero verified, ward-specific rows | **Required before pilot** for any ward where operational dispatch will run unattended | Routing will read `probable` (city-wide match), never `confirmed`, until a real ward-specific verified row exists - `dispatch_intervention_task` still functions, but every dispatch in Delhi today would route on a city-wide guess, not a specific unit |
| Zero `team_name`/`contact_channel`/`working_hours`/`escalation_hierarchy` values | **Required before pilot** for the escalation/notification mechanisms to mean anything operationally | The Phase 9 schema exists and is tested; the DATA to make it operationally real does not exist yet - see `RESPONSIBILITY_REGISTRY_IMPORT_TEMPLATE.csv` |
| **Zero field_officer accounts** | **Hard blocker for any real dispatch** | A dispatch can be created and routed, but there is no real person to acknowledge/accept/complete a task - this is the single most concrete "not ready" fact this audit found |
| SLA rules are generic (3 rows, not per-agency/per-ward) | **Acceptable during limited pilot** | The 2-hour severe-severity / 4-hour default targets are defensible starting points (documented, arguable constants, matching this codebase's own established discipline) - refining per-agency SLAs is a tuning exercise, not a blocker |
| Playbooks (6) are generic, not ward-tuned | **Acceptable during limited pilot** | A generic dust-suppression/inspection playbook is a reasonable starting point; ward-specific playbook variants are an optimisation, not a requirement |
| SO2/CO/O3 not in Delhi's `pollutant_priority` | **Optional improvement** | PM2.5/PM10/NO2 covers the dominant, best-understood Delhi pollutants; adding the others needs the same domain-expert threshold review already flagged in [DATA_QUALITY_AND_SCIENCE.md](DATA_QUALITY_AND_SCIENCE.md) limitation 14 |
| Station sensor type not individually re-verified against OpenAQ metadata | **Optional improvement** | `sensor_type` defaults reasonably; a full per-station audit against OpenAQ's own metadata would sharpen the existing regulatory-vs-indicative confidence caveat but is not blocking |
| No real historical completeness/freshness baseline for the ACTUAL configured stations | **Acceptable during limited pilot, monitor immediately** | The historical replay (real Dec 2018 data, 4 of the 11 resolved stations) shows real, substantial missingness is normal for these sensors - this should be watched via the System Health screen from day one, not treated as a pre-pilot blocker, since it reflects real government sensor behaviour this project does not control |

## What this means concretely

**Delhi's SCHEMA is fully ready** (12 migrations, additive, idempotent,
195+ SQL test assertions passing). **Delhi's OPERATIONAL DATA is not** -
zero real officers, zero verified registry mappings, zero real contact
channels. A pilot could technically run today (dispatch would create
real, correctly-audited `task_dispatches` rows), but every dispatch would
have nobody real to acknowledge it and would route on a city-wide guess
rather than a specific, verified unit. This is the concrete, measured
basis for this phase's pilot-readiness scoring - see
[PILOT_READINESS_REPORT.md](PILOT_READINESS_REPORT.md).

## Filling these gaps

See `supabase/RESPONSIBILITY_REGISTRY_IMPORT_TEMPLATE.csv` for the exact
import template a real pilot operator should use to populate
`responsibility_registry` with real agency/team/contact data, before
enabling `operational_dispatch` unattended.

### Import validation rules (reject, don't silently accept, an incomplete or contradictory row)

Before any row from the template is inserted:

1. **`city_code` must resolve to an existing, active `city_config` row.**
   Reject if not - never auto-create a city from an import file.
2. **`source_category` must be one of the schema's real enum values**
   (`road_dust`, `construction_dust`, `vehicular`, `open_burning`,
   `industrial`, `waste`, `other`). Reject anything else rather than
   coercing it to `other` silently.
3. **`ward_name`, if given, must resolve to an existing ward in that
   city.** A row with no ward is a legitimate CITY-WIDE mapping (matches
   the existing `ward_id is null` pattern already used by the Delhi seed)
   - but a ward name that does NOT match any real ward must be rejected,
   never silently dropped to city-wide.
4. **`regulating_authority` must not be blank.** A row with no named
   authority at all provides nothing routing can use - reject it rather
   than importing a mapping that can only ever resolve to `unresolved`.
5. **`contact_channel_phone` and `contact_channel_email` cannot BOTH be
   blank.** At least one real contact path must exist, or the mapping is
   operationally useless even if it "resolves."
6. **`working_hours` must parse as a recognisable day/time range** (this
   repo does not prescribe a single format, but the import step must
   reject anything that fails a basic sanity parse) - never store an
   unparseable string silently, since `working_hours` is meant to be read
   programmatically later (e.g. to warn a commander that a unit is
   currently off-shift).
7. **`escalation_hierarchy`, if given, must be valid JSON matching the
   `[{"level": int, "role": text, "contact": text}]` shape** (see
   [DATA_MODEL.md](DATA_MODEL.md)'s Phase 9 section) - reject malformed
   JSON rather than storing a string that will silently fail to parse
   later when `escalate_stale_task_dispatches` needs it.
8. **`supported_intervention_types`, if given, must be a `;`-separated
   list of real action `type` values this repo actually uses** (`inspect`,
   `sprinkle`, `notice`, `penalty`, `stop_work`, `closure`, `restriction`,
   `prosecution`, ...) - an empty value is fine (means "not yet
   specified," matching the existing default), but a value naming an
   intervention type that doesn't exist must be rejected, not silently
   ignored.
9. **`mapping_confidence` must be one of `verified`/`estimated`/`legacy`.**
   A newly-imported row should almost always be `estimated` until someone
   has actually confirmed it against a real, current source - `verified`
   should require a non-blank `mapping_source` AND `verification_date`.
10. **No two active rows for the same `city_code` + `source_category` +
    `ward_name` combination** - a contradictory duplicate (two different
    agencies claiming the same city+category+ward) must be rejected and
    surfaced to a human, not silently imported as two competing rows that
    would make `_resolve_task_routing`'s own tie-breaking pick one
    arbitrarily.

**Never invent real officer names, phone numbers, or emails to fill a
blank field** - a row with genuinely unknown contact information should be
imported with `mapping_confidence = 'estimated'` and the contact fields
left blank, not populated with a plausible-looking placeholder. A blank,
honestly-incomplete row is safer than a confidently wrong one, since the
routing/escalation engines already treat a missing contact as "not yet
specified" rather than "supports nothing" (see [DATA_MODEL.md](DATA_MODEL.md)).
