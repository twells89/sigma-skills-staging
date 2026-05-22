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
| `scripts/scan-workbook-gaps.rb` | **Phase 0a (mandatory):** scan a `.twb` and emit `gaps-report.md` + `gaps.json` categorising every feature into ✅ auto / ⚠️ hint / 🛠 manual / ❌ unhandled. Run BEFORE any other phase. |
| `scripts/gap-scout.md` | **Phase 0a-scout:** subagent prompt + protocol for resolving ❌ Unhandled gaps. Main agent spawns one scout per gap via the Agent tool. |
| `scripts/validate-sigma-formula.rb` | Scout primitive: POST a tiny test workbook with a candidate formula, read back column types, return JSON `{ status: ok|error }`. Auto-expands the DM element's columns onto the test master so candidate refs to real data resolve. |
| `scripts/scout-validate-and-persist.rb` | Scout wrapper: call validate-sigma-formula, on success append the rule to `~/.tableau-to-sigma/learned-rules.yaml` (customer's HOME, never the skill repo), on failure write `~/.tableau-to-sigma/escalations/<ts>-<slug>.yaml` AND auto-file a GitHub or beads issue. |
| `scripts/learned-rules.rb` | Loader module: reads `~/.tableau-to-sigma/learned-rules.yaml` at startup. Customer-discovered rules apply BEFORE the built-in translators in `build-charts-from-signals.rb`. |
| `scripts/parse-twb-layout.rb` | Parse a `.twb` XML file into a per-dashboard zone list plus a sister `*-meta.json` (worksheets + shared_filters + parameters + column_aliases). Per chart zone surfaces: position (`x/y/w/h%`), `chart_kind`, `mark_class`, `geo_role`, `sort`, `filters` (with resolved column captions + member values + action-vs-value flag), `aggregations`, `channels`, `formats` (Tableau format strings → Sigma d3-format with paren-negative handling), `calculations`, `dual_axis` (synchronized-axes detection), `ref_marks` (reference lines/bands/trendlines), `filter_column_caption`. |
| `scripts/build-charts-from-signals.rb` | Generate Sigma chart-element specs from parse-twb-layout output + view CSVs + master-column map. Auto-translates: column aliases → `Switch(…)` calc, parameter-driven CASE/IF chains → `Switch([ctl-param-x], …)` with controlId rewrite per page, table calcs (INDEX/LOOKUP/TOTAL/RANK/ZN/IIF/COUNTD) → Sigma equivalents, Tableau formats (p%.%/C1033%/`(neg)`) → Sigma d3-format. Honors `--page-per-worksheet`, `--auto-controls`. Loads customer learned-rules first. Writes `*-actions.md` companion listing Tableau action filters for post-publish cross-filter setup. |
| `scripts/extract-custom-sql.rb` | Phase 1f: pull Custom SQL blocks behind a workbook via Metadata GraphQL + .twb XML fallback. Output → `/tmp/<name>/custom-sql.json`. |
| `scripts/lib/tableau_rest.rb` | Ruby wrapper for the Tableau REST endpoints the skill uses |
| `scripts/estimate-cost.rb` | Predict input/output token cost from workbook + datasource metadata |
| `scripts/fetch-view-data.rb` | Parse pre-fetched view CSVs into a signals manifest (distinct values, date min/max, agg hints) |
| `scripts/discover-warehouse-columns.rb` | Parallel-fetch Sigma column metadata for N table inodeIds |
| `scripts/extract-calc-fields.rb` | Pull every Tableau CALCULATION field (with formula) + translation notes |
| `scripts/validate-spec.rb` | DM or workbook spec validator. Accepts `--type` and `--dm-context` |
| `scripts/post-and-readback.rb` | POST a DM or workbook spec, parse YAML response, GET back the spec, emit element ID map. Also runs a universal **column-type guard** afterward: any column whose formula resolved to type `error` aborts the script with exit 2 and the failing formula. Catches silent-error columns the validator doesn't pattern-match (typo refs, `IsIn`, unsupported functions) without waiting for Phase 6. |
| `scripts/put-layout.rb` | Apply a layout XML to an existing workbook (strips read-only fields) |
| `scripts/auto-parity-plan.rb` | Phase 6a: auto-build a parity plan by matching Sigma chart elements to Tableau view CSVs (with `--rename` for renamed tiles). Output → `/tmp/<name>/parity-plan.json` wrapped as `{ extract, charts: [...] }` |
| `scripts/verify-parity.rb` | Phase 6c: diff expected (Tableau) vs actual (Sigma) per chart. `--extract-mode` switches to structural comparison (bucket count + dim set + sort) with value-drift tolerance for hasExtracts=true workbooks |
| `scripts/export-chart-png.rb` | Phase 6d (visual): export PNG screenshots of every chart in the converted Sigma workbook via `/v2/workbooks/{wb}/export` → `/v2/query/{q}/download`. Catches visual regressions CSV value parity can miss (silently-dropped log scale, missing data labels, wrong chart kind, palette drift). Output: per-element PNGs + `_manifest.json`. Pair with the Tableau MCP `get-view-image` to side-by-side compare source vs target. |
| `scripts/find-or-pick-dm.rb` | Phase 1.5: scan existing DMs in the org and recommend reuse when one already covers the workbook's columns. Score = 0.7·column-overlap + 0.2·table-overlap + 0.1·metric-overlap. Parallel-fetches DM specs (~2s for 50 DMs). Output: `dm-match.json` with ranked candidates + recommendation. Non-destructive. Reuse skips Phase 2 + 3 entirely. |
| `scripts/scan-customer-style.rb` | Phase 0c: sample N recent workbooks in the customer's Sigma org and aggregate style signals (color palettes, number-format strings, layout grids, chart-kind mix, dataLabel preference, element naming case, density). Lets the converter emit specs that match house conventions instead of generic defaults. |
| `scripts/phase-timer.sh` | Source helper for phase timing. `phase_start "<name>"` / `phase_end` around each phase; `phase_report` at the end flushes a JSON summary to `$PHASE_TIMINGS_OUT`. Use to profile real conversions and find the slow phases. |
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

> **Inline Python inside bash — DON'T.** Triple-nested escapes (`f"...{e.get(\\\"name\\\")}..."` inside `python3 -c "..."` inside `bash -c '...'`) silently break. Instead **always write a `.py` file with `Write` and call it via `python3 file.py`.** Same rule for any inline script over ~5 lines: write it to disk, then exec. It's not slower, it's deterministic, and the file becomes a reusable artifact. (Same applies to Ruby — prefer `ruby file.rb` over `ruby -e '...'`.)

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
  --workbook-id <luid> \
  --out /tmp/<name>
```

Produces the same artifacts as MCP-driven Phase 1 in a single run: `get-workbook.json`,
`workbook-content.twb`, `ds-metadata.json` + `graphql-fields.json` (VDS field list + GraphQL
formulas), `views/*.csv` (fetched concurrently), and the dashboard PNG. Downstream scripts
in Phases 2–6 are unchanged. Full endpoint inventory and gotchas in `refs/tableau-rest.md`.

`--datasource-name` / `--datasource-luid` are **optional** — the script parses the
downloaded `.twb` for the first non-Parameters `<datasource caption='X'>` and looks it up
on the site automatically. Pass `--no-auto-ds` to disable, or `--datasource-luid` to force
a specific datasource when the workbook has multiple.

View CSV fetches run in parallel (6 concurrent threads). The dashboard PNG is fetched solo
afterward to avoid VizQL session contention.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 consecutive failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.

---

## Phase 0a — Scan the workbook for feature gaps (MANDATORY)

Run the gap scanner against the customer's `.twb` *before* anything else. It
inventories every workbook feature the skill currently handles vs. doesn't, so
the agent can plan around real translation gaps instead of discovering them
mid-conversion.

```bash
ruby scripts/scan-workbook-gaps.rb /tmp/<name>/workbook-content.twb
# writes <name>-workbook-content-gaps-report.md + <name>-workbook-content-gaps.json
```

Categories emitted:
- **✅ Auto** — translated end-to-end without intervention
- **⚠️ Hint** — agent gets a copy-paste-ready Sigma formula in WARN lines
- **🛠 Manual** — customer wires up post-publish (action filters, ref-marks)
- **❌ Unhandled** — feature is used in the .twb but the skill does not yet
  cover it; the agent should escalate via the `gap-scout` subagent OR file
  an issue at github.com/twells89/sigma-skills-staging

Share the markdown report with the customer up front to set expectations.
Save the JSON for the subagent.

### Phase 0a-scout — spawn the gap-scout subagent for unhandled features

> **MANDATORY, parallelizable.** As soon as the gap scanner produces `gaps.json`,
> read the `detected_features` array and **spawn one `gap-scout` Agent per row
> whose `status` is `unhandled`** (and optionally for high-volume `hint` rows).
> Use `run_in_background: true` so the scout runs in parallel with the rest of
> conversion — by the time you reach Phase 5, the scout has either persisted a
> rule or escalated. Don't read the gap report and proceed without doing this.

For every `❌ Unhandled` row in the gap report (and for high-volume `⚠️ Hint`
rows worth automating), spawn a `gap-scout` subagent via the Agent tool. Each
scout takes ONE gap, proposes a Sigma translation, validates against the
customer's Sigma site via `scripts/validate-sigma-formula.rb`, and:
- on success → writes the rule to `~/.tableau-to-sigma/learned-rules.yaml`
  (the customer's home dir — `git pull` of the skill cannot clobber it).
  All future workbook conversions on this machine pick up the rule via
  `scripts/learned-rules.rb` automatically.
- on failure → writes to `~/.tableau-to-sigma/escalations/` and (Phase 4)
  files a GitHub issue via `gh`.

The build script (`build-charts-from-signals.rb`) loads learned rules at
startup; matching rules apply *before* the built-in translators, so customer-
discovered translations override defaults. See `scripts/gap-scout.md` for the
full subagent prompt + procedure.

Customer-local files always live under `~/.tableau-to-sigma/`:
- `learned-rules.yaml`   — accumulated translation rules
- `escalations/*.yaml`   — gaps the scout couldn't solve
- (override path for testing with `TABLEAU_TO_SIGMA_HOME` env var)

### Phase 0b — Pick the conversion mode (MANDATORY, ask the customer)

Before building anything, **ask the customer which mode they want**. There is
no good default — picking the wrong one wastes the whole conversion.

| Mode | When | Output |
|---|---|---|
| **Dashboard fidelity** (default for dashboard URLs like `/views/<WB>/<Dashboard>`) | Customer wants the source dashboard recreated 1:1 in Sigma | One Sigma page with all charts positioned in the same grid as Tableau; shared filters as page-level controls; layout XML mirrors the dashboard's zone tree |
| **Page-per-worksheet** (default for `/sheets/<Sheet>` URLs OR when the customer says "split it up") | Customer wants each worksheet adjustable independently, OR the dashboard is too dense to recreate cleanly | One Sigma page per Tableau worksheet; shared filters duplicated on each page |

When the customer's URL is a dashboard URL and they haven't explicitly said
"split into pages," the agent MUST ask: "Want me to recreate the dashboard
1:1 (all 6 tiles on one page) or break each worksheet into its own Sigma
page?" Don't assume.

For dashboard mode, `build-charts-from-signals.rb` is invoked WITHOUT
`--page-per-worksheet` — that emits the legacy flat-array output. Then a
separate layout script positions the chart elements in a grid matching the
Tableau dashboard's zone x/y/w/h percentages (parse-twb-layout already
extracts these).

For page-per-worksheet mode, pass `--page-per-worksheet`.

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

### 1a. Resolve the name the customer gave you

The customer's name may be a **datasource**, a **workbook**, or a **dashboard view inside a workbook**. Tableau Cloud's search and list endpoints partition by content type, so you have to try each before declaring no match.

```
# Workbook by name
mcp__tableau__search-content   terms="<name>"   filter.contentTypes=["workbook"]

# Dashboard view by name — falls back to workbook owner via the view's response
mcp__tableau__list-views       filter="name:eq:<name>"

# Datasource by name
mcp__tableau__search-content   terms="<name>"   filter.contentTypes=["datasource"]
mcp__tableau__list-datasources
```

If the workbook search returns nothing, **try `list-views` next** — the customer almost certainly named a dashboard sheet (e.g. "Orders Overview") that lives inside a differently-named workbook ("Orders Conversion Test"). The view response includes the parent workbook's LUID.

### 1b. Find workbooks sourced from a datasource

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

   > **This is the single biggest perf win in the whole conversion.** Measured 2026-05-22: 7 view-CSVs sequentially = ~200s (~28s per call, range 19–40s). Same 7 calls fired in one parallel batch = ~45s (bounded by the slowest single call). Skipping this parallelization is responsible for ~2.5 min of the historical ~9-min conversion runtime. From your conversation, send a single message with one `mcp__tableau__get-view-data` tool-call per view; do NOT send them in separate messages.
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

## Phase 1.5 — Check for an existing DM the workbook can reuse (DO THIS FIRST)

Before running Phase 2 (warehouse column discovery) and Phase 3 (DM build), check whether the customer's Sigma org **already has a data model** that satisfies the workbook's needs. Reusing an existing DM:

- Avoids DM sprawl (customers complain when they end up with a 4th "Orders" DM)
- Cuts Phase 2 + Phase 3 entirely on the reuse path — typically the heaviest 2–3 minutes of a conversion

```bash
# Inputs:
#   workbook-signature.json — derived from Phase 1 .twb parse + view CSV headers
#     { tableau_workbook, warehouse_tables: [FQNs], referenced_columns: [...], measures: [...] }
ruby scripts/find-or-pick-dm.rb \
  --workbook-signature /tmp/<name>/workbook-signature.json \
  --out /tmp/<name>/dm-match.json \
  --limit 100 \
  [--min-score 0.6]   # default; below: build new
  [--force-new]        # bypass scan entirely
```

The picker parallel-fetches DM specs (10 concurrent threads — ~2s for 50 DMs vs ~15s serial). Scoring weights: column overlap 0.7, source-table FQN 0.2, metric overlap 0.1. Output thresholds:

| Score | Action |
|---|---|
| ≥ 0.85 | auto-reuse the recommended DM, skip Phase 2 + 3 |
| 0.6 – 0.85 | ambiguous — **ask the user** before reusing; surface the candidates from `dm-match.json` |
| < 0.6 | no usable match; proceed to Phase 2 + 3 |

Surface this in your conversation with the user:

> "Found existing DM `<name>` covering N/M of the columns this workbook references. Reuse this DM? It would skip ~2–3 min of conversion time but the workbook will inherit X extra columns (sample: ...). Reply `yes` to reuse, `no` to build new, or `show` to see other candidates."

When reusing, jump straight from Phase 1.5 to Phase 5 — the workbook spec's table elements set `source: { kind: data-model, dataModelId: <recommended_dm_id>, elementId: <chosen-element-id> }` and use formula prefixes derived from the existing DM's element name (e.g. `[Plugs Sales/Revenue]`).

The picker is **non-destructive** — it never modifies any DM. The downstream phase decides reuse vs build.

---

## Phase 2 — Discover actual warehouse column names

> **This step is mandatory. Do not skip it or infer column names from Tableau.**
> **Skip Phase 2 entirely if Phase 1.5 recommended a DM you reused.**

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

> **Two sources, in order of authority:**
> 1. **`parse-twb-layout.rb`'s `*-meta.json`** — `shared_filters` (workbook-level filter shelf) and per-chart `zone.filters` (worksheet-level) carry resolved column captions, member-value lists, and an `is_action` flag distinguishing value filters from cross-chart action filters. `build-charts-from-signals.rb --auto-controls` translates list / relative-date / number-range shared filters into Sigma controls per page automatically.
> 2. **View CSV ↔ warehouse diff** (legacy fallback) — for `.twbx`-less workbooks or when the agent suspects the parser missed a filter, compare distinct values in the view CSV against the warehouse.

The diff method is still mandatory for any workbook where you don't have the `.twb` content. When you DO have it, trust the parser's filter output first — it carries member values that the CSV can't reveal.

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

### 5a-auto. Run build-charts-from-signals first

For most workbooks, `build-charts-from-signals.rb` produces a usable starting spec:

```bash
ruby scripts/build-charts-from-signals.rb \
  --tableau-dir /tmp/<name> \
  --layout /tmp/<name>/dashboard-layout.json \
  --meta /tmp/<name>/dashboard-layout-meta.json \
  --master-map /tmp/<name>/master-columns.json \
  --master-element-id master \
  --auto-controls --page-per-worksheet \
  --title "<Workbook Title>" \
  --out /tmp/<name>/chart-specs.json
```

What the build script auto-handles (no agent action needed):
- ✅ chart-kind from `mark` class (bar/line/area/pie/scatter/map)
- ✅ sort direction from `<sort>` (xAxis.sort emitted only when Tableau sorted)
- ✅ aggregator from `column-instance derivation` (Sum/Avg/CountD/Median)
- ✅ DateTrunc for `Month-Trunc`/`Year-Trunc` dimensions
- ✅ Tableau format strings → Sigma d3-format (incl. paren-negative)
- ✅ Column aliases → `Switch(...)` calc on the chart's dim column
- ✅ Shared-view filters → per-page Sigma controls (list/date-range/number-range)
- ✅ Parameters (list domain) → segmented controls
- ✅ Parameter-driven CASE/IF chains → `Switch([ctl-param-X], ...)` calc
- ✅ Table calcs INDEX/LOOKUP/TOTAL/RANK/ZN/IIF/COUNTD → Sigma equivalents
- ✅ Synchronized-axis worksheets → `combo-chart` kind w/ two yAxis groups
- ✅ Customer-discovered learned-rules from `~/.tableau-to-sigma/learned-rules.yaml`

What WARN lines mean — act on each one:
- `'X' parameter-driven calc … → translated to Switch: …` — already emitted, no action needed
- `'X' Tableau table-calc … → Sigma: ...` — copy-paste the formula into a master column if it's used by multiple charts
- `'X' learned-rule applied to … → Sigma: ...` — already emitted, no action needed
- `'X' has Tableau reference marks (...)` — manually add Sigma `referenceMarks` to the chart post-publish (see beads-sigma-7ak)
- `'X' has a color channel on …` — multi-series fan-out: agent emits one yAxis per category in the chart spec
- `'X' has N Tableau action filter(s) — skipped` — read `<out>-actions.md` and wire Sigma cross-element filtering manually
- `'X' detected as dual-axis` — auto-emitted as combo-chart; verify the right kind in the readback
- `parameter '...' is a numeric range — skipped auto-control` — add a number control by hand (blocked on beads-sigma-ebw)

### 5a. Write the workbook spec

> **`folderId` is required here too.**

#### The two-page rule — master always on a dedicated "Data" page

> **MANDATORY.** Every workbook spec MUST have at least two pages: one named `Data`
> containing the master table, and one or more *content* pages containing charts,
> controls, and text. Charts on content pages source the master via cross-page
> `"elementId": "master"` references. **Do not** place the master alongside charts
> on a content page — it shows up as a giant table on the dashboard, and users
> have to manually delete it post-publish.

Spec skeleton (two pages, master on `Data`, all charts on `Orders Overview`):

```json
{
  "name": "Orders Overview",
  "folderId": "<folder-id>",
  "schemaVersion": 1,
  "pages": [
    {
      "id": "page-data",
      "name": "Data",
      "elements": [
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
            { "id": "m-sales", "formula": "[Order Fact/Sales]", "name": "Sales" }
          ],
          "order": ["m-sales"]
        }
      ]
    },
    {
      "id": "page-overview",
      "name": "Orders Overview",
      "elements": [
        { "id": "txt-title", "kind": "text", "body": "# Orders Dashboard" },
        {
          "id": "el-kpi-sales",
          "kind": "kpi-chart",
          "source": { "kind": "table", "elementId": "master" },
          "columns": [{ "id": "k-sales", "formula": "Sum([Master/Sales])", "name": "Total Sales" }],
          "value": { "id": "k-sales" }
        }
      ]
    }
  ]
}
```

Rules:
- Master `kind` is `table`, `visibleAsSource: false`, sourced from the DM element.
- Master-column formulas use the DM element's `name` as prefix (`[Order Fact/Sales]`, not the element ID).
- Charts and controls source the master with `"elementId": "master"` regardless of which page they live on — cross-page references are fully supported.
- Chart-column formulas use the master table's `name` as prefix (`[Master/Sales]`).
- Layout XML must produce **one `<Page>` tag per page**, including a tiny full-width `<LayoutElement elementId="master" .../>` inside the Data page's `<Page>`.

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

### 5f. Compile-check every element (MANDATORY)

```bash
ruby scripts/verify-workbook.rb <workbookId>
```

POST is permissive — it accepts specs whose column formulas don't actually resolve at query time. Those failures surface as string literals in the compiled SQL (`'Unknown column "[X]"'` / `'Circular column reference to [X]'`), and the UI renders the element as empty. `post-and-readback.rb`'s column-type guard catches **some** of these (columns whose type resolves as `error`), but not all. `verify-workbook.rb` asks the server's compiler directly via `GET /v2/workbooks/{id}/elements/{eid}/query` and greps the markers — catches everything the spec-level validator misses. **Parallel-fetches all elements** (5 threads + 429 backoff) — ~1.3s for an 11-element workbook vs ~4s for the legacy `verify-workbook.sh`.

Exit codes:
- `0` — every queryable element compiles clean
- `1` — one or more elements have unresolved/circular formula references; fix the offending columns in the spec, re-PUT, re-verify
- `2` — setup error (missing env, bad workbook ID)

Control elements and other non-queryable kinds are correctly skipped.

This step is mandatory and must run before declaring the conversion done.

---

## Phase 6 — Verify chart data matches Tableau (MANDATORY)

> **A conversion is not complete until Phase 6 has run and either passed or been explicitly accepted with documented divergences.** PUT returning `success: true` only proves the spec parsed — it tells you nothing about whether each chart shows the right numbers. Two recent customer-visible bugs both reached the customer because Phase 6 was skipped: a window-function calc compiling silently as `error` and a pie chart wired to the wrong dimension.

### 6 — one-step (preferred)

```bash
ruby scripts/phase6-parity.rb \
  --tableau /tmp/<name> \
  --workbook-id <sigma-workbook-id>
# add --extract-mode --extract-tol 0.30 when source workbook has a .hyper extract
```

This runs everything below as one command: builds the plan, fetches Sigma
actuals via the workbook elements API, runs the verifier, prints a
pass/fail summary, writes `/tmp/<name>/parity-final.json`. Exits non-zero
on divergence. Use this as the default — the per-step path below is for
debugging.

`scripts/post-and-readback.rb` now prints a "NEXT STEP — Phase 6" prompt
with the exact invocation at the end of every workbook POST, so the agent
sees the reminder right after the spec lands. Don't ignore it.

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

### 6f. Visual verification (PNG screenshots)

CSV value parity confirms the *data* matches. It does NOT catch visual regressions: a log-scale axis that silently fails to render, missing data labels, a stacked-vs-grouped bar mix-up, palette drift. For full conversion fidelity, also export PNGs of every chart in the Sigma workbook and side-by-side them with the Tableau source images.

```bash
ruby scripts/export-chart-png.rb \
  --workbook <workbookId> \
  --out-dir /tmp/<name>/screenshots/ \
  --width 1400 --height 700
```

Output: one PNG per chart-shaped element, plus a `_manifest.json` mapping element ID → file path, status, and bytes. Pair with the Tableau MCP `get-view-image` (or your own `.twb` view screenshots) for source-vs-target diffs.

The script uses Sigma's `POST /v2/workbooks/{wb}/export` (returns `queryId`) followed by `GET /v2/query/{q}/download` (PNG bytes, ~10–12s typical). All charts export in parallel; the script polls each queryId until ready. Element kinds covered: bar/line/area/combo/scatter/pie/donut, kpi-chart, region-map, point-map, pivot-table, table. Tooltip and other UI-only features (see [[feedback-sigma-trellis-ui-only]], [[feedback-sigma-tooltip-ui-only]]) won't appear in the export because they don't render through the spec API.

When to escalate to a visual check rather than just CSV parity:
- The Tableau source had log-scale axes, custom min/max, or non-trivial number formats (`-66l`)
- The chart had data labels turned on (`-cst`)
- The chart had reference lines/bands/trendlines (`-7ak`, `-2th`)
- The conversion uses dual-axis combo (`-d73`) — verify the right-hand series is line-shaped, not all bars
- Any time you're uncertain whether a feature round-tripped — visual diff is the highest-confidence final check

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
