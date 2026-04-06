import fs from "node:fs";
import path from "node:path";
import {
  familyMappingPath,
  familySourceDir,
  parseFamilyArg,
  readLanguagesConfig,
  resolveDashboardFamily,
} from "../helper/_dashboard-family.mjs";

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

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, data) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
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

function shouldCollect(key, value, parent) {
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

function walk(node, visit, parent = null) {
  if (Array.isArray(node)) {
    for (const item of node) {
      walk(item, visit, node);
    }
    return;
  }
  if (!node || typeof node !== "object") {
    return;
  }
  for (const [key, value] of Object.entries(node)) {
    visit(key, value, node, parent);
    walk(value, visit, node);
  }
}

function collectSourceStrings(sourceDir) {
  const files = collectJsonFiles(sourceDir);
  const values = new Set();

  for (const filePath of files) {
    const json = readJson(filePath);
    walk(json, (key, value, node) => {
      if (shouldCollect(key, value, node)) {
        values.add(value);
      }
    });
  }

  return { files, values };
}

function rebuildMapping(sourceLanguage, targetLanguage, sourceValues) {
  const mappingFile = familyMappingPath(family, sourceLanguage, targetLanguage);
  if (!fs.existsSync(mappingFile)) {
    return null;
  }

  const mapping = readJson(mappingFile);
  const exactEntries = Object.entries(mapping.exact || {});
  const containsEntries = Array.isArray(mapping.contains) ? mapping.contains : [];

  const exact = Object.fromEntries(
    exactEntries
      .filter(([sourceText]) => sourceValues.has(sourceText))
      .sort(([left], [right]) => left.localeCompare(right, sourceLanguage)),
  );

  const contains = containsEntries
    .filter((entry) => entry && typeof entry.from === "string" && typeof entry.to === "string")
    .filter((entry) => [...sourceValues].some((value) => value.includes(entry.from)))
    .sort((left, right) => left.from.localeCompare(right.from, sourceLanguage));

  writeJson(mappingFile, { exact, contains });

  return {
    targetLanguage,
    beforeExact: exactEntries.length,
    afterExact: Object.keys(exact).length,
    beforeContains: containsEntries.length,
    afterContains: contains.length,
  };
}

function main() {
  const { sourceLanguage, targetLanguages } = readLanguagesConfig(family);
  const sourceDir = familySourceDir(family, sourceLanguage);

  if (!fs.existsSync(sourceDir)) {
    throw new Error(`Source directory does not exist: ${sourceDir}`);
  }

  const { files, values } = collectSourceStrings(sourceDir);
  console.log(`Scanned ${files.length} source dashboard files.`);
  console.log(`Found ${values.size} unique translatable source strings.`);

  for (const targetLanguage of targetLanguages) {
    if (targetLanguage === sourceLanguage) {
      continue;
    }
    const result = rebuildMapping(sourceLanguage, targetLanguage, values);
    if (!result) {
      console.log(`${targetLanguage}: mapping file missing, skipped.`);
      continue;
    }
    console.log(
      `${targetLanguage}: exact ${result.beforeExact} -> ${result.afterExact}, contains ${result.beforeContains} -> ${result.afterContains}`,
    );
  }
}

main();
