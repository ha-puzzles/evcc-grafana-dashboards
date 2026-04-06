# Localization Maintainer Workflow

This repository uses the maintainer-managed VictoriaMetrics dashboards under `dashboards/src/` as the source for localization work.

## Repository scope

- source of truth: `dashboards/src/en`
- generated translations: `dashboards/translations/<language>`
- mapping files: `dashboards/localization/en_to_<language>.json`
- missing-coverage reports: `dashboards/localization/missing-en_to_<language>.exact.json`
- actual target-language wording must be written by a human or AI in `dashboards/localization/en_to_<language>.json`; the scripts do not translate text automatically

## Standard workflow

1. Update source dashboards only in `dashboards/src/en`.
2. Rebuild mapping files against the current source set:

```bash
node scripts/localization/prune-mappings-to-source.mjs --family=vm
```

This keeps the mapping files trimmed to the strings that still exist in `src/en` and removes verbose source-tracking metadata from the mapping files so they stay readable.

3. Update mappings.

Manual path:
- review `missing-en_to_<language>.exact.json`
- use `exactSources` in that file to see which source dashboard file names each source string comes from
- copy only the intended entries into `en_to_<language>.json`
- fill the target-language value in `exact`
- the final text must be translated manually by a human or with AI assistance before regeneration

Bulk-accept path:

```bash
node scripts/localization/adopt-missing-into-mappings.mjs --family=vm --target=all
```

This bulk step only marks current source strings as accepted by copying them into `exact` with the same value. It is useful when you intentionally want full audit coverage first and translation quality refinement later. A human or AI still has to replace those placeholder values with real target-language translations.

4. Generate translated dashboards:

```bash
node scripts/localization/generate-localized-dashboards.mjs --family=vm
```

5. Apply the safe display-only pass:

```bash
node scripts/localization/apply-safe-display-translations.mjs --family=vm
```

6. Audit remaining untranslated strings:

```bash
node scripts/localization/audit-localization.mjs --family=vm
```

The audit report includes `exactSources` so you can see which `src/en` dashboard file names still need manual translation work. The audit only finds untranslated places; it does not translate them.

## Safety rule

Translate only user-visible text. Do not translate strings that are part of internal wiring such as `refId`, regexes, formulas, matcher options, or aliases that are reused programmatically.

The safe-display script already skips risky alias changes and should always run only on generated target-language dashboards under `dashboards/translations/`, never on `dashboards/src/en`.
