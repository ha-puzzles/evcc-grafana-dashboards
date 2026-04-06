# Localization Workflow

- `languages.json`: defines source + target languages for the default VM flow
- `../src/<sourceLanguage>`: source of truth for VM dashboards
- `../translations/<language>`: generated output per configured target language
- `<source>_to_<target>.json`: translation mapping per language pair

Important:

- `dashboards/src/en` is the maintainer-owned source set and is never regenerated
- generated dashboards are written only under `dashboards/translations/`
- run the mapping prune step after source dashboard changes so stale keys are removed before regenerating

Rebuild mapping files against the current source dashboards:

```bash
node scripts/localization/prune-mappings-to-source.mjs --family=vm
```

Generate localized dashboard files for all configured target languages:

```bash
node scripts/localization/generate-localized-dashboards.mjs --family=vm
```

Apply safe display-only translations on generated dashboard files:

```bash
node scripts/localization/apply-safe-display-translations.mjs --family=vm
```

Audit missing source-to-target mappings for all configured targets:

```bash
node scripts/localization/audit-localization.mjs --family=vm
```

Audit one specific target language:

```bash
node scripts/localization/audit-localization.mjs --family=vm --target=de
```

The audit writes `missing-<source>_to_<target>.exact.json` with candidate keys that still need translations.
