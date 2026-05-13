---
name: tableau-to-sigma
description: >-
  Convert a Tableau datasource or workbook into a Sigma data model and matching
  dashboard. Use when the user has a Tableau datasource, TDS file, or Tableau
  workbook and wants to recreate it in Sigma. Covers column discovery, data
  model creation via REST API, and dashboard layout generation using Ruby.
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

## Prerequisites

### Sigma credentials

Run the setup script once. It stores credentials in `~/.claude/settings.json` so
they are loaded automatically into every future session:

```bash
ruby scripts/setup.rb
```

Then open a new Claude Code session (or run `! source ~/.claude/settings.json`)
so the env vars are live. Every script validates they exist and aborts with a
clear message if they are missing.

Required env vars:
- `SIGMA_BASE_URL` — e.g. `https://aws-api.sigmacomputing.com`
- `SIGMA_CLIENT_ID`
- `SIGMA_CLIENT_SECRET`

### Tableau access

The Tableau MCP tools (`mcp__tableau__*`) are used for metadata retrieval and
must already be authenticated in the session. Direct Tableau PAT auth via curl
frequently returns 401 — always prefer MCP.

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
>
> When this happens: the Phase 6 row-count comparison will fail dramatically (one view I
> converted showed 70 orders in Tableau while Sigma reported 526), but the relative
> proportions and bucket structures still match. Tell the user up front that absolute
> totals may differ, and verify shape parity (does each weekday × year combination have a
> value? are the status categories the same?) instead of value-by-value parity.

### 1c. Get workbook views

```
mcp__tableau__get-workbook   workbookId="<luid>"
```

Returns the list of views (sheets) with their `id` and `name`. Record all view IDs.

### 1d. Retrieve view images

`get-view-image` requires a warm VizQL session. The root cause of most 401s is
**session contention**: firing many requests simultaneously causes them to compete
for the same VizQL session, and most fail — regardless of whether the cache is warm
or whether the view has been visited in a browser. Browser visits are not required.

**The reliable pattern — warm solo, then image solo, one view at a time:**

Step 1 — warm the view:
```
mcp__tableau__get-view-data   viewId="<id1>"
```
Step 2 — immediately fetch the image for that same view before starting the next:
```
mcp__tableau__get-view-image   viewId="<id1>"   format="PNG"   width=1400   height=900
```
Step 3 — repeat for each remaining view.

If `get-view-data` returns 401, skip that view entirely — the image will also fail.

> **Do not fire all views in a parallel batch.** Even if `get-view-data` succeeds in
> a parallel batch, a concurrent `get-view-image` in the same batch will still 401
> due to session contention. Process views one at a time.

Use the images to understand:
- How many KPIs are in the header row and what they measure
- Which chart types are used (bar, line, scatter, map, small multiples)
- The rough grid layout of each page (columns × rows)
- **Page titles, section headers, and any free-text annotations on the dashboard surface** — these are real content (not metadata) and need to be recreated as `text` elements in the Sigma spec. The page tab name (`page['name']`) is *not* a substitute; it only appears in the tab bar, not on the canvas. If the Tableau dashboard shows a heading like "Orders Dashboard" at the top of the page, add a `text` element with `body: "# Orders Dashboard"` and reserve a row for it in the layout.

**Also extract from each view CSV the distinct values of every dimension column and the min/max of every date column** — write them down. Phase 2.5 compares these against the warehouse to detect view-level filters that the Tableau MCP doesn't expose explicitly. A view that emits only `{Q1, Q2}` for a Quarter column when the warehouse contains all four quarters is a filter, not a coincidence.

Sigma spec supports: `bar-chart`, `line-chart`, `area-chart`, `combo-chart`, `scatter-chart`, `kpi-chart`, `pie-chart`, `donut-chart`, `region-map`, `point-map`, `table`, `pivot-table`, `control`, `text`, `image`, `container`.

> **Common kind mistakes — all three are rejected by the API:**
> - `"kpi"` → must be `"kpi-chart"`
> - `"pie"` → must be `"pie-chart"`
> - `"donut"` → must be `"donut-chart"`
>
> The official Sigma example library shows `kpi`, `pie`, and `donut` — all three are wrong. Do not
> follow it. If uncertain about a kind, GET an existing workbook spec (`GET /v2/workbooks/<id>/spec`)
> and read the `kind` fields directly.

