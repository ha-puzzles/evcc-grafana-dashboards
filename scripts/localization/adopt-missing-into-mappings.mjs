import fs from "node:fs";
import path from "node:path";
import {
  familyMappingPath,
  familyReportPath,
  parseFamilyArg,
  readLanguagesConfig,
  resolveDashboardFamily,
} from "../helper/_dashboard-family.mjs";

const repoRoot = process.cwd();
const family = resolveDashboardFamily(parseFamilyArg());

function parseArg(name, fallback = "") {
  const prefix = `--${name}=`;
  const hit = process.argv.find((entry) => entry.startsWith(prefix));
  return hit ? hit.slice(prefix.length) : fallback;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, data) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

function readMapping(sourceLanguage, targetLanguage) {
  const filePath = familyMappingPath(family, sourceLanguage, targetLanguage);
  if (!fs.existsSync(filePath)) {
    return { exact: {}, contains: [], meta: null };
  }
  const parsed = readJson(filePath);
  return {
    exact: parsed.exact ?? {},
    contains: Array.isArray(parsed.contains) ? parsed.contains : [],
    meta: parsed.meta && typeof parsed.meta === "object" ? parsed.meta : null,
  };
}

function readMissingReport(sourceLanguage, targetLanguage) {
  const filePath = familyReportPath(family, sourceLanguage, targetLanguage);
  if (!fs.existsSync(filePath)) {
    return null;
  }
  const parsed = readJson(filePath);
  return parsed.exact && typeof parsed.exact === "object" ? parsed.exact : {};
}

function stripVerboseMeta(meta) {
  if (!meta || typeof meta !== "object") {
    return null;
  }

  const nextMeta = { ...meta };
  delete nextMeta.exactSources;

  return Object.keys(nextMeta).length ? nextMeta : null;
}

function adoptMissing(sourceLanguage, targetLanguage) {
  const missingExact = readMissingReport(sourceLanguage, targetLanguage);
  if (!missingExact) {
    return { targetLanguage, adopted: 0, total: 0, skipped: true };
  }

  const mapping = readMapping(sourceLanguage, targetLanguage);
  let adopted = 0;
  for (const key of Object.keys(missingExact)) {
    if (!Object.hasOwn(mapping.exact, key)) {
      mapping.exact[key] = key;
      adopted += 1;
    }
  }

  const sortedExact = Object.fromEntries(
    Object.entries(mapping.exact).sort(([left], [right]) => left.localeCompare(right, sourceLanguage)),
  );
  const output = {
    exact: sortedExact,
    contains: mapping.contains,
  };

  const nextMeta = stripVerboseMeta(mapping.meta);
  if (nextMeta) {
    output.meta = nextMeta;
  }

  writeJson(familyMappingPath(family, sourceLanguage, targetLanguage), output);
  return {
    targetLanguage,
    adopted,
    total: Object.keys(missingExact).length,
    skipped: false,
  };
}

function main() {
  const { sourceLanguage, targetLanguages } = readLanguagesConfig(family);
  const configuredTargets = targetLanguages.filter((language) => language !== sourceLanguage);
  const targetArg = parseArg("target", "all").trim();
  const requestedTargets =
    targetArg.toLowerCase() === "all"
      ? configuredTargets
      : targetArg
          .split(",")
          .map((entry) => entry.trim())
          .filter(Boolean);

  if (!requestedTargets.length) {
    console.log("No target languages configured for adoption.");
    return;
  }

  for (const targetLanguage of requestedTargets) {
    if (!configuredTargets.includes(targetLanguage)) {
      throw new Error(
        `Unknown target language '${targetLanguage}'. Configure it in ${path.relative(repoRoot, family.languagesConfigPath)}`,
      );
    }
  }

  let totalAdopted = 0;
  for (const targetLanguage of requestedTargets) {
    const result = adoptMissing(sourceLanguage, targetLanguage);
    if (result.skipped) {
      console.log(`${targetLanguage}: missing report not found, skipped.`);
      continue;
    }
    totalAdopted += result.adopted;
    console.log(`${targetLanguage}: adopted ${result.adopted} of ${result.total} missing candidates into exact.`);
  }

  console.log(`Adoption finished. Total newly adopted candidates: ${totalAdopted}`);
}

main();
