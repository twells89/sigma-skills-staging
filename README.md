# Sigma AI Coding-Agent Skills — Staging

Private staging counterpart to [`twells89/sigma-skills`](https://github.com/twells89/sigma-skills). Skills and research living here are **not yet ready to graduate** to the main repo. Expect rough edges, missing docs, and breaking changes between commits.

Like the graduated repo, the staging skills support multiple AI coding agents: Claude Code & Cortex Code read `SKILL.md` directly; Codex / Cursor / Cline / Continue.dev get pre-built files in each skill's `generated/` directory. See the graduated repo's [README](https://github.com/twells89/sigma-skills/blob/main/README.md#installation) for the install helper.

When a skill stabilizes and proves itself across multiple real conversions, it moves to `sigma-skills` (history preserved via `git filter-repo`).

## What's here

| Folder | Status | Purpose |
|--------|--------|---------|
| [`tableau-to-sigma`](tableau-to-sigma/) | Active iteration | Convert a Tableau datasource or workbook into a Sigma data model + matching dashboard. Phases 1–5 (discovery → DM creation → workbook layout → repointing). Defers to the graduated `sigma-workbooks` skill for canonical workbook spec shape. |
| [`tableau-vds-to-snowflake`](tableau-vds-to-snowflake/) | Early | Convert a Tableau `.tds` / VDS source into a Snowflake-compatible data model definition. |
| [`research/`](research/) | Spike writeups | Output from scheduled remote-agent research spikes. Currently: Looker dashboard layout, PowerBI visual layout, DAX-to-Sigma formula coverage. Not skills — read-only reference material informing future converter work. |

## Relationship to `sigma-skills`

The graduated repo holds the building blocks (`sigma-data-models`, `sigma-workbooks`) and proven orchestrators (`custom-sql-to-data-model`). This staging repo holds in-progress orchestrators and research that depends on those building blocks.

If a staging skill needs a building block, install **both** repos locally — staging skills assume their dependencies are already loaded from the graduated repo.

## Installation

### Claude Code & Cortex Code

```bash
git clone https://github.com/twells89/sigma-skills-staging.git ~/sigma-skills-staging
mkdir -p ~/.claude/skills
for d in ~/sigma-skills-staging/*/; do
  name=$(basename "$d")
  [ "$name" = "research" ] && continue   # research isn't a skill
  ln -sf "$d" ~/.claude/skills/"$name"
done
```

### Codex / Cursor / Cline / Continue

Use the helper from the graduated repo — it resolves staging skills automatically:

```bash
~/sigma-skills/scripts/install-into-project.sh tableau-to-sigma codex ~/work/myproject
~/sigma-skills/scripts/install-into-project.sh tableau-to-sigma all  ~/work/myproject
```

## Auth

Same as `sigma-skills`. Skills assume `SIGMA_API_TOKEN` and `SIGMA_BASE_URL` are populated:

```bash
source ~/.sigma-env
eval "$(~/sigma-skills-staging/tableau-to-sigma/scripts/get-token.sh)"
```

Required env vars: `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET`.

## Graduation criteria

A staging skill moves to `sigma-skills` when it has:

- Run cleanly against ≥3 distinct real customer/internal sources without manual intervention
- Documented Phases (or workflow) in `SKILL.md` with a Troubleshooting section
- Helper scripts that handle the standard error cases (auth refresh, rate limits, schema-mismatch fallbacks)
- No outstanding Beads issues marked as blockers for promotion

Promotion is a `git filter-repo` move from this repo to `sigma-skills` (preserves history). The folder is then removed from staging.