Does **not** support via the spec API: bullet chart, gantt.

**Maps are fully spec-supported.** Use `region-map` for choropleths (US state / county / ZIP / CBSA / country fills) and `point-map` for lat/long bubble or symbol maps. See `refs/workbook-layout.md` "Map elements" for the field shape, the exact set of valid `regionType` values (e.g., `us-zipcode`, not `us-zip`; `us-cbsa`, not `us-msa`), and the color-channel rules.

**Trellis (small multiples) is supported in Sigma but configured UI-only.** Bar / line / area / scatter / pie / donut / combo charts can be trellised via the chart editor's **Trellis** panel (Trellis row / Trellis column / Trellis by series). The trellis configuration is **not** exposed in the workbook spec — POST/PUT silently drop fields like `trellisRow`, `trellisColumn`, `trellisRows`, `trellisColumns`, `trellisBy`, and `format.trellis`, and a trellis applied via the UI does not appear in the GET spec either. Build the chart with the right dimensions via spec, then trellis it manually post-publish.

Control types supported: `list`, `date-range`, `text`, `text-area`, `segmented`, `number`, `number-range`, `slider`, `range-slider`, `top-n`.
See `refs/workbook-layout.md` for full control element spec patterns.

---

## Phase 2 — Discover actual warehouse column names

> **This step is mandatory. Do not skip it or infer column names from Tableau.**

Tableau display names ("Sub-Category", "Country/Region") are NOT the same as
Snowflake warehouse column names ("SUB_CATEGORY", "COUNTRY_REGION"). Using the
wrong names produces "dependency not found" errors at publish time.

Fetch a token once now — it's valid for ~1 hour and covers all curl calls in Phases 2–5:

```bash
eval "$(scripts/get-token.sh)"
```

> **Token persistence in multi-command blocks:** `eval` sets env vars in the current
> shell. If you need to combine eval and curl in a single `bash -c '...'` block, keep
> them in the same invocation. Never use `TOKEN=$(eval "$(scripts/get-token.sh)")` —
> the `$()` creates a subshell where the exported var dies immediately.

### 2a. Find the connection

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections" | jq '[.entries[] | {name, connectionId}]'
```

### 2b. Find the table inode/urlId

Search by name, or use the Sigma MCP tool:

```
mcp__sigma-mcp-v2__search   query="<table name>"
```

The search result includes a `urlId` or `inodeId` for the table.

### 2c. Fetch actual column names

Run all tables in parallel — one curl per table, all at the same time:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/tables/<urlId1>/columns"

curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/tables/<urlId2>/columns"
```

> **Response key is `entries`, not `columns`.** Parse with `.get('entries', [])`, not `.get('columns', [])`.
> Using `columns` returns an empty list silently — no error, just missing data.

These are the **exact** column names to use in data model element formulas:
`[TABLE_NAME/Column Name]`.

---

## Phase 2.5 — Detect view-level filters (mandatory)

> **The Tableau view CSV is the source of truth for what the dashboard *renders* — not what's in the warehouse.** Tableau MCP does not expose worksheet/dashboard filters directly, so you have to **infer them from the data the view emits**. A view that omits part of a dimension's values isn't a coincidence; it's a filter, and you must translate it into Sigma. Skipping this step ships a workbook that "renders fine" but disagrees with the source on totals, axis ticks, or visible categories.

### How to detect

For every dimension column on every view, compare:

| Source                         | Query                                              |
|--------------------------------|----------------------------------------------------|
| **View CSV** (Phase 1d)        | Distinct values in the column; min/max for dates   |
| **Warehouse** (after Phase 2)  | `SELECT DISTINCT <col>` / `SELECT MIN, MAX <date>` via `mcp__sigma-mcp-v2__query` (`type: "connection"` with the table inodeId) |

Any value present in the warehouse but missing from the CSV implies a filter on that column.

```sql
-- Warehouse range check
SELECT MIN("DATE") AS min_date, MAX("DATE") AS max_date,
       COUNT(DISTINCT DATE_TRUNC('quarter', "DATE")) AS qtr_count
FROM "connection"."<table-inodeId>"
```

