#!/usr/bin/env node
// Keep the local sample summary aligned with the CI summary block.
//
// Extracts the `Write browser diff summary` run script from ci.yml, executes it
// with the sample data from preview_browser_summary.js, and compares the result
// with the local preview output for both failure and success runs.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { buildSummary, samples } = require("./preview_browser_summary.js");

const workflowPath = path.resolve(__dirname, "../../../.github/workflows/ci.yml");
const readmePath = path.resolve(__dirname, "README.md");

function extractSummaryBlock() {
  const lines = fs.readFileSync(workflowPath, "utf8").split(/\r?\n/);
  const stepIndex = lines.findIndex(
    (line) => line.trim() === "- name: Write browser diff summary",
  );
  if (stepIndex === -1) {
    throw new Error("Write browser diff summary step not found in ci.yml");
  }

  const runIndex = lines.findIndex(
    (line, index) => index > stepIndex && line.trim() === "run: |",
  );
  if (runIndex === -1) {
    throw new Error("Summary step has no run: | block");
  }

  let firstContent = runIndex + 1;
  while (firstContent < lines.length && lines[firstContent].trim() === "") {
    firstContent += 1;
  }
  if (firstContent >= lines.length) {
    throw new Error("Summary run block is empty");
  }

  const indent = lines[firstContent].match(/^ */)[0].length;
  const block = [];
  for (let index = firstContent; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() === "") {
      block.push("");
      continue;
    }
    if (line.match(/^ */)[0].length < indent) break;
    block.push(line.slice(indent));
  }

  return block.join("\n");
}

function extractReadmeExample(marker, label) {
  const text = fs.readFileSync(readmePath, "utf8");
  const markerIndex = text.indexOf(marker);
  if (markerIndex === -1) {
    throw new Error(`README ${label} summary example marker not found`);
  }

  const fence = "```markdown\n";
  const fenceStart = text.indexOf(fence, markerIndex);
  if (fenceStart === -1) {
    throw new Error(`README ${label} summary markdown fence not found`);
  }

  const start = fenceStart + fence.length;
  const end = text.indexOf("\n```", start);
  if (end === -1) {
    throw new Error(`README ${label} summary closing fence not found`);
  }

  return text.slice(start, end).trimEnd();
}

function firstDifference(actual, expected) {
  const actualLines = actual.split("\n");
  const expectedLines = expected.split("\n");
  const length = Math.max(actualLines.length, expectedLines.length);
  for (let index = 0; index < length; index += 1) {
    if (actualLines[index] !== expectedLines[index]) {
      return {
        line: index + 1,
        actual: actualLines[index] ?? "<missing>",
        expected: expectedLines[index] ?? "<missing>",
      };
    }
  }
  return null;
}

const block = extractSummaryBlock();
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "browser-summary-preview-"));

try {
  const sizes = {};
  for (const artifact of [samples.metrics, samples.failure, ...samples.files]) {
    sizes[String(artifact.id)] = artifact.bytes;
  }
  fs.writeFileSync(
    path.join(tempDir, "browser-artifact-sizes.json"),
    JSON.stringify(sizes, null, 2) + "\n",
  );

  for (const success of [false, true]) {
    const summaryPath = path.join(tempDir, success ? "success.md" : "failure.md");
    const env = {
      ...process.env,
      RUNNER_TEMP: tempDir,
      GITHUB_STEP_SUMMARY: summaryPath,
      BROWSER_DIFF_THRESHOLD: String(samples.threshold),
      BROWSER_DIFF_THRESHOLD_SOURCE: samples.source,
      BROWSER_TEST_OUTCOME: success ? "success" : "failure",
      BROWSER_TEST_DURATION: String(samples.duration[success ? "success" : "failure"]),
      BROWSER_ARTIFACT_NAME: samples.failure.name,
      BROWSER_METRICS_ARTIFACT_NAME: samples.metrics.name,
      BROWSER_FAILURE_RETENTION_DAYS: String(samples.retention.failure),
      BROWSER_METRICS_RETENTION_DAYS: String(samples.retention.metrics),
      BROWSER_ARTIFACT_ID: String(samples.failure.id),
      BROWSER_METRICS_ARTIFACT_ID: String(samples.metrics.id),
      BROWSER_ARTIFACT_URL: samples.failure.url,
      BROWSER_METRICS_ARTIFACT_URL: samples.metrics.url,
    };

    for (const file of samples.files) {
      env[`${file.env}_ARTIFACT_ID`] = String(file.id);
      env[`${file.env}_URL`] = file.url;
    }

    const result = spawnSync("bash", ["-c", block], {
      cwd: path.resolve(__dirname, "../../.."),
      env,
      encoding: "utf8",
    });
    if (result.status !== 0) {
      throw new Error(
        `summary block failed for ${success ? "success" : "failure"}: ${result.stderr || result.stdout}`,
      );
    }

    const actual = fs.readFileSync(summaryPath, "utf8").trimEnd();
    const expected = buildSummary(success).trimEnd();
    if (actual !== expected) {
      const difference = firstDifference(actual, expected);
      throw new Error(
        `sample summary mismatch for ${success ? "success" : "failure"} at line ${difference.line}\n` +
          `expected: ${difference.expected}\n` +
          `actual:   ${difference.actual}`,
      );
    }
  }

  for (const [success, marker, label] of [
    [false, "A representative failure summary", "failure"],
    [true, "A representative successful summary", "success"],
  ]) {
    const readmeExample = extractReadmeExample(marker, label);
    const expected = buildSummary(success).trimEnd();
    if (readmeExample !== expected) {
      const difference = firstDifference(readmeExample, expected);
      throw new Error(
        `README ${label} example mismatch at line ${difference.line}\n` +
          `expected: ${difference.expected}\n` +
          `actual:   ${difference.actual}`,
      );
    }
  }

  console.log("browser summary preview alignment: ok (CI summary + README examples)");
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
