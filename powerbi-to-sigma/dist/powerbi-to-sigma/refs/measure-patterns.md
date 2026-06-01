# DAX → Sigma measure-translation playbook

> A field-tested catalog of how Power BI DAX measures map to Sigma formulas,
> what restructuring each requires, and the traps that silently produce wrong
> numbers. Distilled from the KitchenSink / Employee-Dashboard migrations
> (validated 2026-05-31 against Power BI `executeQueries` DAX on workbook
> `c6b8abf8`). Pairs with `refs/vendored/dax-to-sigma-coverage.md`
> (the 94-expression coverage spike) — that doc buckets *coverage*; this doc is
> the *how-to* with verified recipes.

Quick map of which Sigma surface a measure lives in:

| DAX measure type | Sigma home | Why |
|---|---|---|
| Simple aggregate | chart/KPI value formula, or DM metric | scalar, context-free |
| Single-predicate `CALCULATE` | `SumIf` / `CountIf` / boolean-mask `Sum(If(...))` | predicate = mask |
| `% of total` (`ALL`) | `PercentOfTotal(agg, "grand_total")` | first-class function |
| `ALLEXCEPT` / grand-total-on-every-row | `GrandTotal(agg)` / `Subtotal(agg,"grand_total")` | repeats total per row |
| Time-intelligence YTD (`TOTALYTD`) | **grouped level table** + `CumulativeSum` | reset is grouping-driven |
| Prior-period (`SAMEPERIODLASTYEAR`/`DATEADD`) | `DateLookback(agg, [dateCol], n, "year"\|"day")` | direct analog |
| `RANKX` | `Rank()` inside a grouped element | window-in-grouping only |
| `RELATED` / `LOOKUPVALUE` | `[Base/REL/Field]` if related, else `Lookup(...)` | join-driven |
| `USERELATIONSHIP` (dynamic join swap) | no equivalent — materialize a parallel element | static joins |

---

## 1. The `color: {by, column}` series shape (line/bar split)

A chart splits into one series per category **iff** it carries a `color` block:

```json
"color": { "by": "category", "column": "<colId>" }
```

- This is *persisted* in the workbook spec (unlike trellis/tooltip, which are
  UI-only — see memory `feedback_sigma_trellis_ui_only` / `_tooltip_ui_only`).
- Removing the `color` block collapses the chart to a **single series**.
- **Line builder default = single series** (`beads-sigma-c07`): a line chart
  should NOT emit `color` unless the source PBI visual has a Legend/Series
  binding. Per-year, per-region etc. coloring is the exception, opted into
  explicitly — never the default.

### TRAP — `color` was also doing your grouping reset

When `color:{by:category,column:l-year}` is the *only* thing introducing the
Year dimension, removing it also removes the grouping that a `CumulativeSum`
relies on to reset (see §4). Fix the data (precomputed grouped column), not the
color split. Don't keep a 2-series chart just to get a per-year reset.

---

## 2. The cross-element-ref-returns-NULL trap (and workarounds)

When a DM/workbook measure references a column reached through a relationship,
the *form* of the reference matters and several forms silently yield NULL.

**The rule** (memory `feedback_sigma_cross_element_ref_form`): cross-element
refs use the **triple-segment** form `[BaseElement/REL_NAME/Field]`, never the
parenthesized friendly form `[Field (REL_NAME)]` — parens collide with
function-call syntax and the bracket parser never resolves them, leaving a
`type:error / Unknown name` column.

**The NULL trap specifically:** a measure like
`DIVIDE([Total Absence Hours],[Headcount])` where `[Headcount]` counts a column
in a *different* element. Three ways it goes wrong and the workarounds:

1. **Constant denominator** (cheapest, when the denominator is a known scalar):
   `Sum([ABS/Hours]) / 363`. Used for `p-perhead` in the KitchenSink. Exact, but
   hardcodes the headcount — re-derive if the population changes.
2. **DM metric that's UI-only-referenceable** (`beads-sigma-2tf`): define the
   ratio as a DM **metric** with a constant-key join to ALL employees, e.g.
   `Sum([Hours]) / CountDistinct([ABSENCE_RECORDS/Absence -> All Employees/Employee Id])`.
   The metric resolves correctly *in the workbook UI / via the metric() function*
   but is not freely composable as a plain column ref in every context — treat it
   as a metric, surface it via `metric('<id>', t)`, don't inline its body.