### Common patterns

| View CSV symptom                                    | Likely Tableau filter            | Sigma translation |
|-----------------------------------------------------|----------------------------------|-------------------|
| Only some values of a categorical column appear     | "Keep only" / dimension filter   | `list` control with `mode: "include"`, or element-level filter |
| Date min/max is narrower than warehouse             | Date / relative-date filter      | `date-range` control — `mode: "current"` + `unit: "year"\|"quarter"\|...` for relative; `mode: "between"` with explicit `startDate`/`endDate` for fixed |
| Numeric column is bounded                           | Range filter                     | `number-range` or `range-slider` control, or element-level filter |
| Only top N items by some measure                    | Top-N filter                     | `top-n` control or element-level `top-n` filter (see `refs/workbook-layout.md`) |

### Where to apply the filter

Prefer a **workbook-level control filtering the master table** — every chart that sources from master inherits the filter, matching how a Tableau dashboard filter works. Use **element-level filters** only when the filter is fixed and shouldn't be user-adjustable (a hard-coded slice).

Control filter target shape:
```json
"filters": [{"source": {"kind": "table", "elementId": "master"}, "columnId": "<master-col-id>"}]
```

> **A relative-date filter that "rolls forward" in Tableau** ("this year", "last 30 days", "year to date") must be translated as a relative `date-range` control (`mode: "current"`, `unit: ...`) — not a fixed start/end date. Hard-coding `startDate`/`endDate` freezes the filter to today's date and breaks tomorrow.

> **Phase 6 will not catch a missed filter on its own.** Data parity in Phase 6 compares Sigma rows to Tableau rows for the dimensions you query — if your Sigma chart includes extra rows the CSV never had, the comparison only flags missing rows from Tableau, not extra rows in Sigma. Always sanity-check distinct values and date ranges side-by-side before declaring parity.

---

## Phase 3 — Build the data model spec

Write the spec to `/tmp/<name>-datamodel-spec.json`. Full schema is in
`refs/data-model-spec.md`.

### Critical rules

1. **Endpoint**: `POST /v2/dataModels/spec` — NOT `/v2/workbooks/spec`.
   These create completely different objects.

2. **`folderId` is required.** The POST will fail with `"Expecting UUID at 0.folderId but instead got: undefined"`
   if omitted. Find it by listing your documents: `GET /v2/files?typeFilters=workbook` — the `parentId`
   on any of your workbooks is your My Documents folder ID.

3. **Column name special characters** — read `refs/column-gotchas.md` fully.
   Key rule: rename any column whose `name` field contains `/` before saving
   the spec. "Country/Region" → `"name": "Country"`, "State/Province" → `"name": "State"`.
   Slashes in column names break formula references in every downstream workbook.

4. **Element name = formula prefix**. The `name` field on a data model element
   (e.g. `"name": "Orders"`) becomes the prefix in all workbook formulas that
   reference it: `[Orders/Sales]`. Choose clean, stable names.

5. **Relationships go on the source element**, not the target. See `refs/data-model-spec.md`
   for the exact shape.

6. **Column formulas use the warehouse table name as prefix**:
   - Path `["CSA", "Tableau Test", "ORDERS"]` → prefix is `ORDERS`
   - Formula: `"[ORDERS/Column Name]"`

### Validate before posting

