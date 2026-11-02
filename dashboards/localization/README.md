# Localization Workflow

- `languages.json`: defines source + target languages for the default VM flow
- `../src/<sourceLanguage>`: source of truth for VM dashboards
- `../translations/<language>`: generated output per configured target language
- `<source>_to_<target>.json`: translation mapping per language pair
- contributor setup guide: `../../docs/translation-contributor-setup.md`

Important:

- `dashboards/src/en` is the maintainer-owned source set and is never regenerated
- source-only corrections may be committed without regenerating `dashboards/translations/`; run the full workflow only when generated outputs or mappings should be refreshed
- generated dashboards are written only under `dashboards/translations/`
- run the mapping prune step after source dashboard changes so stale keys are removed before regenerating
- a human or AI must provide the actual target-language text in the mapping files; the scripts do not perform textual translation themselves
- the scripts only find untranslated candidates and regenerate the target dashboards from the mapping files

Rebuild mapping files against the current source dashboards. The first command is a dry-run; add `--write` to modify mapping files:

```bash
node scripts/localization/prune-mappings-to-source.mjs --family=vm
node scripts/localization/prune-mappings-to-source.mjs --family=vm --write
```

If you intentionally want to accept every current audit candidate as-is, copy all `missing-*.exact.json` keys into the real mapping files automatically. The first command is a dry-run; add `--write` to modify mapping files:

```bash
node scripts/localization/adopt-missing-into-mappings.mjs --family=vm --target=all
node scripts/localization/adopt-missing-into-mappings.mjs --family=vm --target=all --write
```

This does not translate text. With `--write`, it copies each missing source string into `exact` with the same value so the current source string is treated as accepted coverage. The final wording still has to be written by a human or AI in the target language.

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

The audit writes `missing-<source>_to_<target>.exact.json` with candidate keys that still need translations and an `exactSources` section that lists the `src/en` dashboard file names where each candidate appears. The audit does not translate them; it only reports what still needs translation.
