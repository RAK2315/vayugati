# data.gov.in CPCB API — Authenticated Audit

Run: 2026-07-22 10:44 UTC
Resource: `3b01bcb8-0b14-4abf-b6f2-c1bfd384ba69` (https://api.data.gov.in/resource/3b01bcb8-0b14-4abf-b6f2-c1bfd384ba69)
Request: `format=json&limit=20&filters[state]=Delhi`

This is a one-shot, read-only field-shape probe. **Not** wired into
production ingest — `app/ingest.py` still runs on OpenAQ exactly as
before this audit. No database writes, no OpenAQ changes.

## Result: call succeeded

- **Records returned:** 20
- **Reported total (API's own `total` field):** 315
- **Reported count (API's own `count` field):** 20
- **Lat/lng present on records:** yes

### Available fields

- `avg_value`
- `city`
- `country`
- `last_update`
- `latitude`
- `longitude`
- `max_value`
- `min_value`
- `pollutant_id`
- `state`
- `station`

### Sample station names

- Chandni Chowk, Delhi - IITM
- IIT Delhi, Delhi - IITM
- IMD Lodhi Road, Delhi - IITM
- ITO, Delhi - CPCB
- JNU, Delhi - DPCC
- NSUT Jaffarpur, Delhi - DPCC
- Narela, Delhi - DPCC
- North Campus, DU, Delhi - IITM

### Timestamp examples (`last_update`)

- 22-07-2026 15:00:00

### Pollutant IDs seen

- CO
- NH3
- NO2
- PM10
- PM2.5
- SO2