```bash
python3 -c "
import json, re, sys
spec = json.load(open('/tmp/<name>-datamodel-spec.json'))  # update filename to match your spec
errors = []

# First pass — index every element name across the spec for cross-element ref checks
all_element_names = set()
for page in spec.get('pages', []):
    for el in page.get('elements', []):
        if el.get('name'):
            all_element_names.add(el['name'])

# Spec-level scan — rgb(...) color strings anywhere in the spec get blocked by
# Sigma's Cloudflare WAF with HTTP 403. Use hex (#RRGGBB) instead.
if 'rgb(' in json.dumps(spec):
    errors.append('spec contains rgb(...) color strings — Cloudflare WAF blocks these with HTTP 403. Replace every rgb(R,G,B) with hex #RRGGBB.')

for page in spec.get('pages', []):
    for el in page.get('elements', []):
        kind = el.get('kind', '')
        name = el.get('name', el.get('id', '?'))
        cols = el.get('columns', []) + el.get('metrics', [])
        el_col_names = {c['name'] for c in cols}

        # Valid prefixes for [Prefix/Col] refs on THIS element's formulas:
        #   1. Last segment of own source.path (for warehouse-table sources) — e.g. ORDER_FACT
        #   2. \"Custom SQL\" literal — for source.kind == \"sql\" elements
        #   3. Any OTHER element's name in this spec — for cross-element Lookup() refs
        src = el.get('source', {})
        own_prefixes = set()
        if src.get('kind') == 'warehouse-table' and src.get('path'):
            own_prefixes.add(src['path'][-1])
        if src.get('kind') == 'sql':
            own_prefixes.add('Custom SQL')
        # Bare formula refs without a source prefix — must resolve to a column on the same element.
        # Prefixed refs ([Prefix/Col]) — Prefix must be own source OR another element's name.
        for col in cols:
            formula = col.get('formula', '') or ''
            for ref in re.findall(r'\[([^\]]+)\]', formula):
                if '/' in ref:
                    prefix = ref.split('/', 1)[0]
                    if prefix not in own_prefixes and prefix not in all_element_names:
                        errors.append(f'{name}.{col.get(\"name\")}: ref [{ref}] — prefix \"{prefix}\" is not the element source nor a known element name in this spec')
                else:
                    if ref not in el_col_names:
                        errors.append(f'{name}: bare ref [{ref}] has no match on the same element')

            # Nested-If categorization on a date function with no outer IsNull guard.
            # null Weekday/Month/etc. falls through every comparison and lands in the
            # else string, silently misbucketing null rows.
            if re.search(r'\b(Weekday|Month|Year|Quarter|Day|Hour|Minute)\s*\(', formula, re.IGNORECASE):
                if 'If(' in formula and 'IsNull(' not in formula and 'Coalesce(' not in formula:
                    errors.append(f'{name}.{col.get(\"name\")}: nested-If on a date function without IsNull/Coalesce — null source values silently fall through to the else branch. Wrap with If(IsNull([source]), Null, ...).')

        # Common kind mistakes — API rejects all three
        if kind == 'kpi':
            errors.append(f'{name}: invalid kind \"kpi\" — must be \"kpi-chart\"')
        if kind == 'pie':
            errors.append(f'{name}: invalid kind \"pie\" — must be \"pie-chart\"')
        if kind == 'donut':
            errors.append(f'{name}: invalid kind \"donut\" — must be \"donut-chart\"')

        # kpi-chart must have value field
        if kind == 'kpi-chart' and 'value' not in el:
            errors.append(f'{name}: kpi-chart missing value field')

        # pie-chart and donut-chart must have color + value
        if kind in ('pie-chart', 'donut-chart'):
            if 'color' not in el:
                errors.append(f'{name}: {kind} missing color field')
            if 'value' not in el:
                errors.append(f'{name}: {kind} missing value field')

        # donut-chart holeValue is optional, but if present:
        #   - must be an object {\"id\": \"col-id\"} (literal floats are rejected)
        #   - id must NOT equal value.id (matching IDs silently drops the entire element)
        if kind == 'donut-chart' and 'holeValue' in el:
            hv = el['holeValue']
            if not isinstance(hv, dict) or 'id' not in hv:
                errors.append(f'{name}: donut-chart holeValue must be {{\"id\": \"<col-id>\"}} — literal floats are rejected with \"Invalid object: number\"')
            else:
                vid = el.get('value', {}).get('id')
                if hv.get('id') == vid:
                    errors.append(f'{name}: donut-chart holeValue.id ({hv[\"id\"]}) equals value.id — element is silently dropped on POST. Add a second column with a distinct id (same formula is fine).')

        # chart types that must use yAxis, not measures
        if kind in ('bar-chart', 'line-chart', 'area-chart', 'combo-chart', 'scatter-chart'):
            if 'measures' in el:
                errors.append(f'{name}: use yAxis not measures for {kind}')
            if 'yAxis' not in el:
                errors.append(f'{name}: {kind} missing yAxis')

        # pivot-table needs rowsBy (+ optionally columnsBy). Without them, the element
        # round-trips as a single grand-total row — silent rendering failure.
        if kind == 'pivot-table':
            if 'rows' in el or 'columnGroups' in el:
                errors.append(f'{name}: pivot-table must use rowsBy/columnsBy, not rows/columnGroups')
            if not el.get('rowsBy'):
                errors.append(f'{name}: pivot-table without rowsBy renders only a grand-total row — add rowsBy[{{\"id\": \"...\"}}]')
            for field in ('rowsBy', 'columnsBy'):
                arr = el.get(field, [])
                if arr and isinstance(arr[0], str):
                    errors.append(f'{name}: pivot-table {field} must be object array [{{\"id\": \"col-id\"}}], not string array')
            values = el.get('values', [])
            if values and isinstance(values[0], dict):
                errors.append(f'{name}: pivot-table values must be string array [\"col-id\"], not object array')

for e in errors: print('ERROR:', e)
sys.exit(len(errors))
"
```