3. **Constant-key join element**: add a relationship from the fact to a
   single-row "all employees count" element so the denominator travels with every
   fact row. Heaviest, but fully dynamic.

Verify which one you got by `describe`-ing the element and `query`-ing — a NULL
column or a `type:error` in the DDL is the tell.

---

## 3. `ALLEXCEPT` / grand-total-on-every-row → `GrandTotal()`

PBI pattern: a measure that shows the *same* total on every row of a grouped
visual regardless of the row's grouping, e.g.

```DAX
Sick Hours := CALCULATE([Total Absence Hours], ALLEXCEPT(ABSENCE_RECORDS, ...))
              -- filtered to Sick, ignoring the row's Absence Type
```

PBI renders `14539.7` (grand-total sick) on **every** absence-type row.

A plain `SumIf([ABS/Hours], [ABS/Absence Type] = "Sick")` only shows the value
on the Sick row (NULL elsewhere) — because the SumIf still respects the row's
grouping. **Wrap it in `GrandTotal`** to lift it out of the row grouping:

```
GrandTotal(SumIf([ABS/Hours], [ABS/Absence Type] = "Sick"))
```

`GrandTotal(agg)` = `Subtotal(agg, "grand_total")`: it repeats the all-rows
aggregate on every row. This is the clean Sigma mirror of `ALLEXCEPT` /
`ALL`-context overrides. **Verified:** Personal/PTO/Sick all = 14539.7, matching
PBI exactly. Sigma docs: `sigma-computing/grandtotal`.

> For other grain overrides: `Subtotal(agg, "parent_grouping")` mirrors an
> `ALLEXCEPT` that keeps the *outer* grouping; `PercentOfTotal(agg, level)`
> covers the ratio forms (`grand_total` / `parent_grouping` / `row`).

---

## 4. Single-sawtooth YTD via a precomputed grouped column

PBI `TOTALYTD(SUM(...), 'Date'[Date])` is a continuous YTD that **drops back to
the January value at each year boundary** — one line, sawtooth shape. Target
(verified vs PBI): 2025 Jul→Dec `3536,7412,10932,14700,18080,21844`;
2026 Jan→May `3604,7124,9664,11084,12203.5`.

Sigma has no scalar YTD measure. `CumulativeSum` is the building block, but its
**reset is grouping-driven**: "when used in a grouped table the function is
applied to each grouping above the level of the cumulative sum independently"
(`sigma-computing/cumulativesum`). So the year reset only happens if **Year is a
grouping above Month**.

### The working recipe (verified)

1. **Precompute** in a hidden grouped "level table" (`visibleAsSource:false`),
   sourced from the fact master, with **two nested groupings**:
   ```json
   "groupings": [
     { "id": "ys-g-year",  "groupBy": ["ys-year"],  "calculations": [] },
     { "id": "ys-g-month", "groupBy": ["ys-month"], "calculations": ["ys-ytd"] }
   ]
   ```
   columns: `Year` = `Year([ABS/Date])`, `Month` = `DateTrunc("month",[ABS/Date])`,
   `ys-ytd` = `CumulativeSum(Sum([ABS/Hours]))`. The outer Year grouping makes
   CumulativeSum reset every January. Querying this element directly returns the
   exact sawtooth.

2. **Plot it as a SINGLE series.** Point the line chart at the level table,
   group by Month only, and aggregate the precomputed YTD with **`Max()`** (or
   `Avg`/`Min` — each month already has exactly one value):
   ```
   xAxis: month   yAxis: Max([YTDSRC/YTD Absence Hours])   (NO color block)
   ```

### TRAPS that bit us (so the next migration doesn't repeat them)

- **`Sum()` over a level table re-explodes it.** Wrapping the precomputed YTD in
  `Sum(...)` in the downstream chart re-scans the underlying ungrouped rows and
  returns ~1.8M-scale garbage. Use `Max()` (the per-month value is unique).
- **Internal `groupings` on the line element do NOT nest for the reset.** Adding
  `[Year outer, Month inner]` groupings directly on the *line chart* (instead of
  a separate level table) collapses to the xAxis (month-only) grouping —
  CumulativeSum then runs continuously and never resets (Jan 2026 came out 25448
  instead of 3604). The reset must be materialized in a *separate* grouped
  element first.
- **Don't fix the render by keeping `color:{by,column:year}`.** That gives the
  right numbers but renders two lines, not the one continuous sawtooth PBI shows.
