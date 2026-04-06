import fs from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();

function normalizeFamilyName(rawFamily = "") {
  const normalized = String(rawFamily || "").trim().toLowerCase();
  if (!normalized) {
    return "";
  }
  if (normalized === "vm") {
    return normalized;
  }
  throw new Error(`Unknown dashboard family '${rawFamily}'. Use vm.`);
}

function detectDefaultFamily() {
  return "vm";
}

export function parseFamilyArg(argv = process.argv) {
  const prefix = "--family=";
  const hit = argv.find((entry) => entry.startsWith(prefix));
  return hit ? normalizeFamilyName(hit.slice(prefix.length)) : "";
}

export function resolveDashboardFamily(rawFamily = "") {
  const familyName = normalizeFamilyName(rawFamily) || detectDefaultFamily();
  const dashboardsRoot = path.join(repoRoot, "dashboards");

  return {
    name: familyName,
    tagPrefix: "vm",
    dashboardsRoot,
    sourceRoot: path.join(dashboardsRoot, "src"),
    translationRoot: path.join(dashboardsRoot, "translations"),
    localizationRoot: path.join(dashboardsRoot, "localization"),
    languagesConfigPath: path.join(dashboardsRoot, "localization", "languages.json"),
  };
}

export function readLanguagesConfig(family) {
  const fallback = { sourceLanguage: "en", targetLanguages: ["de"] };

  if (!fs.existsSync(family.languagesConfigPath)) {
    return fallback;
  }

  const parsed = JSON.parse(fs.readFileSync(family.languagesConfigPath, "utf8"));
  const sourceLanguage = String(parsed.sourceLanguage || fallback.sourceLanguage).trim();
  const configuredTargets = Array.isArray(parsed.targetLanguages)
    ? parsed.targetLanguages.map((entry) => String(entry).trim()).filter(Boolean)
    : [];

  const targetLanguages = [...new Set(configuredTargets.length ? configuredTargets : [sourceLanguage])];
  if (!targetLanguages.includes(sourceLanguage)) {
    targetLanguages.unshift(sourceLanguage);
  }

  return { sourceLanguage, targetLanguages };
}

export function familySourceDir(family, sourceLanguage) {
  return path.join(family.sourceRoot, sourceLanguage);
}

export function familyTranslationDir(family, language) {
  return path.join(family.translationRoot, language);
}

export function familyMappingPath(family, sourceLanguage, targetLanguage) {
  return path.join(family.localizationRoot, `${sourceLanguage}_to_${targetLanguage}.json`);
}

export function familyReportPath(family, sourceLanguage, targetLanguage) {
  return path.join(family.localizationRoot, `missing-${sourceLanguage}_to_${targetLanguage}.exact.json`);
}