---

## Phase 4 — POST the data model

```bash
curl -s -X POST \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/<name>-datamodel-spec.json \
  "$SIGMA_BASE_URL/v2/dataModels/spec"
```

> **Response format is YAML, not JSON.** Do NOT pipe to `jq`. Parse with Ruby:
>
> ```bash
> ruby -r yaml -r json -e \
>   "puts JSON.pretty_generate(YAML.safe_load(STDIN.read, permitted_classes:[Date,Time]))"
> ```

> **POST response only contains `dataModelId` — no element IDs.** After a successful POST,
> immediately GET the data model spec to retrieve server-assigned element IDs:
>
> ```bash
> curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
>   "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
>   -o /tmp/dm-get.yaml
>
> ruby -r yaml -r date - <<'EOF'
> require 'date'
> d = YAML.safe_load(File.read('/tmp/dm-get.yaml'), permitted_classes: [Date, Time])
> puts "dataModelId: #{d['dataModelId']}"
> d['pages'].each do |pg|
>   puts "page: #{pg['id']} #{pg['name']}"
>   (pg['elements'] || []).each { |e| puts "  elementId: #{e['id']}  name: #{e['name']}" }
> end
> EOF
> ```

Record the `dataModelId` and element IDs — you need both for workbook source references.

On error: read `refs/column-gotchas.md` → fix the offending column formula → retry.

---

## Phase 5 — Build the Sigma workbook

### 5a. Write the workbook spec

> **`folderId` is required here too.** Omitting it causes `"Expecting UUID at 0.folderId"`.
> Use the same folder ID from Phase 3 (your My Documents folder ID).

Source elements in the workbook from the data model. **Always set `visibleAsSource: false` on
the master table** — it is a source for charts, not a table users should browse directly:

```json
{
  "id": "master",
  "kind": "table",
  "name": "Master",
  "visibleAsSource": false,
  "source": {
    "kind": "data-model",
    "dataModelId": "<dataModelId>",
    "elementId": "<elementId from data model>"
  },
  "columns": [
    { "id": "c-sales", "formula": "[Orders/Sales]", "name": "Sales" }
  ],
  "order": ["c-sales"]
}
```

Column formulas in the master table use the data model element's `name` as prefix
(`[Orders/Sales]`, not the element ID).

Charts and KPIs on content pages source the master table element and use ITS
`name` as prefix. **Cross-page element references are fully supported** — it is
correct and recommended to place the master table on a single "Data" page and
reference it from every other page's elements via `"elementId": "master"`.

> **Master-table column scope determines what controls and future charts can see.** Every column that the data model element exposes does NOT have to be on the master — and pruning the master to "only what current charts need" produces a leaner spec. But the moment a user wants a new control (e.g. "filter by Ship Method"), or a follow-up chart needs a different dimension, you have to amend the master and re-PUT. Default: pull every column you've already denormalized in the data model into the master with `[Element/Col]` passthrough formulas — the master is cheap and amending it later requires a workbook spec edit even though no chart breaks.

> **KPI kind is `kpi-chart`, not `kpi`.** Using `"kind": "kpi"` produces
> `"Invalid kind: 'kpi'"`. All KPI elements must use `"kind": "kpi-chart"`.

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

