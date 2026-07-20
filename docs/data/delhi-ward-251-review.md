# Delhi Ward GeoJSON — 251-Feature Anomaly Review

**Type:** Validation-only review. No Supabase changes, no data import, no app code changes were made while producing this report.
**File reviewed:** `data/delhi/processed/delhi_wards.geojson` (converted from `data/delhi/raw/delhi_wards_opencity_archive.zip`'s `delhi_wards.kml` in Phase 1).
**Trigger:** Delhi's municipal ward structure is commonly referenced as **250 wards**, but the conversion produced **251** features. This report determines whether the 251st feature is a real ward or an artifact.

---

## 1. Total feature count

**251 features**, confirmed by direct count of the `features` array in the GeoJSON.

## 2. Ward_No analysis

| Check | Result |
|---|---|
| Total `Ward_No` values present | 251/251 (the field itself is never absent) |
| Unique `Ward_No` values | 251 (all distinct) |
| Duplicate `Ward_No` values | **0** |
| Non-numeric / unusual `Ward_No` | **0** (every value parses as an integer) |
| Min `Ward_No` | **0** |
| Max `Ward_No` | **250** |
| Gaps in the 0–250 range | **0** — every integer from 0 to 250 is present exactly once |

**This is the key finding.** The range is 0–250 inclusive, which is **251 sequential integers**. Delhi's official ward numbering is 1–250 (250 real wards). A `Ward_No` value of **`0` is not a valid official Delhi ward number** — it functions as a placeholder/default value in this dataset, not a real assigned ward. This single `Ward_No = 0` row is the entire explanation for the 251-vs-250 discrepancy — there is no duplicate among 1–250, and no ward number is skipped.

## 3. WardName analysis

| Check | Result |
|---|---|
| Missing `WardName` | **1** (the same `Ward_No = 0` row) |
| Duplicate `WardName` (among the 250 non-null values) | **0** |
| Unusually generic/short names | **0** |

Every one of the 250 wards numbered 1–250 has a unique, real-looking name (e.g. `NARELA`, `SABAPUR`, `VASANT VIHAR`). Only the anomalous row has no name at all.

## 4. The anomalous feature

`FID = 53`, `Ward_No = "0"`:

```json
{
  "FID": "53",
  "WNo_SEC": "0",
  "AC_No": "44",
  "AC_No_1": "0",
  "AC_Name": null,
  "Ward_No": "0",
  "WardName": null,
  "TotalPop": "0",
  "SC_Pop": "0",
  "NW2022": "0,"
}
```

Compare to its geographic neighbors, all sharing `AC_No = 44` (R K Puram assembly constituency):

| FID | Ward_No | WardName | AC_Name | AC_No_1 | TotalPop |
|---|---|---|---|---|---|
| 15 | 152 | R.K. PURAM | R K PURAM | 44 | 54,347 |
| 63 | 151 | MUNIRKA | R K PURAM | 44 | 64,543 |
| 131 | 153 | VASANT VIHAR | R K PURAM | 44 | 55,960 |
| **53** | **0** | **(null)** | **(null)** | **0** | **0** |

### What the evidence shows

- **`AC_No` is populated correctly (`44`)** and matches its real neighbors exactly — but **`AC_No_1` is `0`** instead of `44`, breaking the pattern every other feature in this constituency follows (where `AC_No` and `AC_No_1` are always identical). This is a strong technical signature of a **failed attribute join** in the source data: one field (`AC_No`) came from a join that succeeded, while every other identifying field (`AC_No_1`, `Ward_No`, `WardName`, `AC_Name`, `TotalPop`, `SC_Pop`) came from a join that silently failed and defaulted to `0`/null, rather than this being a duplicate or stray polygon.
- **The geometry itself is real and unremarkable** — a normal `Polygon` with 918 vertices, bounding box ≈ 0.036° × 0.054°, well within the range of the 250 confirmed-real wards (average bbox width 0.030°, max 0.150°). It is not a whole-city outline, a degenerate sliver, or an empty/near-empty shape.
- **Its location is geographically coherent**, not scattered or off in an unrelated area: its centroid's three nearest neighboring ward centroids are Vasant Vihar, Munirka, and R.K. Puram — the same three named wards that share its `AC_No = 44`. It sits exactly where a fourth ward in that constituency would plausibly be.
- **`NW2022 = "0,"`** — this field is a `"<Ward_No>, <WardName>"` composite label elsewhere (e.g. `"153, VASANT VIHAR"`); here it renders as `"0,"` with nothing after the comma, i.e. the same missing-name problem surfacing in a second, independently-populated field.

### Conclusion

This is a **real polygon with failed/missing metadata**, not a duplicate, not a whole-Delhi outline, and not a corrupted geometry. The most likely explanation is that the original KML/shapefile's attribute table has one row where the join to the authoritative ward-name/ward-number/population lookup failed, leaving default zero/null values while the geometry and one loosely-related field (`AC_No`) survived. This is a property of the **source data itself** — nothing in this project's KML→GeoJSON conversion (Phase 1) altered or introduced it; the conversion script preserved every source field exactly as found.

**No fix is fabricated here.** Guessing a `Ward_No` or `WardName` for this feature (e.g. assuming it's a specific known Vasant Vihar/Munirka sub-area) would be inventing administrative data, which this review does not do.

---

## 5. Confirmations requested

| Item | Result |
|---|---|
| All geometries WGS84 / EPSG:4326 | **Confirmed** — KML coordinates are WGS84 by spec; no reprojection occurred in conversion; re-verified here by re-checking all 251 features' coordinate ranges. |
| All geometries inside Delhi/NCR bounds | **Confirmed, 251/251** — every coordinate in every feature (including the anomalous one) falls inside `web/src/lib/mapRules.ts`'s `DELHI_BOUNDS` (lng 76.7–77.7, lat 28.2–29.0). The anomalous feature's own bbox (lng 77.131–77.168, lat 28.541–28.594) is well inside this box. |
| `FID` safe as a temporary unique source id | **Confirmed for uniqueness** (251 distinct values, including `FID = 53` for the anomalous row) — but note `FID` is a bare sequential index with no independent meaning beyond row order in the source file; it is safe as a *join key back to this GeoJSON*, not as a stable long-term identifier if the source file is ever regenerated. |
| `Ward_No` + `WardName` are the correct import fields | **Confirmed for 250 of 251 features.** For the anomalous feature, neither field is usable as-is (`Ward_No = "0"` is not a real ward number; `WardName` is null) — this is not a field-mapping problem, it's a missing-data problem specific to one row. |

---

## 6. Recommendation

**250 of the 251 features are clean and ready for import.** They cover the full official 1–250 ward numbering with no gaps, no duplicates, real names, real population figures, valid WGS84 geometry, and coordinates confirmed inside Delhi/NCR bounds.

**Exclude `FID = 53` (`Ward_No = "0"`) from the Phase 1 import.** It cannot be assigned a legitimate `Ward_No` or `WardName` without fabricating administrative data. Recommended handling:

1. Import the 250 features with `Ward_No` 1–250 as planned.
2. Set the 251st feature aside — do not import it as ward `0`, and do not merge/rename it into a neighboring ward without independent confirmation.
3. Flag it for manual follow-up: someone with access to an authoritative current MCD ward map/list could check whether this polygon represents a real ward that this particular source file simply failed to label (e.g. a ward split or boundary revision near Vasant Vihar/Munirka/R.K. Puram), or whether it's a genuine digitization leftover in the source KML with no real-world counterpart. Either way, that determination needs a human with ground-truth ward data, not a guess made during file conversion.

This finding does not block Phase 1 ward import — it narrows it from "251 wards" to "250 wards, cleanly matching Delhi's official count, plus one excluded row pending manual review."

---

## 7. Update (Phase 2 follow-up): the excluded feature's likely identity

After the 250-ward import shipped and rendered on the Map, two real gaps appeared in the ward mesh where two non-MCD jurisdictions sit: **NDMC** (New Delhi Municipal Council) and **Delhi Cantonment** (Ministry of Defence). Both were confirmed via point-in-polygon tests against known landmarks (Connaught Place, India Gate, Rashtrapati Bhavan, Chanakyapuri for NDMC; Delhi Cantt Railway Station for Cantonment) — none of the 250 imported wards contain any of these points.

While investigating the Cantonment gap, the same test was run against the excluded `FID = 53` (`Ward_No = "0"`) feature's geometry: **Dhaula Kuan and the Delhi Cantt Railway Station area both fall inside it**, and its centroid falls inside the real OSM-published Delhi Cantonment boundary (relation `3492183`) fetched to fill that gap.

This is a plausible (not certain) explanation, worth recording: `FID = 53` may not be a pure attribute-join failure after all — it may be the Cantonment boundary itself, included in the source KML/shapefile for geographic completeness but correctly left without an MCD `Ward_No`/`WardName` since Cantonment genuinely isn't an MCD ward. The two explanations aren't mutually exclusive (the join could have failed *because* there was no MCD ward record to join to, for exactly this reason). Either way, the original decision to exclude it from the ward import stands — it still cannot be imported as an MCD ward without fabricating a name/number.

**Both gaps are now filled** using real, separately-sourced OpenStreetMap boundaries (not `FID = 53` itself, which remains excluded and unused) — see `scripts/import-osm-jurisdictions.ts` and `data/delhi/processed/delhi_non_mcd_jurisdictions.geojson`.
