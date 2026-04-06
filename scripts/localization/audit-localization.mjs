import fs from "node:fs";
import path from "node:path";
import {
  familyMappingPath,
  familyReportPath,
  familySourceDir,
  parseFamilyArg,
  readLanguagesConfig,
  resolveDashboardFamily,
} from "../helper/_dashboard-family.mjs";

const repoRoot = process.cwd();
const family = resolveDashboardFamily(parseFamilyArg());
const translatableKeys = new Set([
  "title",
  "description",
  "label",
  "name",
  "text",
  "content",
  "displayName",
  "legendFormat",
  "emptyMessage",
]);
const safePropertyIds = new Set([
  "displayName",
  "displayNameFromDS",
]);

function parseArg(name, fallback = "") {
  const prefix = `--${name}=`;
  const hit = process.argv.find((a) => a.startsWith(prefix));
  if (!hit) {
    return fallback;
  }
  return hit.slice(prefix.length);
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
    return { exact: {}, contains: [] };
  }
  const parsed = readJson(filePath);
  return {
    exact: parsed.exact ?? {},
    contains: Array.isArray(parsed.contains) ? parsed.contains : [],
  };
}

function collectJsonFiles(dirPath) {
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectJsonFiles(fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.toLowerCase().endsWith(".json")) {
      files.push(fullPath);
    }
  }
  return files;
}

function translateString(input, mapping) {
  if (Object.hasOwn(mapping.exact, input)) {
    return mapping.exact[input];
  }

  let output = input;
  for (const pair of mapping.contains) {
    if (!pair || typeof pair.from !== "string" || typeof pair.to !== "string") {
      continue;
    }
    output = output.split(pair.from).join(pair.to);
  }
  return output;
}

function isCoveredByMapping(input, mapping) {
  if (Object.hasOwn(mapping.exact, input)) {
    return true;
  }
  for (const pair of mapping.contains) {
    if (!pair || typeof pair.from !== "string") {
      continue;
    }
    if (input.includes(pair.from)) {
      return true;
    }
  }
  return false;
}

function shouldTranslate(key, value, parent) {
  if (typeof value !== "string") {
    return false;
  }
  if (translatableKeys.has(key)) {
    if (key === "name" && !value.startsWith("EVCC:")) {
      return false;
    }
    return true;
  }
  if (
    key === "value" &&
    parent &&
    typeof parent === "object" &&
    typeof parent.id === "string" &&
    safePropertyIds.has(parent.id)
  ) {
    return true;
  }
  return false;
}

function isLikelyNaturalText(text) {
  if (typeof text !== "string") {
    return false;
  }
  if (!/\p{L}/u.test(text)) {
    return false;
  }
  if (/^https?:\/\//i.test(text)) {
    return false;
  }
  if (/^\$\{[^}]+\}$/.test(text)) {
    return false;
  }
  return true;
}

function walk(node, visit, currentPath = "$", parent = null) {
  if (Array.isArray(node)) {
    node.forEach((item, index) => walk(item, visit, `${currentPath}[${index}]`, node));
    return;
  }
  if (!node || typeof node !== "object") {
    return;
  }
  for (const [key, value] of Object.entries(node)) {
    const keyPath = `${currentPath}.${key}`;
    visit(key, value, keyPath, node, parent);
    walk(value, visit, keyPath, node);
  }
}

function auditTarget({ sourceLanguage, targetLanguage, sourceDir }) {
  const files = collectJsonFiles(sourceDir);
  const mapping = readMapping(sourceLanguage, targetLanguage);
  const missing = new Map();

  for (const file of files) {
    const relative = path.relative(sourceDir, file);
    const json = readJson(file);

    walk(json, (key, value, keyPath, node) => {
      if (!shouldTranslate(key, value, node)) {
        return;
      }
      if (!isLikelyNaturalText(value)) {
        return;
      }

      const translated = translateString(value, mapping);
      if (translated !== value) {
        return;
      }
      if (isCoveredByMapping(value, mapping)) {
        return;
      }

      const existing = missing.get(value) ?? [];
      existing.push(`${relative} :: ${keyPath}`);
      missing.set(value, existing);
    });
  }

  const sorted = [...missing.entries()].sort((a, b) => a[0].localeCompare(b[0], targetLanguage));
  const exactSuggestions = {};
  for (const [sourceText] of sorted) {
    exactSuggestions[sourceText] = "";
  }

  const outputFile = familyReportPath(family, sourceLanguage, targetLanguage);
  writeJson(outputFile, {
    generatedAt: new Date().toISOString(),
    sourceLanguage,
    targetLanguage,
    sourceDir: path.relative(repoRoot, sourceDir),
    mappingFile: path.relative(repoRoot, familyMappingPath(family, sourceLanguage, targetLanguage)),
    notes: [
      "Fill each value with the final target-language translation.",
      `Then merge into ${path.relative(repoRoot, familyMappingPath(family, sourceLanguage, targetLanguage))} under exact.`,
      "This audit includes displayName/displayNameFromDS override values.",
      "This is a candidate list; some entries can be intentionally unchanged.",
    ],
    exact: exactSuggestions,
  });

  console.log(`Target '${targetLanguage}': scanned ${files.length} dashboard files.`);
  console.log(`Target '${targetLanguage}': missing translation candidates: ${sorted.length}`);
  console.log(`Suggestion file: ${path.relative(repoRoot, outputFile)}`);

  if (sorted.length > 0) {
    console.log("Top candidates:");
    for (const [sourceText, locations] of sorted.slice(0, 20)) {
      console.log(`- ${sourceText}`);
      console.log(`  first hit: ${locations[0]}`);
    }
  }

  return sorted.length;
}

function main() {
  const { sourceLanguage, targetLanguages } = readLanguagesConfig(family);
  const sourceDir = familySourceDir(family, sourceLanguage);

  if (!fs.existsSync(sourceDir)) {
    throw new Error(`Source directory does not exist: ${sourceDir}`);
  }

  const configuredTargets = targetLanguages.filter((lang) => lang !== sourceLanguage);
  const targetArg = parseArg("target", "all").trim();
  const requestedTargets =
    targetArg.toLowerCase() === "all"
      ? configuredTargets
      : targetArg
          .split(",")
          .map((x) => x.trim())
          .filter(Boolean);

  if (!requestedTargets.length) {
    console.log("No target languages configured for audit.");
    return;
  }

  for (const targetLanguage of requestedTargets) {
    if (!configuredTargets.includes(targetLanguage)) {
      throw new Error(
        `Unknown target language '${targetLanguage}'. Configure it in ${path.relative(repoRoot, family.languagesConfigPath)}`,
      );
    }
  }

  let totalMissing = 0;
  for (const targetLanguage of requestedTargets) {
    totalMissing += auditTarget({ sourceLanguage, targetLanguage, sourceDir });
    console.log("");
  }

  console.log(`Audit finished. Total missing candidates across targets: ${totalMissing}`);
}

main();


