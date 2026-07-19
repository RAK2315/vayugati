# Vayu Gati — Product and Design Plan v2
### Jankari se Karyavahi Tak

## 1. Product definition

Vayu Gati is a pan-India urban air incident-response system. It helps a city:

1. detect or predict a pollution incident;
2. determine whether it is locally actionable;
3. identify probable sources with confidence and evidence;
4. collect missing evidence through sensors, officers and citizens;
5. route the correct task to the responsible authority;
6. track action, escalation and accountability;
7. verify whether the intervention actually reduced pollution; and
8. learn which interventions work best in different conditions.

Delhi is the first development and validation environment because it has the strongest combination of monitoring stations, historical pollution data, meteorology, source studies, mobility indicators, satellite coverage, government action frameworks and complex real-world pollution conditions. The product core must remain configurable for other Indian cities.

## 2. Core outcome

Vayu Gati must move cities from:

> Knowing that the air is polluted

To:

> Knowing where to act, why to act, who must act, what action to take and whether it worked.

The central product object is a **pollution incident**, not a complaint, map, forecast or isolated sensor reading.

## 3. Product principles

- Build nationally; configure locally; validate first in Delhi.
- Never act on one sensor reading, one citizen report or one AI output alone.
- Use pollutant concentrations for scientific analysis; use AQI mainly for public communication.
- Show uncertainty, supporting evidence, contradictory evidence and data quality.
- Separate suspected source, corroborated source and officially verified violation.
- Separate task completion from environmental improvement.
- Automate routine coordination; retain authorised human approval for legal enforcement.
- Citizens participate throughout the incident cycle, but do not replace regulatory monitoring or authorised enforcement.
- Design for partial APIs, unclear jurisdiction, offline field conditions and limited public resources.

## 4. Users

### Command centre
Monitors active and predicted incidents, approves operational actions, assigns resources, resolves jurisdiction disputes and escalates delays.

### Pollution analyst
Reviews pollutant trends, source probabilities, evidence, uncertainty, local-versus-regional pollution and intervention impact.

### Field officer
Receives verification or action tasks, follows a short checklist, records GPS/photo/sensor evidence and reports the field outcome.

### Citizen / Vayu Saathi
Reports visible pollution, answers targeted verification questions, verifies claimed action, reports recurrence and may host a calibrated community sensor.

### Senior administrator
Reviews response times, verified mitigation, recurring hotspots, agency performance, exposure protected and cost-effectiveness.

## 5. End-to-end workflow

Vayu Gati uses two connected loops.

### A. Prevention loop

1. Monitor ambient pollution and known sources.
2. Forecast local pollution risk and local excess.
3. Detect a likely actionable event before the peak.
4. Generate a preventive inspection or intervention task.
5. Dispatch through the appropriate approval level.
6. Verify whether the predicted incident was prevented or reduced.

### B. Incident-response loop

1. Detect a persistent pollution anomaly or cluster of reports.
2. Create one pollution incident and merge duplicate signals.
3. Classify the event as local, mixed, regional or uncertain.
4. Estimate probable source categories with confidence.
5. Request the next best evidence when confidence is insufficient.
6. Map the source/location to the responsible agency, division and officer.
7. Select the best feasible intervention from a pre-approved playbook.
8. Create, approve and dispatch the task.
9. Track acknowledgement, action, SLA and escalation.
10. Verify operational completion and environmental effect.
11. Classify the outcome and monitor recurrence.
12. Save the result in the intervention learning library.

## 6. Monitoring and detection standard

Vayu Gati must support the six major urban air pollutants:

- PM2.5
- PM10
- NO2
- SO2
- CO
- O3

### V1 priority

- Core: PM2.5, PM10 and NO2
- Supporting: SO2, CO and O3

### Detection metrics

- current one-hour concentration;
- rolling 24-hour exposure;
- rate of increase;
- persistence across multiple readings;
- difference from nearby stations or sensors;
- local excess above the wider city/background level;
- probability of a threshold crossing in 6, 12 or 24 hours;
- population and vulnerable facilities exposed;
- data freshness, completeness and calibration quality.

A pollution incident must not be created from one isolated spike unless an independently verified urgent event exists.

## 7. Data inputs

Vayu Gati should be connector-based so each city can use the best available sources.

- CPCB/SPCB/municipal regulatory monitoring stations;
- calibrated fixed and mobile sensors;
- meteorological observations and forecasts;
- traffic, public transport and congestion indicators;
- satellite atmospheric observations and land imagery;
- roads, land use, construction, industry, waste and asset ownership GIS;
- schools, hospitals, population and vulnerability layers;
- citizen reports and targeted verification responses;
- field inspection records;
- source-level telemetry where legally and technically available.

Every feed must store freshness, reliability, coverage, completeness and calibration status.

## 8. Probable source identification

The system should use evidence fusion, not one opaque model.

Evidence categories:

- pollutant signatures and ratios;
- wind direction and speed;
- spatial movement between sensors;
- proximity to roads, construction, industry, waste or exposed soil;
- traffic, construction, industrial or fire activity;
- satellite regional-plume context;
- citizen and field evidence;
- previous incident history.

