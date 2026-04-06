import fs from "node:fs";
import path from "node:path";
import {
  familyMappingPath,
  familyTranslationDir,
  parseFamilyArg,
  readLanguagesConfig,
  resolveDashboardFamily,
} from "../helper/_dashboard-family.mjs";

const repoRoot = process.cwd();
const family = resolveDashboardFamily(parseFamilyArg());

const safeStringKeys = new Set([
  "title",
  "description",
  "label",
  "text",
  "content",
  "displayName",
  "emptyMessage",
]);

const safePropertyIds = new Set([
  "displayName",
  "displayNameFromDS",
]);

function translateMatcherOptions(node, mapping) {
  if (!node || typeof node !== "object") {
    return node;
  }

  if (
    node.id === "byName" &&
    typeof node.options === "string"
  ) {
    return {
      ...node,
      options: translateString(node.options, mapping),
    };
  }

  return node;
}

const aliasRiskyKeys = new Set([
  "refId",
  "expression",
  "query",
  "rawSql",
  "sql",
  "regex",
  "pattern",
  "matcher",
  "options",
  "transformations",
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

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, jsonData) {
  fs.writeFileSync(filePath, `${JSON.stringify(jsonData, null, 2)}\n`, "utf8");
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

function isSamePath(pathA, pathB) {
  if (pathA.length !== pathB.length) {
    return false;
  }

  for (let i = 0; i < pathA.length; i += 1) {
    if (pathA[i] !== pathB[i]) {
      return false;
    }
  }

  return true;
}

function stringMentionsAlias(value, alias) {
  if (value === alias) {
    return true;
  }

  if (value.includes(`$${alias}`)) {
    return true;
  }

  if (alias.length >= 4 && value.includes(alias)) {
    return true;
  }

  return false;
}

function valueMentionsAlias(value, alias) {
  if (typeof value === "string") {
    return stringMentionsAlias(value, alias);
  }

  if (Array.isArray(value)) {
    return value.some((item) => valueMentionsAlias(item, alias));
  }

  if (value && typeof value === "object") {
    return Object.values(value).some((item) => valueMentionsAlias(item, alias));
  }

  return false;
}

function hasUnsafeAliasReference(node, alias, skipPath, currentPath = []) {
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i += 1) {
      if (hasUnsafeAliasReference(node[i], alias, skipPath, [...currentPath, i])) {
        return true;
      }
    }
    return false;
  }

  if (!node || typeof node !== "object") {
    return false;
  }

  for (const [key, value] of Object.entries(node)) {
    const childPath = [...currentPath, key];
    if (isSamePath(childPath, skipPath)) {
      continue;
    }

    if (aliasRiskyKeys.has(key) && valueMentionsAlias(value, alias)) {
      return true;
    }

    if (hasUnsafeAliasReference(value, alias, skipPath, childPath)) {
      return true;
    }
  }

  return false;
}

function canTranslateAlias(panelNode, targetIndex, alias) {
  const aliasPath = ["targets", targetIndex, "alias"];
  return !hasUnsafeAliasReference(panelNode, alias, aliasPath);
}

function translatedXField(node, translatedNode, mapping) {
  const originalXField = node?.options?.xField;
  if (typeof originalXField !== "string") {
    return "";
  }

  const nextXField = translateString(originalXField, mapping);
  if (nextXField === originalXField) {
    return "";
  }

  const translatedTargets = Array.isArray(translatedNode?.targets) ? translatedNode.targets : [];
  return translatedTargets.some((target) => target?.legendFormat === nextXField) ? nextXField : "";
}

function translateSafeNode(node, mapping) {
  if (Array.isArray(node)) {
    return node.map((item) => translateSafeNode(item, mapping));
  }

  if (!node || typeof node !== "object") {
    return node;
  }

  const result = {};
  for (const [childKey, childValue] of Object.entries(node)) {
    if (typeof childValue === "string" && safeStringKeys.has(childKey)) {
      result[childKey] = translateString(childValue, mapping);
      continue;
    }

    if (
      childKey === "value" &&
      typeof childValue === "string" &&
      typeof node.id === "string" &&
      safePropertyIds.has(node.id)
    ) {
      result[childKey] = translateString(childValue, mapping);
      continue;
    }

    if (childKey === "targets" && Array.isArray(childValue)) {
      result[childKey] = childValue.map((target, targetIndex) => {
        const translatedTarget = translateSafeNode(target, mapping);
        if (!target || typeof target !== "object" || typeof target.alias !== "string") {
          return translatedTarget;
        }

        const translatedAlias = translateString(target.alias, mapping);
        if (translatedAlias === target.alias) {
          return translatedTarget;
        }

        if (!canTranslateAlias(node, targetIndex, target.alias)) {
          return translatedTarget;
        }

        return {
          ...translatedTarget,
          alias: translatedAlias,
        };
      });
      continue;
    }

    result[childKey] = translateSafeNode(childValue, mapping);
  }

  const nextXField = translatedXField(node, result, mapping);
  if (nextXField) {
    result.options = {
      ...(result.options || {}),
      xField: nextXField,
    };
  }

  return translateMatcherOptions(result, mapping);
}

function main() {
  const { sourceLanguage, targetLanguages } = readLanguagesConfig(family);
  let totalFiles = 0;

  for (const targetLanguage of targetLanguages) {
    if (targetLanguage === sourceLanguage) {
      continue;
    }

    const targetDir = familyTranslationDir(family, targetLanguage);
    if (!fs.existsSync(targetDir)) {
      console.warn(`Skipping missing translation directory: ${path.relative(repoRoot, targetDir)}`);
      continue;
    }

    const mapping = readMapping(sourceLanguage, targetLanguage);
    const files = collectJsonFiles(targetDir);

    for (const filePath of files) {
      const sourceJson = readJson(filePath);
      const translatedJson = translateSafeNode(sourceJson, mapping);
      writeJson(filePath, translatedJson);
      totalFiles += 1;
    }

    console.log(
      `Applied safe display-only translations to ${files.length} dashboard files for '${targetLanguage}' in family '${family.name}'.`,
    );
  }

  console.log(`Processed ${totalFiles} generated dashboard files in total.`);
}

main();