For multi-series line charts (approximating Tableau small multiples):
```json
{ "formula": "Sum(If([Master/Segment] = \"Consumer\", [Master/Sales], Null))", "name": "Consumer" }
```

See `refs/workbook-layout.md` for full chart patterns.

### 5b. POST the workbook spec

```bash
curl -s -X POST \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/workbook-spec.json \
  "$SIGMA_BASE_URL/v2/workbooks/spec" -o /tmp/wb-response.yaml

# Parse the YAML response — never pipe directly to jq
ruby -r yaml -r json -r date -e \
  "d=YAML.safe_load(File.read('/tmp/wb-response.yaml'),permitted_classes:[Date,Time]); \
   puts 'workbookId: ' + d['workbookId'].to_s"
```

> **Always GET the spec back before building layout XML.** Workbook-spec POST often
> preserves readable string element IDs (e.g. `master`, `el-rev-by-region`) verbatim,
> but this is not contractual — it has been observed to vary. Data-model-spec POST
> *always* reassigns element IDs regardless of what you supplied. Either way, GET
> the spec immediately after POST and use whatever IDs come back when wiring the
> layout XML; never assume your spec IDs survived.

### 5c. GET the spec back and extract real IDs

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks/<workbookId>/spec" \
  > /tmp/current-spec.yaml

# Extract page/element ID map with Ruby
ruby -r yaml -r date - <<'EOF'
require 'date'
spec = YAML.safe_load(File.read('/tmp/current-spec.yaml'), permitted_classes: [Date, Time])
spec['pages'].each do |page|
  puts "\n#{page['id']} : #{page['name']}"
  page['elements'].each { |e| printf "  %-24s %-14s %s\n", e['id'], e['kind'], e['name'] }
end
EOF
```

### 5d. Build layout XML with Ruby — MANDATORY

**Never hand-write layout XML.** Write a fresh Ruby script for each workbook using the
helpers and patterns in `refs/workbook-layout.md`. The script in `scripts/build-layout.rb`
contains generic stubs but uses hardcoded element names — **do not call it directly**.
Instead follow the full pattern from `refs/workbook-layout.md` using the real element IDs
from step 5c.

The script must:
1. Load `/tmp/current-spec.yaml` and build an element name→ID map per page
2. Build page XML using `gc()` / `le()` / `page_xml()` helpers
3. Strip all read-only fields (`workbookId`, `url`, `ownerId`, `createdBy`, `updatedBy`, `createdAt`, `updatedAt`, `latestDocumentVersion`) and per-page `layout` keys
4. Set `spec['layout']` at the top level (never on individual page objects)
5. Write JSON to `/tmp/workbook-with-layout.json`
6. Verify no `elementId=""` before returning

### 5e. PUT the spec with layout

Build the PUT body from the GET YAML spec — strip read-only fields before writing:

```ruby
spec = YAML.safe_load(File.read('/tmp/current-spec.yaml'), permitted_classes: [Date, Time])
spec['pages'].each { |p| p.delete('layout') }
spec['layout'] = layout_xml_string
%w[workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion].each { |k| spec.delete(k) }
# Keep: name, documentVersion, folderId, schemaVersion, pages, layout
File.write('/tmp/workbook-with-layout.json', JSON.pretty_generate(spec))
```

Then PUT:

```bash
curl -s -X PUT \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/workbook-with-layout.json \
  "$SIGMA_BASE_URL/v2/workbooks/<workbookId>/spec"
```

PUT preserves existing element IDs. Only newly added elements get new IDs.

---

## Phase 6 — Verify chart data matches Tableau

> **This step is mandatory. PUT returning `success: true` only proves the spec parsed —
> it tells you nothing about whether each chart shows the right numbers.** A bad column
> formula can resolve to type `error` and silently render an empty chart; a wrong
> dimension or aggregation can ship "successful" but display the wrong story.

For every content chart, query the workbook element via Sigma MCP and compare row-by-row
to the `mcp__tableau__get-view-data` CSV captured in Phase 1.

### 6a. Query each chart element

Use the spec column IDs you wrote (preserved on PUT) and the workbook ID returned by POST:

```
mcp__sigma-mcp-v2__query  type="workbook"  workbookId="<wbId>"
  sql='SELECT "<dim-col-id>", ROUND("<measure-col-id>"::numeric, 2) FROM "workbook"."<element-id>" ORDER BY 1'