- **X-axis: keep the column a true `datetime`, let the time axis sort natively,
  and match PBI's label granularity with the format string.** Bind
  `xAxis: { columnId }` with NO custom `sort` block — a datetime x renders a
  continuous, chronologically-ordered time axis by default; an added
  `xAxis.sort` block can fight that ordering. **The axis-label format is a
  separate decision from the data:** PBI's YTD line labels the axis with the
  **month only** (`Jul, Aug, … Dec, Jan, … May`) — the year boundary is conveyed
  by the sawtooth drop, not by a label. Sigma's default `%b %Y` shows "Jul 2025,
  …, Jan 2026" which reads as a divergence even though the data is identical. Set
  the month column's `format.formatString` to **`%b`** to mirror PBI. The
  underlying values stay distinct datetimes (2025-07 ≠ 2026-01), so chronological
  order and the 11 distinct points are preserved — only the tick *label* changes.
  Note: the MCP `query` tool returns raw datetimes and cannot show you the
  rendered label format or axis order — those are visual properties; confirm them
  in the rendered chart.

---

## 5. Mechanical one-to-one translations (no restructuring)

| DAX | Sigma | Notes |
|---|---|---|
| `SUM(T[A])` | `Sum([T/A])` | prefix differs, mechanical |
| `COUNTROWS(T)` | `Count([T/PK])` | pick a non-null PK; `Count` skips nulls |
| `COUNTROWS` of distinct | `CountDistinct([T/Key])` | |
| `CALCULATE(SUM(T[A]), T[R]="X")` | `SumIf([T/A], [T/R]="X")` | single-predicate; chain with `And` |
| `DIVIDE([Total], CALCULATE([Total], ALL(T)))` | `PercentOfTotal(Sum([T/A]), "grand_total")` | grouped/pivot/viz only |
| `SUMX(T, T[Q]*T[P])` | `Sum([T/Q]*[T/P])` | aggregates take row expressions; `AVERAGEX`→`Avg`, `MAXX`→`Max` |
| `RELATED(C[City])` | `[C/City]` (if related) else `Lookup([C/City],[T/Key],[C/Key])` | `Lookup` = `RELATED`/`LOOKUPVALUE` |

## 6. Translations needing a date-grouped consumer

| DAX | Sigma | Requires |
|---|---|---|
| `RANKX(ALL(P), [Total Sales])` | `Rank(Sum([T/A]), "desc")` | inside a grouped element; to reuse as a measure across visuals, materialize a per-key aggregate and `Lookup` it. `RankOver`/window-rank silently fails in DM-element calc cols. |
| `SAMEPERIODLASTYEAR` | `DateLookback(Sum([T/A]), [Month of Date], 1, "year")` | consuming element grouped on a date-trunc column |
| `DATEADD('Date'[Date], -30, DAY)` | `DateLookback(Sum([T/A]), [Day of Date], 30, "day")` | same shape as prior-period |
| `TOTALYTD` | grouped `CumulativeSum`, §4 | nested Year▸Month grouping + single-series plot |

## 7. No clean Sigma equivalent — flag for design decision

- **`USERELATIONSHIP`** (per-evaluation join swap): Sigma joins are static. Build
  a parallel relationship element (e.g. a ShipDate-based join) and aggregate
  against it — doubles model surface. The converter should refuse and emit a
  "needs data-model design decision" message rather than guess.

---

## Cross-links

- Sigma docs: [`GrandTotal`](https://help.sigmacomputing.com/sigma-computing/docs/grandtotal),
  [`CumulativeSum`](https://help.sigmacomputing.com/sigma-computing/docs/cumulativesum),
  [`PercentOfTotal`](https://help.sigmacomputing.com/sigma-computing/docs/percentoftotal),
  [pivot subtotals](https://help.sigmacomputing.com/sigma-computing/docs/pivot-table-subtotals).
- Skill refs: `dax-to-sigma-coverage.md` (coverage buckets), `spec-fixups.md`
  (DM/workbook post fixups), `connection.md` (Phase 1–2 extract).
- Memory: `feedback_sigma_cross_element_ref_form` (triple-segment refs),
  `feedback_sigma_window_functions` (window-fn silent failures in calc cols),
  `feedback_sigma_trellis_ui_only` / `_tooltip_ui_only` (UI-only fields —
  contrast with `color`, which IS persisted).
- Beads: `c07` (line default single series), `2tf` (UI-only-referenceable DM
  metric for the cross-element ratio), `tkd` (post fixups).
