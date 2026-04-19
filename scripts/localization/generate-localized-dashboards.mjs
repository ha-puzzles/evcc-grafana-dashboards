/**
 * Script: generate-localized-dashboards.mjs
 * Purpose: Renders localized dashboard JSON files from dashboards/src/en by using the language mappings.
 * Version: 2026.04.11.2
 * Last modified: 2026-04-11
 */
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

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, jsonData) {
  const content = `${JSON.stringify(jsonData, null, 2)}\n`;
  fs.writeFileSync(filePath, content, "utf8");
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

function translateJsonNode(node, mapping) {
  if (Array.isArray(node)) {
    return node.map((item) => translateJsonNode(item, mapping));
  }

  if (node && typeof node === "object") {
    const result = {};
    for (const [key, value] of Object.entries(node)) {
      const isSafeName = key !== "name" || (typeof value === "string" && value.startsWith("EVCC:"));
      const isPropertyValueForTranslatableId =
        key === "value" && typeof node.id === "string" && translatableKeys.has(node.id);

      if (
        typeof value === "string" &&
        ((translatableKeys.has(key) && isSafeName) || isPropertyValueForTranslatableId)
      ) {
        result[key] = translateString(value, mapping);
      } else {
        result[key] = translateJsonNode(value, mapping);
      }
    }
    return result;
  }

  return node;
}

function main() {
  const { sourceLanguage, targetLanguages } = readLanguagesConfig(family);
  const sourceDir = familySourceDir(family, sourceLanguage);

  if (!fs.existsSync(sourceDir)) {
    throw new Error(`Source directory does not exist: ${sourceDir}`);
  }

  const files = collectJsonFiles(sourceDir);
  const mappingCache = new Map();

  for (const targetLanguage of targetLanguages) {
    const outDir = familyTranslationDir(family, targetLanguage);
    ensureDir(outDir);

    const mapping =
      targetLanguage === sourceLanguage
        ? { exact: {}, contains: [] }
        : (mappingCache.get(targetLanguage) || readMapping(sourceLanguage, targetLanguage));

    mappingCache.set(targetLanguage, mapping);

    let count = 0;
    for (const sourceFile of files) {
      const relative = path.relative(sourceDir, sourceFile);
      const targetFile = path.join(outDir, relative);
      ensureDir(path.dirname(targetFile));

      const sourceJson = readJson(sourceFile);
      const localizedJson =
        targetLanguage === sourceLanguage
          ? sourceJson
          : translateJsonNode(sourceJson, mapping);

      writeJson(targetFile, localizedJson);
      count += 1;
    }

    console.log(`Generated ${count} dashboard files for '${targetLanguage}' in family '${family.name}'.`);
    console.log(`Output: ${path.relative(repoRoot, outDir)}`);
    if (targetLanguage !== sourceLanguage) {
      console.log(
        `Mapping: ${path.relative(repoRoot, familyMappingPath(family, sourceLanguage, targetLanguage))}`,
      );
    }
  }
}

main();
