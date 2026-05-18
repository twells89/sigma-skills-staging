---
name: tableau-to-sigma
description: >-
  Convert a Tableau datasource or workbook into a Sigma data model and matching
  dashboard. Use when the user has a Tableau datasource, TDS file, or Tableau
  workbook and wants to recreate it in Sigma. Discovery, calc-field translation,
  data model + workbook creation via REST API, layout generation, and parity
  verification — driven by `scripts/*.rb`.
user-invocable: true
---

# Tableau → Sigma Conversion

Convert a Tableau datasource into a Sigma data model, then build a Sigma workbook
that mirrors the Tableau dashboard layout as closely as possible.

**Read ALL of the following before replying or taking any action. Do not make assumptions about skill conventions, prompts, or global instructions — read the files.**
- `refs/column-gotchas.md` — column naming rules and special-character landmines
- `refs/data-model-spec.md` — data model JSON schema, element format, relationship format
- `refs/workbook-layout.md` — Ruby layout generation (mandatory), multi-series chart patterns

**For canonical workbook spec shape** (element kinds, source kinds, controls, formulas, formatting), defer to the sibling **`sigma-workbooks`** skill at `~/sigma-skills/sigma-workbooks/`. This skill restates only the Tableau-conversion-specific patterns; everything else (KPI fields, color channel, pivot-table shape, manual sources, container styling, YAML default, etc.) lives there. Read `sigma-workbooks/reference/specification/` whenever you need the current spec surface.

---

## Scripts

The conversion is driven by `scripts/*.rb`. Each script encapsulates one mechanical
phase. You compose them; the agent's role is judgment (which DM/workbook shape,
which calc translation, which layout) — not orchestration.

| Script | Purpose |
|---|---|
| `scripts/setup.rb` | One-time Sigma credential setup |
| `scripts/get-token.sh` | Exchange `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` for `SIGMA_API_TOKEN` (~1h TTL) |
| `scripts/setup-tableau.rb` | One-time Tableau PAT setup (only needed for PAT mode — see `refs/tableau-rest.md`) |
| `scripts/get-tableau-token.sh` | One-shot signin → exports `TABLEAU_AUTH_TOKEN` + `TABLEAU_SITE_ID` |
| `scripts/tableau-discover.rb` | PAT-mode Phase 1 discovery in one CLI: workbook + views + VDS metadata + GraphQL + .twb content |
| `scripts/parse-twb-layout.rb` | Parse a `.twb` XML file into a per-dashboard zone list (caption + view ref + x/y/w/h% + chart_kind). Use as a deterministic Phase 5 layout scaffold instead of eyeballing the PNG. |
| `scripts/extract-custom-sql.rb` | Phase 1f: pull Custom SQL blocks behind a workbook via Metadata GraphQL + .twb XML fallback. Output → `/tmp/<name>/custom-sql.json`. |
| `scripts/lib/tableau_rest.rb` | Ruby wrapper for the Tableau REST endpoints the skill uses |
| `scripts/estimate-cost.rb` | Predict input/output token cost from workbook + datasource metadata |
| `scripts/fetch-view-data.rb` | Parse pre-fetched view CSVs into a signals manifest (distinct values, date min/max, agg hints) |
| `scripts/discover-warehouse-columns.rb` | Parallel-fetch Sigma column metadata for N table inodeIds |
| `scripts/extract-calc-fields.rb` | Pull every Tableau CALCULATION field (with formula) + translation notes |
| `scripts/validate-spec.rb` | DM or workbook spec validator. Accepts `--type` and `--dm-context` |
| `scripts/post-and-readback.rb` | POST a DM or workbook spec, parse YAML response, GET back the spec, emit element ID map |
| `scripts/put-layout.rb` | Apply a layout XML to an existing workbook (strips read-only fields) |
| `scripts/auto-parity-plan.rb` | Phase 6a: auto-build a parity plan by matching Sigma chart elements to Tableau view CSVs (with `--rename` for renamed tiles). Output → `/tmp/<name>/parity-plan.json` wrapped as `{ extract, charts: [...] }` |
| `scripts/verify-parity.rb` | Phase 6c: diff expected (Tableau) vs actual (Sigma) per chart. `--extract-mode` switches to structural comparison (bucket count + dim set + sort) with value-drift tolerance for hasExtracts=true workbooks |
| `scripts/lib/layout.rb` | Layout-XML helpers (`gc`, `le`, `page_xml`, `assemble`) — `require`'d by per-workbook layout configs |

---

## Prerequisites

### Sigma credentials

Run the setup script once:

```bash
ruby scripts/setup.rb
```

It writes credentials to a config file your agent loads automatically.
<!-- agents:claude-only -->
For Claude Code that's `~/.claude/settings.json` — open a new Claude Code
session (or run `! source ~/.claude/settings.json`) so the env vars are live.
<!-- /agents:claude-only -->
<!-- agents:non-claude
Source the resulting env file in your shell before running anything that
needs the Sigma API — e.g. `source ~/.claude/settings.json` if you let the
script write there by default, or whatever path you configured. Then start
a new agent session so the env vars are live.
agents:end -->

Required env vars:
- `SIGMA_BASE_URL` — e.g. `https://aws-api.sigmacomputing.com`
- `SIGMA_CLIENT_ID`
- `SIGMA_CLIENT_SECRET`

Fetch a token at the start of each phase that needs one:

```bash
eval "$(scripts/get-token.sh)"
```

> Tokens live ~1 hour. Re-run when a curl returns 401. Never use
> `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` creates a subshell where
> the exported var dies immediately. Keep eval + curl in the same `bash -c '...'`
> invocation.

### Tableau access — two modes

The skill supports two transports for Tableau-side discovery. **Prefer MCP** when
it's available; the PAT path is a fallback.