Output example:

- road dust: 62%;
- construction dust: 24%;
- traffic combustion: 10%;
- regional pollution: 4%.

The interface must show supporting evidence, contradictory evidence, missing evidence and confidence.

## 9. Evidence levels and task rules

### Suspected
The model has a hypothesis but evidence is weak. Create only a verification or sensing task.

### Corroborated
Multiple independent signals support the source. Create an inspection, preventive or operational action task, subject to the required approval.

### Officially verified
An authorised officer, official sensor or compliance record confirms the source or violation. Formal enforcement may proceed according to local law and authority.

Legal penalties, stoppages, closures and mandatory restrictions always require authorised approval.

## 10. Next Best Evidence

When source confidence is insufficient, Vayu Gati should recommend the smallest useful evidence mission, such as:

- targeted citizen verification;
- geotagged field photograph;
- mobile-sensor route;
- upwind/downwind measurement;
- construction-activity check;
- traffic count;
- source operating-status check.

The system should explain why the evidence is needed and how it is expected to improve confidence.

## 11. Citizen participation throughout

Citizens participate at all stages:

- detect and report observable pollution;
- verify an AI-generated source hypothesis;
- confirm whether pollution is still active;
- track which authority received the incident;
- verify whether the claimed action occurred;
- report recurrence;
- host calibrated community sensors;
- join trained Vayu Saathi or Air Steward programmes.

Citizen evidence supports prioritisation and verification but cannot independently establish a legal violation.

## 12. Responsibility and routing

Vayu Gati must maintain a Source–Responsibility Registry:

> Source/activity → asset/location → owner/operator → regulating authority → division/zone → responsible officer/team → available intervention → escalation path

The system should route to the most specific responsible unit, not merely a broad department. It must support disputed ownership, overlapping jurisdiction and backup escalation.

## 13. Intervention selection

Interventions come from configurable, city-approved playbooks. Each playbook entry stores:

- applicable source and evidence level;
- responsible authority;
- legal/operational approval level;
- implementation checklist;
- required team and equipment;
- estimated deployment time and cost;
- expected effect and duration;
- known limitations;
- required proof;
- environmental verification method;
- evidence basis: literature, expert estimate or Vayu Gati observation.

Before recommending an action, the system checks team availability, equipment, travel time, workload and alternatives.

## 14. Controlled automation

### Automatic
- incident creation;
- duplicate clustering;
- evidence-task creation;
- routine sensor checks;
- citizen verification missions;
- reminders and SLA tracking.

### Command approval
- field-team deployment;
- municipal equipment deployment;
- construction inspection;
- traffic or sanitation operations.

### Authorised legal approval
- penalties;
- stop-work orders;
- industrial restrictions or closure;
- mandatory traffic restrictions.

## 15. Verification and impact

A photo proves that an activity occurred; it does not prove pollution reduction.

### Operational verification

- GPS and timestamp;
- officer checklist;
- photographs/video;
- asset or vehicle record;
- official inspection outcome.

### Environmental verification

- post-action sensor response;
- weather-adjusted comparison;
- expected no-action estimate;
- comparable untreated location where possible;
- citizen confirmation;
- recurrence monitoring.

Final outcomes:

- effective;
- partly effective;
- ineffective;
- inconclusive;
- source hypothesis disproved;
- action completed but pollution unchanged;
- problem recurred.

## 16. Scientific and data-driven standards

- Calibrate low-cost sensors against regulatory stations.
- Label uncalibrated data as indicative.
- Validate forecasts on future unseen periods.
- Compare forecasts with a persistence baseline.
- Track MAE, RMSE, bias, severe-event recall and false-alarm rate.
- Validate source attribution using independently verified incidents and known source studies.
- Evaluate interventions using weather adjustment, matched locations, interrupted time series or synthetic controls where feasible.
- Never present a model probability as a proven causal or legal finding.

## 17. Product metrics

### North-star metric

**Time to Verified Mitigation:** time from detecting an actionable incident to reaching a defensible environmental outcome.

### Supporting metrics

- forecast performance against persistence;
- source-confirmation rate;
- correct first-time routing rate;
- task acknowledgement and completion time;
- SLA breaches and escalation time;
- false dispatch rate;
- verified intervention effectiveness;
- recurrence rate;
- citizen–officer verification agreement;
- exposed person-hours protected;
- cost per effective intervention;
- data uptime and confidence coverage.

## 18. Product surfaces

The product uses one shared design system with role-specific experiences.

### Command workspace
Desktop-first. Incident queue, map, responsibility, evidence, task approval, assignment, SLA, escalation and impact.

### Analyst workspace
Scientific evidence, pollutant trends, forecast uncertainty, source probabilities, local/regional classification and impact analysis.

### Field application
Mobile-first, offline-capable, camera/GPS-first, large controls, short checklists, voice notes and minimal typing.

### Citizen application
Simple and accessible. Local air status, reports, targeted verification, incident tracking, action confirmation and recurrence reporting.

