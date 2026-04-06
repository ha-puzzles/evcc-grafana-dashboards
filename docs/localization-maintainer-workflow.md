# Localization Maintainer Workflow

This repository uses the maintainer-managed VictoriaMetrics dashboards under `dashboards/src/` as the source for localization work.

## Repository scope

- source of truth: `dashboards/src/en`
- generated translations: `dashboards/translations/<language>`
- mapping files: `dashboards/localization/en_to_<language>.json`
- missing-coverage reports: `dashboards/localization/missing-en_to_<language>.exact.json`

## Standard workflow

1. Update source dashboards only in `dashboards/src/en`.
2. Rebuild mapping files against the current source set:

```bash
node scripts/localization/prune-mappings-to-source.mjs --family=vm
```

3. Generate translated dashboards:

```bash
node scripts/localization/generate-localized-dashboards.mjs --family=vm
```

4. Apply the safe display-only pass:

```bash
node scripts/localization/apply-safe-display-translations.mjs --family=vm
```

5. Audit remaining untranslated strings:

```bash
node scripts/localization/audit-localization.mjs --family=vm
```

## Safety rule

Translate only user-visible text. Do not translate strings that are part of internal wiring such as `refId`, regexes, formulas, matcher options, or aliases that are reused programmatically.

The safe-display script already skips risky alias changes and should always run only on generated target-language dashboards under `dashboards/translations/`, never on `dashboards/src/en`.
