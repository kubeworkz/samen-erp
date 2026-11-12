#!/usr/bin/env node
// Validate browser-metrics.json against the versioned schema.
//
// The repository deliberately has no npm test dependency, so this uses the
// shared dependency-free validator for the JSON Schema subset in
// json_schema_subset.js.

const fs = require("node:fs");
const path = require("node:path");
const { isObject, validate } = require("./json_schema_subset.js");

const schemaPath = path.join(__dirname, "browser-metrics.schema.json");
const instancePath = process.argv[2];

if (!instancePath) {
  console.error("usage: node samenerp/test/browser/validate_browser_metrics.js <browser-metrics.json>");
  process.exit(2);
}

let schema;
try {
  schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
} catch (error) {
  console.error(`browser metrics schema validation failed: ${error.message}`);
  process.exit(1);
}

const schemaVersion = schema["x-schema-version"];
if (!Number.isInteger(schemaVersion) || schemaVersion < 1) {
  console.error(
    `browser metrics schema version is invalid: x-schema-version=${JSON.stringify(schemaVersion)}`,
  );
  process.exit(1);
}

let instance;
try {
  instance = JSON.parse(fs.readFileSync(instancePath, "utf8"));
} catch (error) {
  console.error(`browser metrics schema validation failed: ${error.message}`);
  process.exit(1);
}

const errors = [];
validate(instance, schema, "$", errors);
if (isObject(instance) && instance.schema_version !== schemaVersion) {
  errors.push(`$.schema_version: expected ${schemaVersion} from the schema`);
}

if (errors.length > 0) {
  console.error(`browser metrics schema validation failed (${schema.$id})`);
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`browser metrics schema validation: ok (schema version ${instance.schema_version})`);
