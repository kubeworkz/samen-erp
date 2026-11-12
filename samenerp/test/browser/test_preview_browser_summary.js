#!/usr/bin/env node
// Verify that valid preview output is accepted and deliberately corrupt
// fixtures are rejected for the expected reason.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = __dirname;
const previewPath = path.join(root, "preview_browser_summary.js");
const validatorPath = path.join(root, "validate_preview_browser_summary.js");
const fixtureDir = path.join(root, "fixtures", "preview-summary");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "browser-preview-validator-"));
const DEFAULT_MUTATION_SEED = 0x5eed1234;

const fixtureCases = [
  {
    name: "invalid-version.json",
    expected: "$.schema_version: expected 1 from the schema",
  },
  {
    name: "invalid-success-with-failure-size.json",
    expected: "$.failure_artifact.size_bytes: unexpected when produced is false",
  },
  {
    name: "invalid-failure-missing-size.json",
    expected: "$.failure_artifact.size_bytes: required when produced is true",
  },
  {
    name: "invalid-failure-empty-files.json",
    expected: "$.failure_artifact.files: expected at least one file when produced is true",
  },
  {
    name: "invalid-failure-section.json",
    expected: '$.failure_artifact.files[0].section: expected one of "Logs", "Screenshots", "Reports"',
  },
  {
    name: "invalid-failure-url.json",
    expected: "$.failure_artifact.files[0].url: does not match ^https?://\\S+$",
  },
  {
    name: "invalid-negative-duration.json",
    expected: "$.duration_seconds: expected at least 0",
  },
  {
    name: "invalid-threshold.json",
    expected: "$.threshold: expected at most 255",
  },
  {
    name: "invalid-missing-server-log.json",
    expected: '$.failure_artifact.files: missing required file "server.log" (Logs)',
  },
  {
    name: "invalid-null-file-entry.json",
    expected: "$.failure_artifact.files[0]: expected object, got null",
  },
  {
    name: "invalid-server-log-section.json",
    expected: '$.failure_artifact.files: "server.log" must be in section Logs',
  },
  {
    name: "invalid-unknown-property.json",
    expected: '$: unexpected property "unexpected"',
  },
];

function run(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error) {
    throw new Error(`${command} failed to start: ${result.error.message}`);
  }
  return result;
}

function validate(file) {
  return run(process.execPath, [validatorPath, file]);
}

function mulberry32(seed) {
  return function random() {
    let value = (seed += 0x6d2b79f5);
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function collectPaths(value, prefix = [], paths = []) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      const path = [...prefix, index];
      paths.push(path);
      collectPaths(item, path, paths);
    });
  } else if (value !== null && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      const path = [...prefix, key];
      paths.push(path);
      collectPaths(child, path, paths);
    }
  }
  return paths;
}

function getAtPath(value, path) {
  return path.reduce((current, part) => current?.[part], value);
}

function setAtPath(value, path, replacement) {
  const parent = getAtPath(value, path.slice(0, -1));
  parent[path[path.length - 1]] = replacement;
}

function deleteAtPath(value, path) {
  const parent = getAtPath(value, path.slice(0, -1));
  const key = path[path.length - 1];
  if (Array.isArray(parent)) {
    parent[key] = null;
  } else {
    delete parent[key];
  }
}

function buildMutationCases(payloads, count, seed) {
  const random = mulberry32(seed);
  const replacementValues = [
    null,
    true,
    false,
    "",
    "invalid",
    0,
    -1,
    1.5,
    999999,
    [],
    {},
    ["x"],
    { unexpected: true },
  ];
  const cases = [];

  for (let index = 0; index < count; index += 1) {
    const base = payloads[index % payloads.length];
    const payload = structuredClone(base);
    const paths = collectPaths(payload);
    const path = paths[Math.floor(random() * paths.length)];
    if (random() < 0.2) {
      deleteAtPath(payload, path);
    } else {
      const replacement = replacementValues[Math.floor(random() * replacementValues.length)];
      setAtPath(payload, path, structuredClone(replacement));
    }
    cases.push({ index, path: path.join("."), payload });
  }

  return cases;
}

function seedUsage() {
  console.error("usage: node ... --seed <non-negative integer>");
  process.exit(2);
}

function parseSeedValue(raw) {
  if (!/^(?:0x[0-9a-f]+|\d+)$/i.test(raw)) seedUsage();
  const seed = Number(raw);
  if (!Number.isSafeInteger(seed) || seed < 0) seedUsage();
  return seed >>> 0;
}

function parseMutationSeed(args) {
  const equalsArg = args.find((arg) => arg.startsWith("--seed="));
  if (equalsArg) return parseSeedValue(equalsArg.slice("--seed=".length));

  const index = args.indexOf("--seed");
  if (index === -1) return DEFAULT_MUTATION_SEED;

  const raw = args[index + 1];
  if (raw === undefined || raw.startsWith("--")) seedUsage();
  return parseSeedValue(raw);
}

