# SSRS → Sigma — converter design notes

Design sketch for a future `ssrs-to-sigma` skill, parallel to the existing
`tableau-to-sigma` and `cognos-to-sigma` converters. Customer requirement
that drove this scoping: the SSRS report server sits inside the customer's
firewall, so we can't reach it from the outside.

> Status: research / design only. No code yet. Last touched 2026-05-28.

---

## Phase 1 input format — RDL XML files

SSRS reports are authored as **RDL** (Report Definition Language) — a public
XML schema (`http://schemas.microsoft.com/sqlserver/reporting/...`). Every
report on a report server has a canonical `.rdl` file that defines:

- Data sources (connection strings to SQL Server / Oracle / etc.)
- Datasets (raw SQL queries OR stored proc references + parameter bindings)
- Parameters (with default values, allowed-values queries, multi-select)
- Tablix elements — a single shape that renders as table, matrix (pivot), or list
- Charts (column / bar / line / pie / scatter / area / range / gauge / funnel)
- Filters and groupings
- Subreports (a tile that embeds another report by path)
- Expressions in a VB-like syntax (`=Fields!Name.Value`, `=Sum(Fields!Sales.Value, "DS1")`, IIf/Switch/Iif)
- Report layout (Body, PageHeader, PageFooter, Tablix coordinates)

**RDLC** is the local/client variant — same XML, no DataSources block (data
bound at runtime). Treat identically once we have the structure.

Like BOBJ RWS ([[reference_sap_bobj_rws]]) and Tableau `.twb`, the RDL XML
is file-based and the realistic Phase 1 input.

---

## Firewall constraint — customer-runnable export CLI

Because the report server sits behind a firewall, the converter cannot call
SSRS REST itself. The pattern that works:

1. Ship a **small CLI the customer runs inside their network** (Python or
   .NET — .NET is friendlier because every SSRS-hosting org already has the
   runtime). It either:
   - Walks the SSRS REST API at `/reports/api/v2.0/CatalogItems` /
     `/CatalogItemsByPath` (SSRS 2017+, Power BI Report Server) and
     downloads `Content` for every report, OR
   - Queries the `ReportServer` catalog DB directly (older SSRS) for the
     `Catalog.Content` BLOB column — XML stored as `varbinary(max)`.
2. The CLI emits a zip:
   ```
   ssrs-export-<ts>/
     catalog.json              # path, name, modifiedDate, owner per report
     reports/
       <folder>/<name>.rdl     # raw XML, preserved folder structure
     datasources/
       <name>.rds              # shared data sources (extracted from catalog)
     metadata.json             # server version, total reports, sizes
   ```
3. Customer hands the zip to us. From that point everything is offline.

The CLI is the deliverable equivalent of `tableau-discover.rb`'s PAT mode —
short, single-purpose, easy to audit before running inside a corporate net.

> **Alternative for non-server SSRS**: SSDT/Visual Studio projects ship as a
> `.rptproj` folder with .rdl files directly on disk. Customer just zips
> the project folder. Same downstream pipeline.

---

## Translation surface

| SSRS concept | Sigma equivalent | Difficulty |
|---|---|---|
| Data source (`<DataSource>` connection string) | Sigma connection ID + warehouse-table source | medium — connection string → connection lookup is manual |
| Dataset (raw SQL) | Custom SQL data-model element (`kind: "sql"`) | clean 1:1 ([[feedback_sigma_formula_rules]]) |
| Dataset (stored proc) | Custom SQL wrapping `EXEC sp_xxx` (Snowflake/BigQuery need rewrite) | hard — stored procs rarely portable |
| Parameter (single value, default) | `control` of `controlType: list` / `number` / `date-range` | clean 1:1 |
| Parameter (multi-select with `AvailableValues` query) | `control` of `list` with `source: {kind: source, ...}` | clean 1:1 |
| Tablix as **table** (no Column groups) | Sigma `table` element | clean 1:1 |
| Tablix as **matrix** (Row + Column groups) | Sigma `pivot-table` with `rowsBy` / `columnsBy` / `values` | clean 1:1 ([[feedback_sigma_pivot_rowsby_columnsby]]) — same target we just landed for Tableau crosstabs |
| Tablix as **list** (banded layout) | Sigma `table` with grouping OR a chart, case-by-case | medium — banded layouts often need redesign |
| Chart (column/bar/line/pie/scatter/area) | matching Sigma chart kind | clean 1:1 |
| Chart (gauge / funnel / radar / polar / range) | Sigma substitution: KPI for gauge, bar for funnel; radar/polar = redesign | hard |
| Subreport | New Sigma page sourced from same DM OR drillthrough link | medium — multi-pass conversion |
| Drillthrough action (`Action` element) | Sigma drill action / control bind | medium |
| Page header / footer | Sigma `text` elements at top/bottom | partial — pagination concept doesn't exist in Sigma |
| Conditional formatting (BackgroundColor expression) | `conditionalFormats[]` | medium — expression translation |
| Expression — `=Fields!X.Value` | `[Master/X]` | clean 1:1 |
| Expression — `=Sum(Fields!X.Value, "Dataset1")` | `Sum([Master/X])` (scope dropped, may need element-level filter) | medium |
| Expression — `=IIf(cond, t, f)` | `If(cond, t, f)` | clean 1:1 |
| Expression — `=Switch(c1,v1, c2,v2, ...)` | `Switch(c1,v1, c2,v2, ...)` | clean 1:1 |
| Expression — `=Code.MyFunction(...)` (custom VB) | manual escalation | hard — VB code blocks |
| Expression — `=RunningValue(Fields!X.Value, Sum, "Dataset1")` | Custom SQL window OR manual | hard ([[feedback_sigma_window_functions]]) |
| Lookup / LookupSet / MultiLookup | `Lookup(...)` formula on master | clean 1:1 |
| Aggregate scopes (`"Dataset1"`, group names) | implicit in Sigma master/grouping; mostly drops cleanly | medium |
| Visibility expression (`<Hidden>=`) | Sigma element-level filters OR conditional show | partial |