| Mode | When to use | Setup |
|---|---|---|
| **MCP** | `mcp__tableau__*` tools are loaded in the session | None — host handles auth |
| **PAT (REST)** | MCP tools not available, OR you need `.twb` content (layout-hint extraction, embedded datasources) | `ruby scripts/setup-tableau.rb` once, then `eval "$(scripts/get-tableau-token.sh)"` per session |

**Detection at session start:** try `mcp__tableau__list-workbooks`. If the tool is
loaded and responds, you're in MCP mode. If it errors with "tool not found", fall
back to PAT mode.

**PAT mode in one command:**

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/tableau-discover.rb \
  --workbook-name "<name>" \
  --datasource-name "<name>" \
  --out /tmp/<name>
```

Produces the same artifacts as MCP-driven Phase 1 (`get-workbook.json`, `ds-metadata.json`,
`views/*.csv`, dashboard PNG, plus `workbook-content.twb`). Downstream scripts in Phases 2–6
are unchanged. Full endpoint inventory and gotchas in `refs/tableau-rest.md`.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 consecutive failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.

---

## Phase 0 — Estimate cost up front

Before committing to the conversion, predict the agent token cost. Useful for
quoting and for bucketing workbooks (small/medium/large/very-large) in a
multi-workbook migration.

```bash
# Pre-fetch workbook + datasource metadata
mcp__tableau__get-workbook  workbookId="<luid>"            > /tmp/<name>/get-workbook.json
mcp__tableau__get-datasource-metadata  datasourceLuid="..." > /tmp/<name>/ds-metadata.json

ruby scripts/estimate-cost.rb \
  --workbook /tmp/<name>/get-workbook.json \
  --datasource /tmp/<name>/ds-metadata.json
```

The estimator emits a JSON record with `features` (dashboards, sheets, calc
fields, custom SQL bytes) and `estimate` (complexity bucket, input/output
token counts, USD cost). Coefficients are heuristic and should be calibrated
against ~10 measured conversions before use in customer quotes.

---

## Phase 1 — Discover the Tableau datasource structure

### 1a. Find the datasource

```
mcp__tableau__search-content   terms="<datasource name>"   filter.contentTypes=["datasource"]
mcp__tableau__list-datasources
```

### 1b. Find workbooks sourced from it

```
mcp__tableau__search-content   terms="<datasource name>"   filter.contentTypes=["workbook"]
```

> **Check `hasExtracts` on the search result.** When `hasExtracts: true` on a workbook
> (and especially on its datasource), the Tableau view CSVs reflect a **frozen snapshot**
> of the warehouse — not its current state. Sigma always reads the live warehouse, so the
> absolute counts in Tableau views will diverge from Sigma values, even when the chart
> *structure* (dimensions, aggregations, breakdowns) is identical.

### 1c. Get workbook views

```
mcp__tableau__get-workbook   workbookId="<luid>"
```

Returns the list of views (sheets) with their `id` and `name`. Record all view IDs.

### 1d. Retrieve view data and images

Two different fetches with very different cost profiles. **Don't conflate them.**

- **`get-view-data` (CSVs)** — cheap, no VizQL session contention. **Fire all view CSVs in parallel** in a single batch.
- **`get-view-image` (PNGs)** — expensive, hits VizQL session contention. Most 401s come from firing multiple image requests simultaneously (or alongside other view calls).

**What to actually fetch:**

| Need | Source | How |
|---|---|---|
| Dashboard layout (grid, chart positions, title, filter shelf) | The dashboard view's PNG | 1 `get-view-image` call |
| Each chart's dimensions, measures, aggregation | Each sheet's CSV | All sheets in parallel via `get-view-data` |
| Distinct values + date min/max for Phase 2.5 filter detection | Each sheet's CSV | Same parallel batch |
| What an individual sheet looks like in isolation | Sheet PNG | **Skip by default** — fetch one only if you need to disambiguate a tile whose dashboard title is misleading or truncated |

Save each fetched CSV to `/tmp/<name>/views/<viewId>.csv` and parse them with:

```bash
ruby scripts/fetch-view-data.rb /tmp/<name>/views /tmp/<name>/signals.json
```

The output (`signals.json`) contains, per view, a `columns` map with `kind`
(dimension / numeric / date), `distinct_count`, sampled `distinct` values,
numeric ranges, and `aggregation_hints` parsed from CSV headers like
"Sum of Gross Revenue" or "Distinct count of Order Id".

**The reliable fetch pattern:**

1. Fire all `get-view-data` calls (every sheet + the dashboard view) **in a single parallel batch**. CSVs don't have session contention.
2. Fetch **only the dashboard view's PNG** with `get-view-image`. Solo — no other view calls in flight.
3. If a specific tile's dashboard title looks wrong or truncated, fetch that one sheet's PNG solo to disambiguate.

If `get-view-data` returns 401 for a view, retry that view solo; if it 401s again, skip it.

> **Do not parallel-fire `get-view-image` calls.** Even if the CSVs succeeded in parallel, concurrent image requests still 401 due to VizQL session contention. Images are always solo.

> **Reading the dashboard image is MANDATORY before writing the workbook spec in Phase 5.** The CSV headers tell you a chart's dimensions and measures; they do NOT tell you (a) the chart's *kind* (a `Category, Count` CSV could back a bar OR a pie OR a donut), (b) any text annotations (titles, section headers, footnotes), or (c) the filter shelf. Skipping the image read is the most common Phase 5 mistake — you ship a workbook that has the right numbers but is missing tiles the source dashboard actually rendered.

**Phase 1d checklist — confirm before moving on:**

- [ ] Opened the dashboard PNG and listed every tile, including non-chart tiles (text, filter shelves, legends, image placeholders)
- [ ] Decided the chart kind of each tile from the image, not just the CSV header (bar / line / pie / donut / kpi / map / table)
- [ ] Noted every text element on the dashboard surface (page title, section headers, free-text annotations)
- [ ] Noted every dashboard-level filter or parameter control (date range, list, segmented buttons)

Use the dashboard image to understand:
- How many KPIs are in the header row and what they measure
- Which chart types are used (bar, line, scatter, map, small multiples, **pie / donut**)
- The rough grid layout of each page (columns × rows) — count the rows; this is what your layout XML needs to match
- **Page titles, section headers, and any free-text annotations on the dashboard surface** — these are real content (not metadata) and need to be recreated as `text` elements in the Sigma spec. The page tab name (`page['name']`) is *not* a substitute; it only appears in the tab bar, not on the canvas. If the Tableau dashboard shows a heading like "Orders Dashboard" at the top of the page, add a `text` element with `body: "## Orders Dashboard"` and reserve a row for it in the layout.
- **The filter shelf.** Tableau dashboards usually have visible filter controls (a date range slider, a region list, a state list). These appear as `control` elements in the Sigma workbook — never just as Phase 2.5 element-level filters, because that strips the user-facing control surface.

**Alternative / supplement: parse the `.twb` zone tree.** If you have `workbook-content.twb` from PAT-mode Phase 1, run:

```bash
ruby scripts/parse-twb-layout.rb /tmp/<name>/workbook-content.twb /tmp/<name>/dashboard-layout.json
```

It emits a per-dashboard zone list with `caption`, `view_ref`, `x/y/w/h` in percent, **and `chart_kind` extracted from each worksheet's `<mark>` element** (`bar` / `line` / `pie` / `scatter` / `map-region` / `map-point` / `table-or-text` / `automatic` / `other`). This is more reliable than inferring chart type from the view CSV — the CSV headers can't distinguish bar-vs-pie or bar-vs-map. Map every zone in the output to a Sigma element using the tables in `refs/workbook-layout.md` (`Reading the .twb dashboard layout` section).

> **Maps:** if `parse-twb-layout.rb` emits `chart_kind: map-region` or `chart_kind: map-point` for any zone, do NOT build a bar chart. Use Sigma's `region-map` / `point-map` element kinds. The Tableau geographic role (`semantic-role` on the column) translates to Sigma's `regionType` via the table in `refs/workbook-layout.md`. Sigma's region types are US-only except for `country` — non-US state/county/ZIP data falls back to a sorted bar chart or, if lat/long is available, a `point-map`.

> **`chart_kind: automatic`:** Tableau's "Automatic" mark picks a default for the encodings. It usually renders as a bar but is not deterministic. When you see `automatic`, fetch the dashboard PNG and look at that specific tile to decide the Sigma kind.

Sigma spec supports: `bar-chart`, `line-chart`, `area-chart`, `combo-chart`, `scatter-chart`, `kpi-chart`, `pie-chart`, `donut-chart`, `region-map`, `point-map`, `table`, `pivot-table`, `control`, `text`, `image`, `container`.

> **Common kind mistakes — all three are rejected by the API:**
> - `"kpi"` → must be `"kpi-chart"`
> - `"pie"` → must be `"pie-chart"`
> - `"donut"` → must be `"donut-chart"`
>
> The official Sigma example library shows `kpi`, `pie`, and `donut` — all three are wrong. The validator (`scripts/validate-spec.rb`) flags them, but do not rely on it: write the correct kind from the start.

Does **not** support via the spec API: bullet chart, gantt.

**Maps are fully spec-supported.** Use `region-map` for choropleths (US state / county / ZIP / CBSA / country fills) and `point-map` for lat/long bubble or symbol maps. See `refs/workbook-layout.md` "Map elements" for the field shape, the exact set of valid `regionType` values, and the color-channel rules.

**Trellis (small multiples) is supported in Sigma but configured UI-only.** Build the chart with the right dimensions via spec, then trellis it manually post-publish.

Control types supported: `list`, `date-range`, `text`, `text-area`, `segmented`, `number`, `number-range`, `slider`, `range-slider`, `top-n`.
See `refs/workbook-layout.md` for full control element spec patterns.

### 1e. Extract Tableau calc fields

```bash
ruby scripts/extract-calc-fields.rb /tmp/<name>/ds-metadata.json /tmp/<name>/calc-fields.json
```

Each calc record carries `name`, `formula`, `default_agg`, `requires_custom_sql`,
and a `translation_notes` array flagging the common Tableau→Sigma gotchas:
- `IIF` → `If`
- `COUNTD` → `CountDistinct`
- IF/ELSEIF chains ending in literal — **wrap nullable inputs in `Coalesce` to match Tableau ELSE-catches-null semantics** (Tableau collapses NULL into the ELSE branch; Sigma `If(NULL >= ..., ...)` returns NULL)
- **`requires_custom_sql: true`** for Tableau table calcs (`WINDOW_*`, `RUNNING_*`, `RANK*`, `INDEX`, `FIRST`, `LAST`, `SIZE`, `TOTAL`, `LOOKUP`, `PREVIOUS_VALUE`) and LODs (`{FIXED/INCLUDE/EXCLUDE}`). These CANNOT be Sigma DM calc columns — Sigma's `CountOver` / `SumOver` / `RankOver` / `CumulativeSum` etc. **silently produce `error` type columns** when used in a DM calc column or grouping-table master calc. They MUST be implemented as a Sigma Custom SQL data-model element (`kind: "sql"`). See Phase 3 below for the spec shape.

Translate the calc fields into the DM (Phase 3) using the original Tableau
formula as the source of truth, NOT the warehouse column the calc happens
to reference. Example: a Tableau "Customer Value Tier" calc that buckets
`Lifetime Revenue` must be re-derived in Sigma from `LIFETIME_REVENUE`, not
pulled from a same-named `LOYALTY_TIER` warehouse column.

### 1f. Extract Custom SQL (PAT mode)

If the source workbook uses Custom SQL — either as the entire datasource or
mixed alongside warehouse tables — run:

```bash
ruby scripts/extract-custom-sql.rb \
  --workbook-luid <wb-luid> \
  --twb /tmp/<name>/workbook-content.twb \
  --out /tmp/<name>/custom-sql.json
```

The script tries two paths:
1. **Metadata GraphQL API** for `CustomSQLTable` nodes downstream of the workbook (works for both published-datasource Custom SQL and embedded Custom SQL).
2. **`.twb` XML fallback** for embedded `<relation type='text'>` blocks (covers cases the Metadata API hasn't crawled yet).

Output is a JSON array, one entry per Custom SQL block, with `query` (the raw SQL text), `connectionType`, and downstream workbook/datasource pointers. If the array is non-empty, build the DM in Phase 3 with **Custom SQL elements** (`kind: "sql"`) sourcing the actual SQL — not warehouse-table references.

> **MCP-mode caveat.** This script needs PAT-mode env vars (`TABLEAU_AUTH_TOKEN`, etc.). If you only have MCP available, you cannot pull custom SQL — that's a real gap; switch to PAT mode for any workbook the customer says uses custom SQL.

---

## Phase 2 — Discover actual warehouse column names

> **This step is mandatory. Do not skip it or infer column names from Tableau.**

Tableau display names ("Sub-Category", "Country/Region") are NOT the same as
Snowflake warehouse column names ("SUB_CATEGORY", "COUNTRY_REGION"). Using the
wrong names produces "dependency not found" errors at publish time.

```bash
eval "$(scripts/get-token.sh)" && \
ruby scripts/discover-warehouse-columns.rb /tmp/<name>/columns \
  <inodeId1> <inodeId2> ...
```

The script:
- runs all column-fetches in parallel,
- handles the "response key is `entries`, not `columns`" gotcha,
- writes one `<inodeId>.json` per table into the output dir.

The friendly names returned are the **exact** values to use in DM element formulas: `[TABLE_NAME/Column Name]`.

Find table inodeIds via Sigma search:

```
mcp__sigma-mcp-v2__search   query="<table name>"   entityTypes=["table"]
```

---

## Phase 2.5 — Detect view-level filters (mandatory)

> **The Tableau view CSV is the source of truth for what the dashboard *renders* — not what's in the warehouse.** Tableau MCP does not expose worksheet/dashboard filters directly, so you have to **infer them from the data the view emits**. A view that omits part of a dimension's values isn't a coincidence; it's a filter, and you must translate it into Sigma. Skipping this step ships a workbook that "renders fine" but disagrees with the source on totals, axis ticks, or visible categories.

For every dimension column on every view, compare:

| Source                         | Query                                              |
|--------------------------------|----------------------------------------------------|
| **View CSV signals** (Phase 1d) | Read `signals.json` — `columns.<col>.distinct`, `numeric_range`, `kind` |
| **Warehouse** (after Phase 2)  | `SELECT DISTINCT <col>` / `SELECT MIN, MAX <date>` via `mcp__sigma-mcp-v2__query` (`type: "connection"` with the table inodeId) |

Any value present in the warehouse but missing from the CSV implies a filter on that column.

```sql
SELECT MIN("DATE") AS min_date, MAX("DATE") AS max_date,
       COUNT(DISTINCT DATE_TRUNC('quarter', "DATE")) AS qtr_count
FROM "connection"."<table-inodeId>"
```

### Common patterns

| View CSV symptom | Likely Tableau filter | Sigma translation |
|---|---|---|
| Only some values of a categorical column appear | "Keep only" / dimension filter | `list` control with `mode: "include"`, or element-level filter |
| Date min/max is narrower than warehouse | Date / relative-date filter | `date-range` control — `mode: "current"` + `unit: "year"\|"quarter"\|...` for relative; `mode: "between"` with explicit `startDate`/`endDate` for fixed |
| Numeric column is bounded | Range filter | `number-range` or `range-slider` control, or element-level filter |
| Only top N items by some measure | Top-N filter | `top-n` control or element-level `top-n` filter (see `refs/workbook-layout.md`) |

### Where to apply the filter

Prefer a **workbook-level control filtering the master table** — every chart that sources from master inherits the filter, matching how a Tableau dashboard filter works. Use **element-level filters** only when the filter is fixed and shouldn't be user-adjustable (a hard-coded slice).

```json
"filters": [{"source": {"kind": "table", "elementId": "master"}, "columnId": "<master-col-id>"}]
```

> **A relative-date filter that "rolls forward" in Tableau** ("this year", "last 30 days", "year to date") must be translated as a relative `date-range` control (`mode: "current"`, `unit: ...`) — not a fixed start/end date. Hard-coding `startDate`/`endDate` freezes the filter to today's date and breaks tomorrow.

> **Phase 6 will not catch a missed filter on its own.** Data parity in Phase 6 compares Sigma rows to Tableau rows for the dimensions you query — if your Sigma chart includes extra rows the CSV never had, the comparison only flags missing rows from Tableau, not extra rows in Sigma. Always sanity-check distinct values and date ranges side-by-side before declaring parity.

---

## Phase 3 — Build the data model spec

Write the spec to `/tmp/<name>/dm-spec.json`. Full schema is in
`refs/data-model-spec.md`.

### Critical rules

1. **Endpoint**: `POST /v2/dataModels/spec` — NOT `/v2/workbooks/spec`.
2. **`folderId` is required.** Find it via `GET /v2/files?typeFilters=workbook` — `parentId` on any of your workbooks.
3. **Column name special characters** — read `refs/column-gotchas.md`. Rename any column whose `name` contains `/` ("Country/Region" → `"Country"`, "State/Province" → `"State"`).
4. **Element name = formula prefix**. The `name` field on a DM element (e.g. `"Orders"`) becomes the prefix in all workbook formulas that reference it: `[Orders/Sales]`. Choose clean, stable names.
5. **Relationships go on the source element**, not the target. See `refs/data-model-spec.md`.
6. **Column formulas use the warehouse table name as prefix**: path `["CSA", "Tableau Test", "ORDERS"]` → formula `"[ORDERS/Column Name]"`.

### When to use a Custom SQL element instead of a calc column

> **Sigma window functions silently fail in DM calc columns and in workbook master (grouping-table) calc columns.** `CountOver`, `SumOver`, `RankOver`, `RowNumberOver`, `MaxOver`, `MinOver`, `AvgOver`, `FirstOver`, `LastOver`, `MedianOver`, `StdDevOver`, `CumulativeSum`, `CumulativeAvg`, etc. all POST/PUT successfully and return `success: true`, but the column resolves as `error` on GET and the chart that references it renders blank. The validator now hard-fails on these (see `scripts/validate-spec.rb`), but the right fix at design time is to NOT write them as calc columns in the first place.

Any Tableau calc whose `requires_custom_sql: true` (from Phase 1e) — that is, any `WINDOW_*` / `RUNNING_*` / `RANK*` / `INDEX` / `FIRST` / `LAST` / `SIZE` / `TOTAL` / `LOOKUP` / `PREVIOUS_VALUE` table calc, or any `{FIXED/INCLUDE/EXCLUDE}` LOD — must be implemented as a **Sigma Custom SQL data-model element**:

```json
{
  "id": "el-orders-windowed",
  "kind": "table",
  "name": "Orders With Window Calcs",
  "source": {
    "connectionId": "<connection-id>",
    "kind": "sql",
    "statement": "SELECT o.ORDER_ID, o.REGION, o.SALES,\n  SUM(o.SALES) OVER (PARTITION BY o.REGION) AS REGION_TOTAL_SALES,\n  RANK() OVER (PARTITION BY o.REGION ORDER BY o.SALES DESC) AS SALES_RANK_IN_REGION,\n  SUM(o.SALES) OVER (ORDER BY o.ORDER_DATE ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUNNING_SALES\nFROM ANALYTICS.PUBLIC.ORDERS o"
  },
  "columns": [
    { "id": "c-order-id",      "name": "Order Id",            "formula": "[Custom SQL/ORDER_ID]" },
    { "id": "c-region",        "name": "Region",              "formula": "[Custom SQL/REGION]" },
    { "id": "c-sales",         "name": "Sales",               "formula": "[Custom SQL/SALES]" },
    { "id": "c-region-total",  "name": "Region Total Sales",  "formula": "[Custom SQL/REGION_TOTAL_SALES]" },
    { "id": "c-sales-rank",    "name": "Sales Rank in Region","formula": "[Custom SQL/SALES_RANK_IN_REGION]" },
    { "id": "c-running-sales", "name": "Running Sales",       "formula": "[Custom SQL/RUNNING_SALES]" }
  ]
}
```

Key points:
- `source.kind` is `"sql"` (not `"warehouse-table"`).
- `source.statement` is the raw SQL text (the field name is `statement`, NOT `sql`). Use the warehouse dialect for the underlying connection (Snowflake, BigQuery, etc.).
- Column formula prefix is `[Custom SQL/<ALIAS_FROM_SELECT_LIST>]`. The alias is whatever you wrote in the `SELECT ... AS NAME` clause. **Use UPPERCASE aliases** (matches Snowflake's default identifier casing); Sigma's column lookup is case-sensitive against the SQL output.
- Every column you want to expose in the DM needs both a SELECT-list entry in the SQL AND a corresponding `columns[]` entry on the DM element.
- Translation hints from `extract-calc-fields.rb`:
  - `RUNNING_SUM(SUM([X]))` → `SUM(X) OVER (ORDER BY <time> ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`
  - `WINDOW_SUM(SUM([X]))` → `SUM(X) OVER (<partition / order>)`
  - `RANK(SUM([X]))` → `RANK() OVER (PARTITION BY <p> ORDER BY <X> DESC)`
  - `{FIXED [Dim] : SUM([X])}` → `SUM(X) OVER (PARTITION BY Dim)` or a pre-aggregated subquery joined back
  - `LOOKUP(SUM([X]), -1)` → `LAG(X) OVER (ORDER BY <time>)`

When a workbook mixes plain calcs with window calcs, you can have BOTH kinds of DM elements in the same data model: one `warehouse-table` element for everything plain, plus one or more `sql` elements for the window/LOD calcs, related by key. Charts source from whichever element has the columns they need.

> **DM PUT reassigns element IDs.** Combining a `warehouse-table` element with a `sql` element in the same DM works fine, but every PUT of the DM spec churns IDs — so plan to capture IDs once with `post-and-readback.rb`, build the workbook from those IDs, and avoid editing the DM in flight.

### Translate Tableau calc fields here

Each calc from `calc-fields.json` (Phase 1e) becomes a DM calc column (or a workbook-level
calc on the master table, depending on grain). For calc columns that wrap a NULLABLE source
in an IF/ELSEIF chain, **wrap with `Coalesce` to match Tableau's null-fallthrough behavior**.

Example — Tableau:

```
IF [Lifetime Revenue] >= 5000 THEN "Platinum" ELSEIF >= 2000 THEN "Gold" ELSEIF >= 500 THEN "Silver" ELSE "Bronze" END
```

Sigma DM calc column on Order Fact (since the bucket depends on a joined dim):

```
If(Coalesce(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]), -1) >= 5000, "Platinum",
  If(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]) >= 2000, "Gold",
    If(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]) >= 500, "Silver", "Bronze")))
```

Without `Coalesce(-1)` orphan-joined rows produce a NULL bucket instead of falling into "Bronze"
the way Tableau's ELSE does — and parity will diverge.

### Validate before posting

```bash
ruby scripts/validate-spec.rb --type datamodel /tmp/<name>/dm-spec.json
```

Catches: formula prefix mismatches, bare refs not matching a sibling, `kpi`/`pie`/`donut` kind
mistakes, `rgb(...)` color strings (Cloudflare WAF blocks), missing yAxis on
bar/line/area/combo/scatter, missing color+value on pie/donut, donut `holeValue.id` matching
`value.id` (silent element drop), pivot-table missing rowsBy (single grand-total row), and
nested-If on date functions without IsNull guard.

Exit 0 = clean, exit 1 = errors printed to stdout.

---

## Phase 4 — POST the data model

```bash
eval "$(scripts/get-token.sh)" && \
ruby scripts/post-and-readback.rb --type datamodel \
  --spec /tmp/<name>/dm-spec.json \
  --out /tmp/<name>/dm-ids.json
```

The script:
- POSTs the spec,
- parses the YAML response (the spec endpoints return YAML by default),
- immediately GETs the spec back to retrieve server-assigned element IDs,
- writes a clean JSON map: `{dataModelId, pages: [{id, name, elements: [{id, kind, name}]}]}`.

Record the `dataModelId` and element IDs. The `dm-ids.json` is used by the
workbook validator (Phase 5) to accept `[Order Fact/...]` cross-source refs.

On error: read the message → fix the offending column formula → re-validate → re-POST.

---

## Phase 5 — Build the Sigma workbook

### 5a. Write the workbook spec

> **`folderId` is required here too.**

Source the master table from the data model. **Always set `visibleAsSource: false` on
the master table** — it is a source for charts, not a table users browse directly.

```json
{
  "id": "master",
  "kind": "table",
  "name": "Master",
  "visibleAsSource": false,
  "source": {
    "kind": "data-model",
    "dataModelId": "<dataModelId>",
    "elementId": "<elementId from dm-ids.json>"
  },
  "columns": [
    { "id": "c-sales", "formula": "[Orders/Sales]", "name": "Sales" }
  ],
  "order": ["c-sales"]
}
```

Master-table column formulas use the DM element's `name` as prefix (`[Orders/Sales]`, not the element ID).

Charts and KPIs on content pages source the master table and use ITS `name` as prefix.
Cross-page element references are fully supported — place the master on a hidden "Data"
page and reference it from every other page's elements via `"elementId": "master"`.

> **Master-table column scope.** Default: pull every column you've already denormalized
> in the DM into the master with passthrough formulas. The master is cheap; amending it
> later for a new control requires a workbook spec edit even though no chart breaks.

> **KPI kind is `kpi-chart`, not `kpi`. Pie is `pie-chart`. Donut is `donut-chart`.**
> The validator catches this; don't rely on it.

```json
{
  "kind": "kpi-chart",
  "source": { "kind": "table", "elementId": "master" },
  "columns": [
    { "id": "k-sales", "formula": "Sum([Master/Sales])", "name": "Total Sales",
      "format": {"kind": "number", "formatString": "$,.0f"} }
  ],
  "value": { "id": "k-sales" }
}
```

See `refs/workbook-layout.md` for chart patterns, multi-series formulas, and map shapes.

### 5b. Validate the workbook spec

```bash
ruby scripts/validate-spec.rb --type workbook \
  --dm-context /tmp/<name>/dm-ids.json \
  /tmp/<name>/wb-spec.json
```

`--dm-context` lets the validator accept `[Order Fact/...]` cross-source refs (where
"Order Fact" is a DM element name from Phase 4). Without it, every cross-source ref is
flagged as unknown.

### 5c. POST the workbook + readback

```bash
ruby scripts/post-and-readback.rb --type workbook \
  --spec /tmp/<name>/wb-spec.json \
  --out /tmp/<name>/wb-ids.json
```

> **Element IDs may or may not survive POST.** Workbook-spec POST often preserves readable
> string element IDs verbatim, but this is not contractual. Data-model-spec POST always
> reassigns IDs. Either way, the readback is the source of truth — use IDs from `wb-ids.json`
> when wiring layout XML.

### 5d. Build layout XML

Write a per-workbook layout config that `require`s the helper library. Never hand-write
layout XML.

```ruby
# /tmp/<name>/build-layout.rb
require 'json'
$LOAD_PATH.unshift File.expand_path('scripts/lib', __dir__)  # or absolute path
require 'layout'
include SigmaLayout

# Element IDs from Phase 5c
ids = JSON.parse(File.read('/tmp/<name>/wb-ids.json'))
e = ids['pages'][0]['elements'].each_with_object({}) { |x, h| h[x['id']] = x['id'] }

xml = assemble(
  page_xml('page-dashboard',
    le(e['title-text'],     1, 25,  1,  3),
    le(e['el-kpi-1'],       1,  7,  3,  9),
    le(e['el-kpi-2'],       7, 13,  3,  9),
    le(e['el-chart-1'],     1, 13,  9, 21),
    le(e['el-chart-2'],    13, 25,  9, 21)
  ),
  page_xml('page-data', le('master', 1, 25, 1, 21))
)

File.write('/tmp/<name>/layout.xml', xml)
```

Layout helpers (in `scripts/lib/layout.rb`): `gc(eid, c0, c1, r0, r1, inner)` for
`<GridContainer>`, `le(eid, c0, c1, r0, r1)` for `<LayoutElement>`, `page_xml(page_id, *children)`
to wrap a page, `assemble(*pages)` to add the XML prologue.

See `refs/workbook-layout.md` for typical page layouts (4 KPIs + line chart + 2 bars,
multi-row containers, etc.) and rules (`<GridContainer>` for nesting, KPI inner `gridRow`
must match container outer span).

### 5e. PUT the layout

```bash
ruby scripts/put-layout.rb \
  --workbook <workbookId> \
  --layout /tmp/<name>/layout.xml
```

The script:
- GETs the current workbook spec,
- replaces per-page `layout` with a single top-level `layout` (per-page layouts are silently dropped),
- strips read-only fields (`workbookId`, `url`, `ownerId`, `createdBy`, `updatedBy`, `createdAt`, `updatedAt`, `latestDocumentVersion`),
- aborts if any `elementId=""` appears in the XML,
- PUTs the full payload back.

PUT preserves existing element IDs. Only newly-added elements get new IDs.

---

## Phase 6 — Verify chart data matches Tableau (MANDATORY)

> **A conversion is not complete until Phase 6 has run and either passed or been explicitly accepted with documented divergences.** PUT returning `success: true` only proves the spec parsed — it tells you nothing about whether each chart shows the right numbers. Two recent customer-visible bugs both reached the customer because Phase 6 was skipped: a window-function calc compiling silently as `error` and a pie chart wired to the wrong dimension.

### 6a. Auto-build a parity plan

Don't hand-write the plan. Use the auto-builder, which matches Sigma chart-element names to Tableau view CSVs and emits a plan keyed by chart:

```bash
ruby scripts/auto-parity-plan.rb \
  --tableau /tmp/<name> \
  --workbook-spec /tmp/<name>/wb-spec.json \
  --workbook-id <sigma-workbook-id> \
  --out /tmp/<name>/parity-plan.json
```

The output is wrapped as `{ "extract": <bool>, "charts": [...] }` — the `extract` flag is set automatically from `get-workbook.json`'s `hasExtracts` field when the workbook itself is extract-backed. If a Sigma chart was renamed from its Tableau title (e.g., the pie tile renamed from "Order Channel vs Ship Method" → "Orders by Category"), pass `--rename "Order Channel vs Ship Method=Orders by Category"` so the auto-matcher pairs them.

> **Extract status is also visible on the workbook's datasource.** `auto-parity-plan.rb` only reads workbook-level `hasExtracts`. If the underlying datasource has an extract but the workbook attribute is `false`, you'll have to flip the `extract` field by hand OR pass `--extract-mode` to verify-parity.rb.

### 6b. Fetch Sigma actuals

For every chart in the plan that lacks an `actual` key, query Sigma and paste the result rows:

```
mcp__sigma-mcp-v2__query  type="workbook"  workbookId="<wbId>"
  sql='SELECT "<dim-col-id>", ROUND("<measure-col-id>"::numeric, 2) FROM "workbook"."<element-id>" ORDER BY 1'
```

The plan file pre-populates `sql_template` and `workbookId` on each chart — just run the SQL and paste the resulting rows under `"actual": { "rows": [...] }`.

> **A chart element's SQL view exposes only that chart's own columns.** A `WHERE "m-order-date-key" BETWEEN ...` against `el-rev-by-region` fails with `Unresolved column`. Two ways to handle:
> - Query the master table directly (`FROM "workbook"."master"`) and aggregate in SQL.
> - Skip the filter and compare what the chart shows. Workbook control filters are not applied at API-query time, so a `type="workbook"` SQL query against a chart element returns the full unfiltered dataset.

### 6c. Run the verifier

```bash
# Strict (default): exact value comparison
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json

# Extract mode: structural comparison only, tolerant of value drift
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json --extract-mode
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json --extract-mode --extract-tol 0.50
```

Output: per-chart `PASS` or `DIVERGE`. Exit 0 on full pass, 1 on any divergence.

### 6d. Extract handling

When the Tableau workbook (or its datasource) has `hasExtracts: true`, the view CSVs reflect a **frozen snapshot** of the warehouse from the last extract refresh. Sigma queries the warehouse live, so the absolute values WILL drift — that's expected, not a bug. `--extract-mode` shifts the check to:

- ✓ same number of buckets (rows in the chart)
- ✓ same set of dimension values
- ✓ same sort order on the dimension
- ⚠ measure values within `--extract-tol` (default 30%) — anything outside is flagged but does NOT fail the check; review case-by-case

If the customer expects Tableau-extract numbers to match Sigma-live numbers exactly, the answer is to refresh the Tableau extract before exporting CSVs OR to point Sigma at the same snapshot via a saved query. Otherwise live-vs-extract divergence is structural, not a parity bug.

### 6e. Triage divergences (strict mode)

| Symptom | Likely cause |
|---|---|
| Numbers wrong by a constant factor | Aggregation mismatch (Sum vs Avg vs CountDistinct) |
| Wrong dimension values | `[Master/...]` formula references the wrong column |
| Date axis has 24 buckets where Tableau shows 12 | Cross-year month rollup — see `refs/column-gotchas.md` |
| Sigma chart shows extra dim values Tableau never displays | Missed Phase 2.5 filter — apply the filter as `date-range`/`list`/`top-n` |
| Bucket values differ but ratios match | Wrong source column — see Phase 3 "Translate Tableau calc fields here". A `Customer Value Tier` Tableau calc-derived from `Lifetime Revenue` must NOT be replaced by a warehouse `LOYALTY_TIER` column |
| Empty result / column resolves as `error` | `mcp__sigma-mcp-v2__describe` on the element; type `error` means the formula failed to compile (often `IsIn`, unsupported window function, or missing-column ref) |
| Numbers consistently within ±X% across all buckets | Extract drift — switch to `--extract-mode` if the source workbook has `hasExtracts: true` |

### 6b. Triage divergences

| Symptom | Likely cause |
|---|---|
| Numbers wrong by a constant factor | Aggregation mismatch (Sum vs Avg vs CountDistinct) |
| Wrong dimension values | `[Master/...]` formula references the wrong column |
| Date axis has 24 buckets where Tableau shows 12 | Cross-year month rollup — see `refs/column-gotchas.md` |
| Sigma chart shows extra dim values Tableau never displays | Missed Phase 2.5 filter — apply the filter as `date-range`/`list`/`top-n` |
| Bucket values differ but ratios match | Wrong source column — see Phase 3 "Translate Tableau calc fields here". A `Customer Value Tier` Tableau calc-derived from `Lifetime Revenue` must NOT be replaced by a warehouse `LOYALTY_TIER` column |
| Empty result / column resolves as `error` | `mcp__sigma-mcp-v2__describe` on the element; type `error` means the formula failed to compile (often `IsIn`, unsupported window function, or missing-column ref) |

### 6c. Trust the CSV, not the dashboard caption

A Tableau dashboard's chart title is hardcoded text on the dashboard, not derived from
the underlying view. When a Tableau author replaces a chart's data without updating the
title, the caption lies. **The view's `get-view-data` CSV is the source of truth** —
build the Sigma chart against the CSV's actual columns and pick a truthful Sigma name,
even if it disagrees with what's printed above the bars in Tableau.

### 6d. Phantom `--metric-["..."]` columns

`mcp__sigma-mcp-v2__query` with `type="workbook"` appends synthetic columns of the form
`--metric-["<colId>"]` whose values look like `Column "X.--metric-[...]" does not exist.`.
Harmless — your explicitly-SELECTed columns return correct values alongside the noise.

---

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `Expecting UUID at 0.folderId but instead got: undefined` | `folderId` missing from spec | Find with `GET /v2/files?typeFilters=workbook` → `parentId` |
| `Invalid kind: 'kpi' \| 'pie' \| 'donut'` | Used Sigma example library naming | Replace with `kpi-chart` / `pie-chart` / `donut-chart`; the validator catches this |
| Element kind rejected, unknown | Guessed an unsupported kind | `GET /v2/workbooks/<existing-id>/spec` and read `kind` fields of real elements |
| `dependency not found: formula reference 'orders/country region'` | Slash in column `name` field | Rename the column to "Country" before saving the DM spec |
| All columns on a table fail together | One bad formula poisons the element | Find the specific bad ref in the error message; fix only that column |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML | Use `post-and-readback.rb` (it parses YAML); never pipe spec responses to `jq` |
| Validator flags `[X/col]` as unknown prefix on a workbook spec | `--dm-context` not passed | Re-run with `--dm-context /tmp/<name>/dm-ids.json` |
| `401` on `get-view-data` in parallel batch | VizQL session contention | Retry that view solo; if still 401, skip — view is inaccessible |
| `401` on `get-view-image` | Always solo, never parallel with other view calls | Retry the image solo, no concurrent requests |
| `429` on Tableau view image | Rate limited | Wait and retry |
| Column fetch returns empty list | Response key is `entries`, not `columns` | Use `discover-warehouse-columns.rb` (handles this) |
| PUT returns `invalid_request` with no field named | Read-only metadata fields included in PUT body | Use `put-layout.rb` (strips them) |
| PUT returns `Invalid 1: schemaVersion, got undefined` | `schemaVersion` stripped from PUT body | Keep `schemaVersion`; the script preserves it |
| Layout PUT rejected, some elements not visible | `elementId=""` in layout XML | Script aborts on this; check the per-workbook layout config for nil IDs and guard with `.compact` |
| Layout has elements stacked vertically | No layout XML provided, or wrong IDs | Read IDs from `wb-ids.json` (Phase 5c readback), not your spec |
| KPI names invisible / truncated inside container | Inner `gridRow` smaller than container's outer span — `gridTemplateRows="auto"` does NOT expand | Set inner KPI `gridRow` end = container outer end |
| Empty containers visible on page | Container elements in spec but layout XML uses `<LayoutElement>` not `<GridContainer>` for them | Use `gc(...)` helper, not `le(...)`, for elements that wrap children |
| Wrong endpoint — workbook created instead of data model | Used `--type workbook` instead of `--type datamodel` | Delete the workbook; re-POST with the right `--type` |
| Bar chart renders vertical but Tableau shows horizontal | Orientation is UI-only — `"orientation": "horizontal"` silently dropped | Set post-publish: chart editor → Properties → Chart type → Horizontal |
| Sigma chart shows dim values Tableau's view never had | Missed Phase 2.5 filter | Diff CSV signals vs warehouse; add the filter as control/element-level |
| Axis label rotation / dashboard title alignment | UI-only fields | Set in element editor post-publish |
| `mcp__sigma-mcp-v2__query` returns "Table X not found" | Workbook queries don't resolve element names as table refs | Use `type: "connection"` with raw inodeId for unfiltered warehouse queries |
| `Unresolved column: <name>` on workbook/datamodel query | These surfaces expose **column IDs**, not display names | `describe` the element first; use the quoted IDs from the DDL |
| `Duplicate id: 'ctl-xxx'` on workbook POST | A control element's `id` matches its `controlId` (same namespace) | Use distinct values: `id: "el-ctl-region"`, `controlId: "ctl-region"` |
| Integer date key column renders as number axis | `ORDER_DATE_KEY` stored as YYYYMMDD integer | Cast in workbook column: `Date(Left(Text([Master/ORDER_DATE_KEY]), 4) & "-" & Mid(..., 5, 2) & "-" & Right(..., 2))`. `DateParse()` and `ToText()` do not exist in Sigma. |
| Sigma line chart shows 24 month-year buckets where Tableau shows 12 month names | Tableau MONTH part collapses across years; Sigma `DateTrunc("month", ...)` preserves year | See `refs/column-gotchas.md` "Cross-year month rollup" |
| Parity DIVERGE: bucket values differ but ratios match | Wrong source column for a Tableau calc | Calc-derived buckets must be re-derived from the same source the Tableau calc used (see `calc-fields.json` from Phase 1e), not from a same-named warehouse column |
| Calc-extracted formula uses `IIF`/`COUNTD`/LOD | Tableau syntax that's not 1:1 with Sigma | `IIF(c,t,e)` → `If(c,t,e)`; `COUNTD(x)` → `CountDistinct(x)`; LOD expressions need a per-case Sigma equivalent (window, Lookup, or pre-aggregation) |
| Ruby heredoc inside `bash -c '...'` fails with backslash errors | Bash's single-quoted block reaches into the heredoc | Write Ruby to a file with the `Write` tool and run `ruby /tmp/script.rb` |
