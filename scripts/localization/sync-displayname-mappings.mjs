import fs from "node:fs";
import path from "node:path";
import {
  familyMappingPath,
  familySourceDir,
  familyTranslationDir,
  parseFamilyArg,
  readLanguagesConfig,
  resolveDashboardFamily,
} from "../helper/_dashboard-family.mjs";

const family = resolveDashboardFamily(parseFamilyArg());

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, data) {
  fs.writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

function collectJsonFiles(dirPath) {
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectJsonFiles(fullPath));
    } else if (entry.isFile() && entry.name.toLowerCase().endsWith(".json")) {
      files.push(fullPath);
    }
  }
  return files;
}

function collectDisplayNamePairs(sourceNode, targetNode, pairs) {
  if (Array.isArray(sourceNode) && Array.isArray(targetNode)) {
    const len = Math.min(sourceNode.length, targetNode.length);
    for (let i = 0; i < len; i += 1) {
      collectDisplayNamePairs(sourceNode[i], targetNode[i], pairs);
    }
    return;
  }

  if (!sourceNode || !targetNode || typeof sourceNode !== "object" || typeof targetNode !== "object") {
    return;
  }

  if (
    typeof sourceNode.id === "string" &&
    typeof targetNode.id === "string" &&
    sourceNode.id === targetNode.id &&
    (sourceNode.id === "displayName" || sourceNode.id === "displayNameFromDS") &&
    typeof sourceNode.value === "string" &&
    typeof targetNode.value === "string" &&
    sourceNode.value !== targetNode.value
  ) {
    pairs.set(sourceNode.value, targetNode.value);
  }

  const keys = new Set([...Object.keys(sourceNode), ...Object.keys(targetNode)]);
  for (const key of keys) {
    if (!(key in sourceNode) || !(key in targetNode)) {
      continue;
    }
    collectDisplayNamePairs(sourceNode[key], targetNode[key], pairs);
  }
}

function updateMapping(sourceLanguage, targetLanguage) {
  const sourceLangDir = familySourceDir(family, sourceLanguage);
  const targetLangDir = familyTranslationDir(family, targetLanguage);
  const mappingFile = familyMappingPath(family, sourceLanguage, targetLanguage);

  if (!fs.existsSync(targetLangDir) || !fs.existsSync(mappingFile)) {
    return { targetLanguage, added: 0, totalPairs: 0 };
  }

  const mapping = readJson(mappingFile);
  mapping.exact = mapping.exact || {};
  mapping.contains = Array.isArray(mapping.contains) ? mapping.contains : [];

  const files = collectJsonFiles(sourceLangDir);
  const pairs = new Map();

  for (const sourceFile of files) {
    const relative = path.relative(sourceLangDir, sourceFile);
    const targetFile = path.join(targetLangDir, relative);
    if (!fs.existsSync(targetFile)) {
      continue;
    }

    const sourceJson = readJson(sourceFile);
    const targetJson = readJson(targetFile);
    collectDisplayNamePairs(sourceJson, targetJson, pairs);
  }

  let added = 0;
  for (const [sourceValue, targetValue] of pairs.entries()) {
    if (!Object.hasOwn(mapping.exact, sourceValue)) {
      mapping.exact[sourceValue] = targetValue;
      added += 1;
    }
  }

  if (added > 0) {
    const sortedExact = Object.fromEntries(
      Object.entries(mapping.exact).sort(([a], [b]) => a.localeCompare(b, sourceLanguage)),
    );
    mapping.exact = sortedExact;
    writeJson(mappingFile, mapping);
  }

  return { targetLanguage, added, totalPairs: pairs.size };
}

function main() {
  const { sourceLanguage, targetLanguages } = readLanguagesConfig(family);
  for (const targetLanguage of targetLanguages) {
    if (targetLanguage === sourceLanguage) {
      continue;
    }
    const result = updateMapping(sourceLanguage, targetLanguage);
    console.log(`${result.targetLanguage}: added ${result.added} displayName mappings from ${result.totalPairs} discovered pairs.`);
  }
}

main();


