#!/usr/bin/env node
// Validate preview_browser_summary.js --json output against the versioned schema.

const fs = require("node:fs");
const path = require("node:path");
const { isObject, validate } = require("./json_schema_subset.js");

const schemaPath = path.join(__dirname, "preview_browser_summary.schema.json");
const instancePath = process.argv[2];

const requiredFailureFiles = [
  { section: "Logs", name: "browser-console.log" },
  { section: "Logs", name: "server.log" },
  { section: "Logs", name: "chrome-stderr.log" },
  { section: "Screenshots", name: "failure.png" },
  { section: "Screenshots", name: "trash-restore-blurred.png" },
  { section: "Screenshots", name: "trash-restore-focused.png" },
  { section: "Screenshots", name: "trash-restore-diff.png" },
  { section: "Reports", name: "failure.txt" },
  { section: "Reports", name: "page.html" },
];

if (!instancePath) {
  console.error(
    "usage: node samenerp/test/browser/validate_preview_browser_summary.js <preview-summary.json>",
  );
  process.exit(2);
}

let schema;
try {
  schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
} catch (error) {
  console.error(`browser summary preview schema validation failed: ${error.message}`);
  process.exit(1);
}

const schemaVersion = schema["x-schema-version"];
if (!Number.isInteger(schemaVersion) || schemaVersion < 1) {
  console.error(
    `browser summary preview schema version is invalid: x-schema-version=${JSON.stringify(schemaVersion)}`,
  );
  process.exit(1);
}

let instance;
try {
  instance = JSON.parse(fs.readFileSync(instancePath, "utf8"));
} catch (error) {
  console.error(`browser summary preview schema validation failed: ${error.message}`);
  process.exit(1);
}

const errors = [];
validate(instance, schema, "$", errors);
if (isObject(instance) && instance.schema_version !== schemaVersion) {
  errors.push(`$.schema_version: expected ${schemaVersion} from the schema`);
}

// JSON Schema conditionals are outside the local validator subset, so enforce
// the outcome-specific failure-artifact shape here.
if (isObject(instance) && isObject(instance.failure_artifact)) {
  const failure = instance.failure_artifact;
  const artifactFields = ["size_bytes", "size", "url"];
  if (failure.produced === true) {
    for (const field of artifactFields) {
      if (!Object.prototype.hasOwnProperty.call(failure, field)) {
        errors.push(`$.failure_artifact.${field}: required when produced is true`);
      }
    }
    if (Array.isArray(failure.files)) {
      if (failure.files.length === 0) {
        errors.push("$.failure_artifact.files: expected at least one file when produced is true");
      }
      const fileEntries = failure.files.filter(isObject);
      for (const required of requiredFailureFiles) {
        const entry = fileEntries.find((file) => file.name === required.name);
        if (!entry) {
          errors.push(
            `$.failure_artifact.files: missing required file "${required.name}" (${required.section})`,
          );
        } else if (entry.section !== required.section) {
          errors.push(
            `$.failure_artifact.files: "${required.name}" must be in section ${required.section}`,
          );
        }
      }
    }
  } else if (failure.produced === false) {
    for (const field of artifactFields) {
      if (Object.prototype.hasOwnProperty.call(failure, field)) {
        errors.push(`$.failure_artifact.${field}: unexpected when produced is false`);
      }
    }
    if (Array.isArray(failure.files) && failure.files.length !== 0) {
      errors.push("$.failure_artifact.files: expected no files when produced is false");
    }
  }
}

if (errors.length > 0) {
  console.error(`browser summary preview schema validation failed (${schema.$id})`);
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(
  `browser summary preview schema validation: ok (schema version ${instance.schema_version})`,
);