---

## Phases (mirrors `tableau-to-sigma`)

1. **Phase 0** — Customer runs the export CLI inside the firewall; sends zip.
2. **Phase 0a** — Gap scan across all RDLs in the zip; emit a report
   categorizing every report as Auto / Hint / Manual / Unhandled (like
   `scan-workbook-gaps.rb`).
3. **Phase 1** — Per RDL: parse XML → datasource, dataset SQL, parameter,
   tablix/chart inventory, calc-field equivalents.
4. **Phase 1.5** — DM reuse check against existing Sigma DMs (warehouse FQN
   + column-overlap scoring, same as Tableau).
5. **Phase 2** — Warehouse column discovery for any new DMs.
6. **Phase 3** — Build Sigma DM spec (warehouse-table for plain datasets,
   `kind: sql` Custom SQL for raw-query datasets — most RDL datasets ARE
   raw SQL, so Custom SQL is the majority).
7. **Phase 4** — POST DM.
8. **Phase 5** — Build workbook spec — page per report (or per logical
   group), elements per tablix/chart, controls per parameter, layout based
   on tablix coordinates.
9. **Phase 6** — Parity verification — render the Tableau-style row-level
   comparison against the source RDL's preview (SSRS REST `Reports/{id}`
   render endpoint exposes CSV/XML/JSON output that can serve as the
   expected baseline IF the customer can run the report inside the firewall
   and include the render output in the export zip).

---

## Hard problems / known gaps

- **Stored proc datasets** — `EXEC sp_xxx @p=1` doesn't run in Sigma's
  warehouse dialects directly. Either rewrite the proc inline as Custom
  SQL (only feasible when the proc is small and the customer hands over
  the body) or escalate.
- **Pixel-perfect paginated layouts** — page headers/footers, page breaks,
  embedded subreports with banded detail rows. These don't fit Sigma's
  grid-based dashboard model. The assessment phase should flag and quote
  these as "redesign" rather than "convert."
- **Code blocks** — RDL allows `<Code>...VB.NET...</Code>` blocks
  referenced by `=Code.Foo(...)` in expressions. No analog in Sigma; needs
  per-block manual translation.
- **Multi-value parameter joins** — `=Join(Parameters!X.Value, ",")`
  passed into a dataset SQL needs to become a Sigma `list` control where
  the chart uses Sigma's `[control].value` reference.
- **Mixed-grain tablix** — a Tablix can have both Row and Column groups
  AND a detail band; this is a hybrid table+pivot that needs hand-
  decomposition into either a Sigma pivot OR a grouped table, not both.

---

## MVP scope

- File-based RDL XML input (skip the firewall CLI for v0 — assume customer
  has already exported)
- Phase 1 + Phase 5 covering tablix (table + matrix), basic chart kinds,
  parameters, raw-SQL datasets
- Defer: subreports, drillthrough, custom VB code, gauge/funnel/radar
- Reuse from tableau-to-sigma:
  - DM picker / inspect-dm-shape (Phase 1.5)
  - Post-and-readback workflow
  - verify-workbook + Phase 6 parity scaffolding
  - layout helpers (Ruby `lib/layout.rb`)
  - Gap-scout subagent pattern

---

## Open questions

- Is there a customer corpus we can build against? (we'd need ~5 real-
  world RDLs of varying complexity to calibrate the gap scanner)
- Does the firewall CLI need to be .NET (every SSRS host has it) or
  Python (more portable but customer needs to install)? Probably .NET.
- For parity (Phase 6), can we reliably get the customer to include
  rendered CSV from `?rs:Format=CSV` for each report in the export zip?
  Without that we can't verify data parity — only structural/spec
  compilation.
