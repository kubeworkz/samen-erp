#!/usr/bin/env node
// Fail if browser-metrics.schema.json uses a keyword or construct that
// validate_browser_metrics.js does not interpret. The CI schema meta-check
// proves the document is well-formed; this lint keeps it within the local
// validator's deliberately small subset.

const fs = require("node:fs");
const path = require("node:path");

const supportedValidationKeywords = new Set([
  "type",
  "const",
  "enum",
  "required",
  "properties",
  "additionalProperties",
  "pattern",
  "minLength",
  "maxLength",
  "minimum",
  "maximum",
  "items",
]);

// These describe or annotate a schema; they do not need validator support.
const supportedAnnotationKeywords = new Set([
  "$schema",
  "$id",
  "$comment",
  "title",
  "description",
  "default",
  "examples",
  "deprecated",
  "readOnly",
  "writeOnly",
  "x-schema-version",
]);

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isSupportedKeyword(keyword) {
  return supportedValidationKeywords.has(keyword) || supportedAnnotationKeywords.has(keyword);
}

function visit(schema, jsonPath, errors) {
  if (!isObject(schema)) {
    errors.push(`${jsonPath}: schema nodes must be objects`);
    return;
  }

  for (const keyword of Object.keys(schema)) {
    if (!isSupportedKeyword(keyword)) {
      errors.push(`${jsonPath}: unsupported keyword "${keyword}"`);
    }
  }

  if (schema.properties !== undefined) {
    if (!isObject(schema.properties)) {
      errors.push(`${jsonPath}.properties: expected an object`);
    } else {
      for (const [name, child] of Object.entries(schema.properties)) {
        visit(child, `${jsonPath}.properties.${name}`, errors);
      }
    }
  }

  if (schema.items !== undefined) {
    if (!isObject(schema.items)) {
      errors.push(`${jsonPath}.items: only a single object schema is supported`);
    } else {
      visit(schema.items, `${jsonPath}.items`, errors);
    }
  }

  if (
    schema.additionalProperties !== undefined &&
    typeof schema.additionalProperties !== "boolean"
  ) {
    errors.push(`${jsonPath}.additionalProperties: only a boolean is supported`);
  }
}

const schemaPath =
  process.argv[2] || path.join(__dirname, "browser-metrics.schema.json");

let schema;
try {
  schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
} catch (error) {
  console.error(`browser metrics schema keyword lint failed: ${error.message}`);
  process.exit(1);
}

const errors = [];
visit(schema, "$", errors);

if (errors.length > 0) {
  console.error("browser metrics schema keyword lint failed");
  for (const error of errors) console.error(`- ${error}`);
  console.error(
    "Add the keyword to validate_browser_metrics.js (and this lint), or remove it from the schema.",
  );
  process.exit(1);
}

console.log("browser metrics schema keyword lint: ok");
