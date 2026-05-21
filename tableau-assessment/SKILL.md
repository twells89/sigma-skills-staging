---
name: tableau-assessment
description: Take inventory of a Tableau Cloud site and produce a migration-readiness readout — environment counts, licenses, datasource mix, refresh history, per-workbook usage, per-workbook complexity (via .twb gap-scan), and a value/cost-ranked migration shortlist. Use when a user wants to scope a Tableau→Sigma migration, audit BI sprawl, or pick which workbooks to convert first. Lightweight (~90s) MCP-driven pre-scoping; complements Hakkoda's deeper Assessment App rather than replacing it.
---

# Tableau Assessment

Surveys a Tableau Cloud site via the Tableau Admin Insights project (MCP) and the
workbook-content REST endpoint (PAT). Emits a markdown readout + JSON inventory
the user can hand to a Sigma rep, a Hakkoda engagement, or directly to the
`tableau-to-sigma` skill for conversion of the shortlisted workbooks.

---

## Privacy posture (READ FIRST, surface to the customer)

**This skill reads workbook metadata, not warehouse data.** What crosses Anthropic's
API on its way through Claude:

| Crosses Anthropic API | Stays local |
|---|---|
| Aggregate counts (workbook count, user count, datasource counts) | View CSVs (this skill never fetches them) |
| Workbook names, owner emails, project names | Warehouse rows (this skill never queries them) |
| `User License Type` and login dates from Admin Insights | Customer database credentials |
| Refresh job results, durations, error messages | The customer's actual reports' values |
| `.twb` XML for each workbook (calc-field definitions, custom SQL, layout) | `.hyper` extract data files (skipped on download) |

**This is a weaker posture than Hakkoda's "stays in Snowflake" app.** Hakkoda's
Snowflake Native App keeps everything inside the customer's Snowflake account. This
skill — like every other Claude Code skill — sends what it reads through the
Anthropic API to Claude. The user should be told this before running.

The skill writes outputs to a local directory (`/tmp/assessment-<sitename>/` by
default) and does NOT upload them anywhere. If the customer wants the readout
shared with a Sigma rep, that's a deliberate `Share` action, not automatic.

See `PRIVACY.md` for the full disclosure to share with customer privacy/legal review.

---

## When to use this skill

- A Tableau customer wants a 5-minute scoping view before booking a Hakkoda 1-hour assessment
- A Sigma SE preparing for a discovery call wants a pre-built migration shortlist
- A customer is deciding which Tableau workbooks to retire vs. migrate
- A `tableau-to-sigma` invocation needs a Phase 0 inventory of the source site

**Not for**: Replacing Hakkoda's full Assessment App readout (pricing scenarios,
permissions audit, dataset similarity at depth). Those still live in Hakkoda.

---

## Scripts overview

| Script | Purpose |
|---|---|
| `scripts/setup-tableau.sh` | Symlink to the tableau-to-sigma PAT setup wizard |
| `scripts/get-tableau-token.sh` | Symlink to the tableau-to-sigma token-refresh wrapper |
| `scripts/probe-admin-insights.rb` | Confirm the Admin Insights project is visible (gates whether license/refresh/usage sections run) |
| `scripts/fetch-all-twbs.rb` | Parallel download of all workbook `.twb` files via REST (PAT mode only) |
| `scripts/aggregate-complexity.rb` | Run `scan-workbook-gaps.rb` (from tableau-to-sigma) against every `.twb`; emit `complexity.json` |
| `scripts/build-shortlist.rb` | Cross-tabulate usage × complexity; rank by `value / (1 + cost)`; emit `shortlist.json` |
| `scripts/render-readout.rb` | Compose final `readout.md` from `inventory.json` + `complexity.json` + `shortlist.json` |

Scripts that need warehouse-table data (the MCP query-datasource calls against
Admin Insights) are NOT scripts — the agent fires those directly per the recipes
in this SKILL.md, because MCP tool calls only work from the agent's context.

---

## Modes

| Mode | Setup | Coverage | Use when |
|---|---|---|---|
| **MCP-only** | None — just Tableau MCP loaded as Site Admin | Environment + Licenses + Datasource mix + Refresh + Usage | Quick pre-scope; customer hasn't issued a PAT |
| **MCP + PAT** *(recommended)* | `ruby scripts/setup-tableau.sh` once (~30s) | Adds per-workbook complexity scan + ranked migration shortlist | Real migration planning; full readout |

The user driving the skill MUST have Site Admin role in Tableau — Admin Insights
is only published to that group by default. The skill probes this and surfaces a
clear error if Admin Insights isn't visible.

---

## Phase 0 — Probe access

