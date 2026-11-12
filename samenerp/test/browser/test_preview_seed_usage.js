#!/usr/bin/env node
// Verify that --seed without a valid value is a usage error rather than a
// silent fallback to the default mutation seed or a partial test run.

const path = require("node:path");
const { spawnSync } = require("node:child_process");

const testPath = path.join(__dirname, "test_preview_browser_summary.js");
const cases = [
  { label: "--seed", args: ["--seed"] },
  { label: "--seed=", args: ["--seed="] },
  { label: "--seed --success", args: ["--seed", "--success"] },
  { label: "--seed nope", args: ["--seed", "nope"] },
  { label: "--seed -1", args: ["--seed", "-1"] },
  { label: "--seed 1.5", args: ["--seed", "1.5"] },
];

for (const testCase of cases) {
  const result = spawnSync(process.execPath, [testPath, ...testCase.args], {
    encoding: "utf8",
  });

  if (result.error) {
    throw new Error(`${testCase.label} failed to start: ${result.error.message}`);
  }
  if (result.status !== 2) {
    throw new Error(
      `${testCase.label} should exit 2, got ${result.status}: ${result.stderr || result.stdout}`,
    );
  }
  if (!result.stderr.includes("usage: node ... --seed <non-negative integer>")) {
    throw new Error(`${testCase.label} did not print usage: ${result.stderr}`);
  }
  if (
    result.stdout.includes("browser summary preview validator checks") ||
    result.stdout.includes("mutations")
  ) {
    throw new Error(`${testCase.label} ran mutations instead of exiting immediately: ${result.stdout}`);
  }
}

console.log(`browser summary preview seed usage check: ok (${cases.length} cases)`);