## 19. Visual and interaction design

Vayu Gati should feel like a serious government operations product, inspired by Microsoft 365 and Outlook: clean, structured, calm, professional and information-dense without becoming cluttered.

### Brand system

- Primary dark brown: `#422B1C`
- Sky blue: `#C4F1FF`
- Warm cream: `#F6EFE4`
- White working surfaces
- Red, amber and green reserved for severity and operational status
- Typography: Segoe UI Variable / Segoe UI; Inter or system sans-serif fallback
- Thin borders, subtle shadows, restrained radii and compact spacing

### Logo usage

- Primary: dark-brown Vayu Gati logo on cream or white.
- Alternate: sky-blue mark on dark brown.
- Compact icon: the two flowing wave shapes without the full curved wordmark for small navigation and favicon use.

### Shared application shell

- top bar: logo, product name, global search, alerts, help and user profile;
- left icon rail: Overview, Incidents, Map, Tasks, Citizens, Sensors, Analytics and Settings;
- contextual secondary navigation based on the active module;
- main workspace using Outlook-style list-detail-action panes.

### Command workspace pattern

1. Incident list and filters
2. Selected incident workspace with map, timeline and evidence
3. Action panel with next-best evidence, recommendation, approval and assignment

The map supports decisions but does not replace the incident queue as the primary interface.

### Accessibility

- WCAG AA contrast;
- labels in addition to colours;
- keyboard navigation for desktop users;
- Hindi and English layout support;
- explicit loading, error, stale-data, partial-data and offline states;
- progressive disclosure for dense technical evidence.

## 20. Pan-India configuration model

The product core is common. Each city uses a City Pack containing:

- geographic and administrative boundaries;
- monitoring and weather connectors;
- local source categories and registries;
- agency, zone and officer responsibility mapping;
- intervention playbooks and legal approval levels;
- teams, equipment and SLAs;
- local language and communication templates;
- escalation hierarchy;
- city-specific models and calibration.

Nothing essential should be hardcoded to Delhi.

## 21. Delhi development scope

Delhi is the first testbed, not the final product boundary.

Initial development should use a limited set of data-rich hotspots/wards and test:

- all six-pollutant data support;
- PM2.5, PM10 and NO2 forecasting;
- local-excess estimation;
- incident creation and clustering;
- source probability and evidence display;
- citizen and field verification;
- responsibility routing;
- controlled task dispatch;
- dual verification;
- basic intervention impact measurement.

## 22. Existing project migration requirements

The current project must be upgraded incrementally, not rebuilt blindly.

### Preserve

- working authentication;
- valid Supabase tables, storage and RLS;
- reliable data ingestion;
- functioning report, field and command workflows that remain useful;
- working deployment configuration.

### Change

- make `incidents` the central product object;
- link reports, evidence, attributions, tasks, actions and outcomes to incidents;
- separate source hypothesis from official verification;
- separate action completion from impact outcome;
- add next-best-evidence missions;
- add responsibility routing, approval level, SLA and escalation;
- replace binary `resolved` with evidence-backed outcome states;
- replace the current shell with the Microsoft 365-style design system;
- keep role-specific views while unifying the visual language.

### Migration safety

- use versioned database migrations;
- do not delete working tables or data without a mapped replacement;
- keep backward compatibility until the new workflow is tested;
- complete small vertical slices and keep the app deployable after each slice;
- do not fake live integrations; show explicit unavailable or demo-data states.

## 23. Recommended implementation sequence

### Phase 0 — Audit and safety

- audit the repository, routes, schema, RLS, integrations and deployment;
- document what already works and what conflicts with this plan;
- create versioned migrations and a rollback strategy;
- create design tokens and shared application shell.

### Phase 1 — Incident-centred workflow

- add incidents and incident evidence;
- link citizen reports to incidents;
- merge duplicates;
- add evidence levels, status timeline and audit history;
- preserve the existing report flow during migration.

### Phase 2 — Verification and routing

- add next-best-evidence missions;
- add source–responsibility registry;
- add task approval level, assignment, SLA and escalation;
- make the field workflow offline-capable.

### Phase 3 — Scientific intelligence

- implement six-pollutant data support;
- add data-quality metadata;
- implement incident detection, local excess, forecasting and source probabilities;
- expose uncertainty and contradictory evidence.

### Phase 4 — Intervention and impact

- add configurable intervention playbooks;
- check teams and equipment before recommendation;
- add operational and environmental verification;
- classify impact and recurrence;
- build the intervention learning library.

### Phase 5 — Command and citizen maturity

- complete the command list-detail-action workspace;
- complete targeted citizen missions and action verification;
- add senior-level metrics and accountability views;
- validate the city-pack approach with a second-city configuration.

## 24. Definition of a successful first product

A successful first version must demonstrate one complete incident journey:

> Pollution detected or predicted → incident created → probable source identified → missing evidence collected → correct authority routed → feasible action approved and dispatched → field action recorded → citizens and sensors verify the result → impact classified and saved for future learning.