```

Run the queries in parallel — they're independent reads, no session contention.

> **A chart element's SQL view exposes only that chart's own columns** — not the master table's. A `WHERE "m-order-date-key" BETWEEN ...` against `el-rev-by-region` fails with `Unresolved column: m-order-date-key` because that column doesn't exist on the chart's aggregated projection. Two ways to handle this:
> - **Query the master table directly** (`FROM "workbook"."master"`) when you need to filter on a column the chart doesn't expose — then aggregate in SQL to compare to the chart's rendered values.
> - **Skip the filter and compare what the chart shows.** Workbook control filters are applied at view time, not at API-query time, so a `type="workbook"` SQL query against a chart element always returns the full unfiltered dataset. If the Tableau CSV is from a filtered dashboard view, you'll need to apply the same predicate against the master table to match.

### 6b. Compare to Tableau CSVs

Every row from the Sigma query must match a row in the corresponding Tableau view CSV
(modulo float-precision rounding). If anything diverges:
- **Numbers wrong by a constant factor** → check aggregation (Sum vs Avg vs CountDistinct).
- **Wrong dimension values** → check the `[Master/...]` formula references the right column.
- **Date axis has 24 buckets where Tableau shows 12** → see `refs/column-gotchas.md` "Cross-year month rollup".
- **Empty result / column resolves as `error`** → run `mcp__sigma-mcp-v2__describe` on the element; column type `error` means the formula failed to compile (often `IsIn`, an unsupported window function, or a missing-column ref).

### 6c. Trust the CSV, not the dashboard caption

A Tableau dashboard's chart title is hardcoded text on the dashboard, not derived from
the underlying view. When a Tableau author replaces a chart's data without updating the
title, the caption lies. **The view's `get-view-data` CSV is the source of truth** —
build the Sigma chart against the CSV's actual columns and pick a truthful Sigma name,
even if it disagrees with what's printed above the bars in Tableau.

### 6d. Phantom `--metric-["..."]` columns in workbook query results

`mcp__sigma-mcp-v2__query` with `type="workbook"` appends synthetic columns to every
result row of the form `--metric-["<colId>"]` whose values look like
`Column "X.--metric-[...]" does not exist.`. These are harmless artifacts of the
metric-projection layer — your explicitly-SELECTed columns return correct values
alongside them. Don't mistake the noise for a real query failure.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Expecting UUID at 0.folderId but instead got: undefined` | `folderId` missing from data model or workbook spec | Find your folder ID with `GET /v2/files?typeFilters=workbook` — use the `parentId` of any existing workbook |
| `Invalid kind: 'kpi'` | Used `"kind": "kpi"` — the correct kind is `"kpi-chart"` | Replace all `"kind": "kpi"` with `"kind": "kpi-chart"` in the spec |
| `Invalid kind: 'pie'` | Used `"kind": "pie"` — the official example library shows this but it's wrong | Replace with `"kind": "pie-chart"` |
| `Invalid kind: 'donut'` | Used `"kind": "donut"` — the official example library shows this but it's wrong | Replace with `"kind": "donut-chart"` |
| Element kind rejected, not sure what's valid | Unknown/guessed element kind | `GET /v2/workbooks/<existing-id>/spec` and read the `kind` fields of real elements — never guess |
| `dependency not found: formula reference 'orders/country region'` | Column named "Country/Region" has slash — unresolvable in formulas | Rename column to "Country" in the data model spec; re-POST |
| `dependency not found: formula reference 'orders/state province'` | Same slash issue with "State/Province" | Rename to "State" |
| All columns on a table fail together | One bad formula poisons the whole element | Find the specific failing ref in the error message; fix only that column |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML, not JSON | Parse with `ruby -r yaml -r json` instead |
| `401` on `get-view-image` after solo `get-view-data` succeeded | Rare transient failure | Retry `get-view-image` solo immediately — no concurrent requests |
| `401` on `get-view-image` despite `get-view-data` succeeding in same parallel batch | Session contention — concurrent requests compete for the same VizQL session | Retry the image solo with no other concurrent view requests |
| `401` on both `get-view-data` and `get-view-image` | View uses a data connection the API token can't reach | Skip this view; it's inaccessible via MCP regardless of technique |
| Batch `get-view-data` returns mostly 401s | Session contention from parallel requests — not a cache issue | Switch to solo warm → solo image, one view at a time |
| `429` on Tableau view image | Rate limited | Wait and retry the specific view |
| Column fetch returns empty list | Response key is `entries`, not `columns` | Use `.get('entries', [])` when parsing column API responses |
| PUT returns `invalid_request` with no field named | Read-only metadata fields included in PUT body | Strip `workbookId`, `url`, `ownerId`, `createdBy`, `updatedBy`, `createdAt`, `updatedAt`, `latestDocumentVersion` from the PUT body |
| PUT returns `Invalid 1: schemaVersion, got undefined` | `schemaVersion` was stripped from PUT body | Keep `schemaVersion` in the PUT body — it is required |
| Layout PUT rejected, some elements not visible | `elementId=""` in layout XML from nil Ruby variable | Guard fallback element lookups: use `(le(id, ...) if id)` and `.compact` |
| Layout has elements stacked vertically | No layout XML provided, or layout uses wrong IDs | GET spec after POST to get real IDs; rebuild layout with Ruby |
| KPI names invisible or truncated inside container | Inner `gridRow` too small — `gridTemplateRows="auto"` does NOT expand to fill container height | Set inner KPI `gridRow` end value = container outer end value (e.g., container `1 / 9` → KPIs `1 / 9`) |
| Empty containers visible on page | Container elements in spec but not referenced as `<GridContainer>` in layout XML | Add them to layout as `<GridContainer>` wrapping their child KPIs |
| Wrong endpoint — workbook created instead of data model | Called `/v2/workbooks` instead of `/v2/dataModels/spec` | Delete the workbook; re-POST to the correct endpoint |
| Bar chart renders vertical but Tableau shows horizontal bars | Bar chart orientation is UI-only — `"orientation": "horizontal"` is silently accepted and dropped | Set it manually post-publish: chart editor → Properties → Chart type → Horizontal icon |
| Sigma chart shows dimension values that Tableau's view never displays (e.g. extra quarters, extra regions, dates outside Tableau's range) | Tableau view has a worksheet/dashboard filter you didn't translate — the MCP does not expose filters explicitly, so they're invisible unless you compare CSV ranges to warehouse ranges | Phase 2.5 — diff distinct values / date min-max from view CSV vs the warehouse; add the missing filter as a `date-range`/`list`/`top-n` control or element-level filter |
| Axis label rotation not applied | Axis rotation is UI-only — not stored in or returned by spec API | Set it manually post-publish: chart editor → Format → X-axis → Label rotation |
| Dashboard title appears left-aligned despite Tableau showing it centered | Text element alignment is UI-only — `text` element spec only persists `id`/`kind`/`body` | Set in element editor → Format → Alignment after publish |
| `mcp__sigma-mcp-v2__query` with `type: "workbook"` returns "Table X not found" | Workbook queries don't resolve element names (e.g., `"Master"`) as table refs | Use `type: "connection"` with the raw table inodeId for data validation queries |
| Workbook query result rows include `--metric-["..."]` columns whose values say `Column "X.--metric-[...]" does not exist.` | Synthetic metric-projection columns appended by the query engine on `type="workbook"` queries — harmless | Ignore them; your explicitly-SELECTed columns return correct values alongside the noise |
| Integer date key column renders as number axis on line chart | `ORDER_DATE_KEY` is stored as an integer (YYYYMMDD); Sigma treats it as a number | Cast in the workbook column: `Date(Left(Text([Master/ORDER_DATE_KEY]), 4) & "-" & Mid(Text([Master/ORDER_DATE_KEY]), 5, 2) & "-" & Right(Text([Master/ORDER_DATE_KEY]), 2))` — `DateParse()` and `ToText()` do not exist in Sigma |
| Sigma line chart shows 24 month-year buckets where Tableau shows 12 month names | Tableau MONTH part collapses across years; Sigma `DateTrunc("month", ...)` preserves year | See `refs/column-gotchas.md` "Cross-year month rollup" — synthesize a single-year date in the formula |