Confirm the user has the access the skill needs. Two checks, in order:

```bash
# 0a. Tableau MCP loaded? Try a cheap call:
mcp__tableau__list-workbooks   limit=1
# If "tool not found" → MCP isn't loaded. Skill cannot run.
# If 401/403 → user signed in but lacks site-level read access.

# 0b. Admin Insights visible?
ruby scripts/probe-admin-insights.rb
# Calls mcp__tableau__search-content for "Admin Insights"; reports which of the
# 10 expected datasources are reachable. Exits 1 if zero are reachable (user is
# not a Site Admin → can run only the Section 1 inventory below).
```

If only the basic inventory runs (Section 1 below), surface a banner in the readout:

> "Run this as a Tableau Site Admin to unlock license, refresh, and usage
> sections. Currently running with limited access."

---

## Phase 1 — Environment inventory (MCP, always runs)

Even without Admin Insights, the skill can produce a basic environment overview
from `mcp__tableau__search-content` and `mcp__tableau__list-workbooks`. This is
the "even broken access still produces something" floor.

```
mcp__tableau__list-workbooks                                     # → workbook count + sheetCount/hasExtracts per workbook
mcp__tableau__search-content filter.contentTypes=["datasource"]  # → datasource count
mcp__tableau__list-views                                         # → view count
```

Write the rolled-up counts to `inventory.json`'s `environment_overview` key.

---

## Phase 2 — Admin Insights queries (MCP, requires Site Admin)

For each of the queries below, call `mcp__tableau__query-datasource` with the
listed `datasourceLuid` and `query` payload. **Run queries sequentially, not in
parallel** — VizQL session contention causes 401s under fan-out.

Field names matter — Admin Insights field naming is inconsistent and a typo
silently fails. See `refs/admin-insights-fields.md` for the verified field-name
cheat sheet. Critical: it's `Event Id`, not `Event LUID`.

### 2a. Site-content item counts → `inventory.environment_overview`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Item Type" },
    { "fieldCaption": "Item LUID", "function": "COUNTD", "fieldAlias": "n" }
  ]}
}
```

### 2b. License breakdown → `inventory.licenses`

```json
{
  "datasourceLuid": "<TS Users LUID>",
  "query": { "fields": [
    { "fieldCaption": "User License Type" },
    { "fieldCaption": "User Site Role" },
    { "fieldCaption": "User LUID", "function": "COUNTD", "fieldAlias": "users" },
    { "fieldCaption": "Days Since Last Login", "function": "AVG", "fieldAlias": "avg_days_since_login" }
  ]}
}
```

### 2c. Content ownership → `inventory.content_ownership`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Item Type" },
    { "fieldCaption": "Owner Email" },
    { "fieldCaption": "Item LUID", "function": "COUNTD", "fieldAlias": "n" }
  ], "filters": [{
    "field": { "fieldCaption": "Item Type" },
    "filterType": "SET",
    "values": ["Workbook", "Datasource", "Flow", "View"]
  }]}
}
```

