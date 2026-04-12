# Translation Contributor Setup

This guide is for contributors who only want to work on localization for the VictoriaMetrics dashboard branch.

## Prerequisites

- Git
- Node.js 20 or newer
- a GitHub fork of `ha-puzzles/evcc-grafana-dashboards`
- a text editor that preserves JSON formatting

On Debian or Ubuntu, install Git and Node.js 20+ with:

```bash
sudo apt update
sudo apt install -y git ca-certificates curl
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
node --version
npm --version
```

No Grafana instance is required for editing translations. Grafana is only needed for visual import or screenshot validation.

## Repository Setup

Clone your fork into a dedicated working directory:

```bash
git clone https://github.com/<your-user>/evcc-grafana-dashboards.git evcc-grafana-translations
cd evcc-grafana-translations
```

Add the maintainer repository as `upstream`:

```bash
git remote add upstream https://github.com/ha-puzzles/evcc-grafana-dashboards.git
git fetch upstream
```

Create a translation branch from the maintainer's VictoriaMetrics branch:

```bash
git switch -c vm-translations upstream/victoria-metrics
git push -u origin vm-translations
```

If the branch already exists in your fork, use:

```bash
git fetch origin
git switch vm-translations
git pull --ff-only
```

## Directory Roles

- `dashboards/src/en`: maintainer-owned English source dashboards
- `dashboards/localization/en_to_<language>.json`: human or AI maintained translation mappings
- `dashboards/localization/missing-en_to_<language>.exact.json`: audit reports with open mapping candidates
- `dashboards/translations/<language>`: generated dashboard output
- `scripts/localization`: helper scripts for pruning, rendering, and auditing localization state

Do not edit files under `dashboards/translations/` manually. They are generated output.

## Translation-Only Workflow

Use this flow when the English source dashboards already look correct and you only want to improve target-language translations.

1. Check the current state:

```bash
git status
node scripts/localization/audit-localization.mjs --family=vm
```

2. Edit the relevant mapping file, for example:

```text
dashboards/localization/en_to_de.json
dashboards/localization/en_to_fr.json
```

3. Translate values in the `exact` section. The scripts do not translate text automatically; the final wording must be supplied by a human translator or with AI assistance.

4. Regenerate and audit:

```bash
node scripts/localization/generate-localized-dashboards.mjs --family=vm
node scripts/localization/apply-safe-display-translations.mjs --family=vm
node scripts/localization/audit-localization.mjs --family=vm
```

5. Review the diff:

```bash
git diff --stat
git diff -- dashboards/localization dashboards/translations
```

A normal translation update usually changes one or more `en_to_<language>.json` files, generated dashboards under `dashboards/translations/`, and refreshed `missing-*.exact.json` reports.

## Accepting New Missing Candidates

When source dashboards add new text, the audit writes candidates to `missing-en_to_<language>.exact.json`.

Preview what would be copied into mapping files:

```bash
node scripts/localization/adopt-missing-into-mappings.mjs --family=vm --target=all
```

Write placeholder mappings only when that is intentional:

```bash
node scripts/localization/adopt-missing-into-mappings.mjs --family=vm --target=all --write
```

This copies candidates as `source -> source`. It is not a translation step. Replace those placeholder values with real target-language text before expecting localized output.

## Source-Only Corrections

Use this flow when the English source dashboard itself contains wrong or mixed-language text.

Edit only files under:

```text
dashboards/src/en
```

For source-only corrections, do not regenerate `dashboards/translations/` unless you intentionally want to refresh generated outputs in the same change. A source-only pull request may contain only `dashboards/src/en/...` and possibly documentation.

After editing a source JSON file, validate it:

```bash
node -e "JSON.parse(require('fs').readFileSync('dashboards/src/en/EVCC_ Month.json', 'utf8')); console.log('JSON OK')"
git diff --check
```

## Pruning Stale Mapping Entries

Preview stale entries first:

```bash
node scripts/localization/prune-mappings-to-source.mjs --family=vm
```

Write the pruned mappings only when intended:

```bash
node scripts/localization/prune-mappings-to-source.mjs --family=vm --write
```

Pruning is useful after source dashboards have changed and mappings should be aligned to the current source text set.

## Pull Request Target

Open pull requests from your fork branch to:

```text
ha-puzzles/evcc-grafana-dashboards: victoria-metrics
```

Do not target `main` for VictoriaMetrics translation work unless the maintainer explicitly asks for it.

## Safety Rules

- Translate user-visible text only.
- Do not translate query internals, formulas, regexes, datasource UIDs, or `refId` values unless you are intentionally refactoring the source dashboard and have validated all references.
- Keep generated files out of source-only corrections.
- Keep translation pull requests focused: one source cleanup, one language update, or one workflow improvement at a time.