function assertNoStackTrace(result, label) {
  if (/\n\s+at\s+\S+/.test(result.stderr) || /\nNode\.js v\d+/.test(result.stderr)) {
    throw new Error(`${label} produced a stack trace: ${result.stderr}`);
  }
}

function assertNoCrash(result, label) {
  if (result.error) {
    throw new Error(`${label} failed to run: ${result.error.message}`);
  }
  if (result.status !== 0 && result.status !== 1) {
    throw new Error(`${label} exited with unexpected status ${result.status}: ${result.stderr}`);
  }
  if (result.status === 1) {
    if (!result.stderr.includes("browser summary preview schema validation failed")) {
      throw new Error(`${label} exited 1 without a validation error: ${result.stderr}`);
    }
    if (/\b(?:TypeError|ReferenceError|RangeError|SyntaxError)\b/.test(result.stderr)) {
      throw new Error(`${label} crashed during validation: ${result.stderr}`);
    }
  }
}

const mutationSeed = parseMutationSeed(process.argv.slice(2));

try {
  const validPayloads = [];
  for (const [name, args] of [
    ["failure.json", ["--json"]],
    ["success.json", ["--json", "--success"]],
  ]) {
    const preview = run(process.execPath, [previewPath, ...args]);
    if (preview.status !== 0) {
      throw new Error(`preview ${args.join(" ")} failed: ${preview.stderr || preview.stdout}`);
    }

    const file = path.join(tempDir, name);
    fs.writeFileSync(file, preview.stdout);
    const result = validate(file);
    if (result.status !== 0) {
      throw new Error(`valid preview ${name} was rejected: ${result.stderr || result.stdout}`);
    }
    validPayloads.push(JSON.parse(preview.stdout));
  }

  for (const fixture of fixtureCases) {
    const file = path.join(fixtureDir, fixture.name);
    const result = validate(file);
    assertNoCrash(result, fixture.name);
    assertNoStackTrace(result, fixture.name);
    if (result.status !== 1) {
      throw new Error(
        `${fixture.name} should be rejected with status 1, got ${result.status}: ` +
          `${result.stderr || result.stdout}`,
      );
    }
    if (!result.stderr.includes(fixture.expected)) {
      throw new Error(
        `${fixture.name} rejection did not include ${JSON.stringify(fixture.expected)}: ` +
          `${result.stderr}`,
      );
    }
  }

  const parseErrorFixture = "invalid-json-syntax.json";
  const parseErrorResult = validate(path.join(fixtureDir, parseErrorFixture));
  assertNoCrash(parseErrorResult, parseErrorFixture);
  if (parseErrorResult.status !== 1) {
    throw new Error(
      `${parseErrorFixture} should exit 1, got ${parseErrorResult.status}: ` +
        `${parseErrorResult.stderr || parseErrorResult.stdout}`,
    );
  }
    if (!/browser summary preview schema validation failed: .*JSON/i.test(parseErrorResult.stderr)) {
    throw new Error(`${parseErrorFixture} did not report a JSON parse error: ${parseErrorResult.stderr}`);
  }
  assertNoStackTrace(parseErrorResult, parseErrorFixture);

  const mutationCases = buildMutationCases(validPayloads, 64, mutationSeed);
  const alternateSeed = (mutationSeed ^ 0x9e3779b9) >>> 0;
  const alternateMutationCases = buildMutationCases(validPayloads, 64, alternateSeed);
  if (
    JSON.stringify(mutationCases.map((mutation) => mutation.payload)) ===
    JSON.stringify(alternateMutationCases.map((mutation) => mutation.payload))
  ) {
    throw new Error(
      `mutation seeds 0x${mutationSeed.toString(16)} and 0x${alternateSeed.toString(16)} ` +
        "produced identical payloads",
    );
  }

  const mutationSets = [
    { label: "mutation", prefix: "mutation", cases: mutationCases },
    {
      label: "alternate mutation",
      prefix: "alternate-mutation",
      cases: alternateMutationCases,
    },
  ];
  for (const mutationSet of mutationSets) {
    for (const mutation of mutationSet.cases) {
      const file = path.join(tempDir, `${mutationSet.prefix}-${mutation.index}.json`);
      fs.writeFileSync(file, JSON.stringify(mutation.payload));
      const label = `${mutationSet.label} ${mutation.index} at ${mutation.path}`;
      const result = validate(file);
      assertNoCrash(result, label);
      assertNoStackTrace(result, label);
    }
  }

  console.log(
    `browser summary preview validator checks: ok (2 valid outputs, ` +
      `${fixtureCases.length + 1} invalid fixtures, ${mutationCases.length} mutations, ` +
      `${alternateMutationCases.length} alternate mutations, ` +
      `seed 0x${mutationSeed.toString(16)}, alternate seed 0x${alternateSeed.toString(16)} differs)`,
  );
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