### 2d. Datasource types + extract mix → `inventory.datasource_types`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Data Source Content Type" },
    { "fieldCaption": "Data Source Database Type" },
    { "fieldCaption": "Is Data Extract" },
    { "fieldCaption": "Item LUID", "function": "COUNTD", "fieldAlias": "n" }
  ], "filters": [{
    "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["Datasource"]
  }]}
}
```

### 2e. Refresh history → `inventory.refresh_jobs`

```json
{
  "datasourceLuid": "<Job Performance LUID>",
  "query": { "fields": [
    { "fieldCaption": "Job Type" },
    { "fieldCaption": "Final Job Result" },
    { "fieldCaption": "Job ID", "function": "COUNTD", "fieldAlias": "jobs" },
    { "fieldCaption": "Job Duration", "function": "AVG", "fieldAlias": "avg_duration_s" }
  ]}
}
```

### 2f. Workbook usage ranking → `inventory.workbook_usage`

```json
{
  "datasourceLuid": "<TS Events LUID>",
  "query": { "fields": [
    { "fieldCaption": "Workbook Name" },
    { "fieldCaption": "Number of Events", "function": "SUM", "fieldAlias": "accesses", "sortDirection": "DESC", "sortPriority": 1 },
    { "fieldCaption": "Count of Distinct Actors", "fieldAlias": "actors" }
  ], "filters": [
    { "field": { "fieldCaption": "Event Type" }, "filterType": "SET", "values": ["Access"] },
    { "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["View", "Workbook"] }
  ]}
}
```

### 2g. Workbook inventory (size, owner, last accessed, hyperlink) → `inventory.workbook_inventory`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Item Name" },
    { "fieldCaption": "Owner Email" },
    { "fieldCaption": "Top Parent Project Name" },
    { "fieldCaption": "Size (MB)", "function": "SUM", "fieldAlias": "size_mb" },
    { "fieldCaption": "Last Accessed At" },
    { "fieldCaption": "Is Data Extract" },
    { "fieldCaption": "Has Refresh Scheduled" },
    { "fieldCaption": "Item Hyperlink" }
  ], "filters": [{
    "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["Workbook"]
  }]}
}
```

Merge the seven outputs into `<out>/inventory.json` following the schema in
`refs/output-shapes.md`.

### 2h. Per-user usage map → `users.json` (after running analyze-users.rb)

For user-population segmentation and per-user migration coverage:

```json
{
  "datasourceLuid": "<TS Users LUID>",
  "query": { "fields": [
    { "fieldCaption": "User Email" },
    { "fieldCaption": "User License Type" },
    { "fieldCaption": "User Site Role" },
    { "fieldCaption": "Days Since Last Login", "function": "MAX", "fieldAlias": "days_since" },
    { "fieldCaption": "Workbooks",  "function": "SUM", "fieldAlias": "owned_wb" },
    { "fieldCaption": "Views",      "function": "SUM", "fieldAlias": "owned_views" },
    { "fieldCaption": "Total Traffic - Views", "function": "SUM", "fieldAlias": "traffic_views" },
    { "fieldCaption": "Access Events - Views", "function": "SUM", "fieldAlias": "access_views" },
    { "fieldCaption": "Last Login Date" }
  ]}
}
```
Save the response under `<out>/raw-ts-users.json`.

Then the per-user-per-workbook access map (used to compute migration coverage):

```json
{
  "datasourceLuid": "<TS Events LUID>",
  "query": { "fields": [
    { "fieldCaption": "Actor User Name" },
    { "fieldCaption": "Workbook Name" },
    { "fieldCaption": "Number of Events", "function": "SUM", "fieldAlias": "accesses" }
  ], "filters": [
    { "field": { "fieldCaption": "Event Type" }, "filterType": "SET", "values": ["Access"] },
    { "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["View", "Workbook"] }
  ]}
}
```
Save the response under `<out>/raw-ts-events-per-user.json`.

---

## Phase 3 — Per-workbook complexity (PAT, optional but recommended)

This is the section that differentiates the skill from Hakkoda. Hakkoda owns
assessment but not conversion; this skill ties them together by predicting
per-workbook conversion cost.

### 3a. Auth + fetch

```bash
ruby scripts/setup-tableau.sh         # one-time, prompts for PAT name + secret
eval "$(scripts/get-tableau-token.sh)" # refreshes ~hourly auth token
ruby scripts/fetch-all-twbs.rb --out /tmp/assessment-<site>
```

`fetch-all-twbs.rb` lists every workbook via REST, downloads `.twb` content in
parallel (6-thread cap), and unzips any `.twbx` to extract the inner `.twb`.

### 3b. Run the gap-scanner against each workbook

```bash
ruby scripts/aggregate-complexity.rb /tmp/assessment-<site>
```

Iterates `<out>/twbs/*.twb`, runs `tableau-to-sigma/scripts/scan-workbook-gaps.rb`
on each, parses each `<luid>-gaps-report.json`, aggregates feature counts in
four buckets (auto / hint / manual / unhandled) per workbook. Writes
`complexity.json`.

### 3c. Build the migration shortlist

```bash
ruby scripts/build-shortlist.rb /tmp/assessment-<site>
```

Cross-tabulates `inventory.workbook_usage` with `complexity.json`. Scores each
workbook:

- `value = accesses × √(distinct_viewers)`
- `cost  = 10·unhandled + 3·manual + 1·hint`
- `score = value / (1 + cost)`

Writes `shortlist.json` — ranked by score, with explicit "retire" tags on
zero-access workbooks and explicit "needs gap-scout" flags on workbooks with
unhandled features.

---

## Phase 4 — Site-wide lineage via Metadata API (PAT, optional but recommended)

The Tableau Metadata API exposes the full lineage graph — workbooks, embedded /
published datasources, connection hostnames, custom SQL queries, Prep flows —
in a single GraphQL call. This unlocks the prescriptive data-source analysis
(red flags, similarity clusters, Sigma-readiness verdicts).

### 4a. Fetch the site-wide metadata graph

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/fetch-metadata-graph.rb --out /tmp/assessment-<site>
```

One POST to `/api/metadata/graphql`. Writes `metadata-graph.json` (~100–250 KB
for most sites). Requires Site Admin role.

### 4b. Analyze data sources

```bash
ruby scripts/analyze-datasources.rb --out /tmp/assessment-<site>
```

For each data source (published + embedded), classifies:

| Verdict | Means |
|---|---|
| `drop-in` | Cloud warehouse natively supported by Sigma; connect directly |
| `verify-network` | Cloud type on an unrecognized host, or detected on-prem hostname; confirm Sigma can reach |
| `verify-db` | Database supported via a Sigma connector that may need extra config |
| `verify-modeling` | Federated cross-source join; review Sigma data-model relationship coverage |
| `resolve-published` | References another published datasource; resolve recursively |
| `land-in-warehouse` | File-based (Excel / CSV / Google Drive / .hyper); needs warehouse upload first. **Recommended path: use the sibling `tableau-vds-to-snowflake` skill to auto-generate Snowflake DDL + Sigma data model from the .tds.** |

Also emits:
- **Similarity clusters** — embedded datasources whose field-name sets overlap by ≥75% (Jaccard). Strong consolidation candidates.
- **Custom SQL inventory** — every Custom SQL block on the site with its downstream workbooks.
- **Prep flow inventory** — flow → downstream-datasource/workbook lineage, orphan detection.

Connection-type → verdict mapping is in `analyze-datasources.rb`'s constants block. Update when Sigma adds a new connector.

### 4c. Analyze user populations

```bash
ruby scripts/analyze-users.rb --out /tmp/assessment-<site>
```

Reads `raw-ts-users.json` + `raw-ts-events-per-user.json` (Phase 2h) + `shortlist.json`.
Segments users into power-user / active-creator / heavy-consumer / casual / light /
dormant / never-logged-in buckets. For each user, computes **pilot-migration coverage**
— what percent of their actual workbook accesses are covered by the top-5 pilot.

Bucket thresholds and segment definitions are in `analyze-users.rb`'s
`segment_for` function — tune for the customer's site size.

---

## Phase 5 — Render the readout

```bash
ruby scripts/render-readout.rb /tmp/assessment-<site>
```

Composes the 12-section markdown report (template at `refs/readout-template.md`).
Sections covered:

1. Environment overview
2. Licenses & cost scenario
3. Content ownership
4. Datasource patterns
5. Refresh insights
6. Workbook priority — usage-ranked
7. Migration shortlist (PAT-mode only — falls back to usage-only if MCP-only)
8. PAT-mode addendum: per-workbook complexity (PAT-mode only)
9. What the skill found vs. what it didn't
10. Privacy disclosure (links to PRIVACY.md)
11. Hand-off package contents
12. Next steps

Deliverables in `/tmp/assessment-<site>/`:

- `readout.md` — customer-facing markdown
- `inventory.json` — raw Admin Insights aggregates
- `complexity.json` — per-workbook gap counts (PAT mode)
- `shortlist.json` — ranked migration shortlist (PAT mode)
- `twbs/` — cached `.twb` files (PAT mode; can be deleted after rendering)

---

## Handoff to tableau-to-sigma

The migration shortlist is directly consumable by the conversion skill. After
review, hand the top N workbook LUIDs to `tableau-to-sigma`:

> "Migrate the top 5 from this assessment: <list of workbook URLs>. Use the
> shortlist's `auto/hint/manual/unhandled` flags to set expectations per
> workbook."

The conversion skill's Phase 0a (`scan-workbook-gaps.rb`) will produce the SAME
gap-counts that this assessment already cached, so it can skip re-scanning.
(Phase 2 enhancement: have `tableau-to-sigma` read this skill's `complexity.json`
directly when both are present in the same `/tmp/<site>/` dir.)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `probe-admin-insights.rb` finds 0 datasources | User is not Site Admin | Surface limited-mode banner; skip sections 2–3 |
| MCP `get-datasource-metadata` returns 401 in batch | VizQL session contention | Serialize Admin Insights metadata calls (one at a time) |
| `query-datasource` returns `Field 'X' not found` | Field-name typo (e.g., `Event LUID` instead of `Event Id`) | Check `refs/admin-insights-fields.md` |
| `fetch-all-twbs.rb` 302 redirect on `/workbooks` | Missing `Tableau.base_path` prefix | Use `Tableau.base_path + "/workbooks"`, not `/workbooks` alone |
| Tableau PAT 4 consecutive signin failures | Tableau Cloud invalidates the PAT | Mint a new PAT in Tableau settings; re-run setup |
| `aggregate-complexity.rb` skips `.twbx` workbooks | Inner `.twb` not unzipped | `fetch-all-twbs.rb` unzips automatically; rerun the fetch step |
