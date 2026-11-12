#!/usr/bin/env node
// Print a sample browser job summary for local review.
//
//   node samenerp/test/browser/preview_browser_summary.js
//   node samenerp/test/browser/preview_browser_summary.js --success
//   node samenerp/test/browser/preview_browser_summary.js --json [--success]
//
// This uses fixed sample sizes and artifact links; it does not call GitHub.
// check_browser_summary_preview.js reuses the sample to compare this output
// with the summary block in .github/workflows/ci.yml.

const artifactBase = "https://github.com/example/samen/actions/runs/123/artifacts";

const samples = {
  threshold: 96,
  source: "repository variable",
  duration: { failure: 15, success: 12 },
  retention: { metrics: 30, failure: 7 },
  metrics: {
    id: 1,
    name: "browser-metrics-123-1",
    bytes: 1287,
    url: `${artifactBase}/1`,
  },
  failure: {
    id: 10,
    name: "browser-failure-123-1",
    bytes: 25464,
    url: `${artifactBase}/10`,
  },
  files: [
    { id: 11, name: "browser-console.log", bytes: 2048, section: "Logs", url: `${artifactBase}/11`, env: "BROWSER_CONSOLE_LOG" },
    { id: 12, name: "server.log", bytes: 1536, section: "Logs", url: `${artifactBase}/12`, env: "BROWSER_SERVER_LOG" },
    { id: 13, name: "chrome-stderr.log", bytes: 500, section: "Logs", url: `${artifactBase}/13`, env: "BROWSER_CHROME_STDERR" },
    { id: 14, name: "failure.png", bytes: 4096, section: "Screenshots", url: `${artifactBase}/14`, env: "BROWSER_FAILURE_SCREENSHOT" },
    { id: 15, name: "trash-restore-blurred.png", bytes: 4096, section: "Screenshots", url: `${artifactBase}/15`, env: "BROWSER_TRASH_BLURRED" },
    { id: 16, name: "trash-restore-focused.png", bytes: 4096, section: "Screenshots", url: `${artifactBase}/16`, env: "BROWSER_TRASH_FOCUSED" },
    { id: 17, name: "trash-restore-diff.png", bytes: 8192, section: "Screenshots", url: `${artifactBase}/17`, env: "BROWSER_TRASH_DIFF" },
    { id: 18, name: "failure.txt", bytes: 300, section: "Reports", url: `${artifactBase}/18`, env: "BROWSER_FAILURE_REPORT" },
    { id: 19, name: "page.html", bytes: 600, section: "Reports", url: `${artifactBase}/19`, env: "BROWSER_PAGE_HTML" },
  ],
};

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}

function artifactRow(name, contents, bytes, retention, url) {
  return `| \`${name}\` | ${contents} | ${formatSize(bytes)} | ${retention} days | [Download](${url}) |`;
}

function fileRow(file) {
  return `| \`${file.name}\` | ${formatSize(file.bytes)} | ${samples.retention.failure} days | [Download](${file.url}) |`;
}

function buildSummary(success) {
  const lines = [
    "### Browser visual diff",
    "",
    `- Threshold: **${samples.threshold}**`,
    `- Source: ${samples.source}`,
    `- Outcome: **${success ? "success" : "failure"}**`,
    `- Duration: **${samples.duration[success ? "success" : "failure"]} s**`,
    "",
    "### Browser artifacts",
    "",
    "| Artifact | Contents | Size | Retention | Link |",
    "| --- | --- | --- | --- | --- |",
    artifactRow(
      samples.metrics.name,
      "Metrics JSON",
      samples.metrics.bytes,
      samples.retention.metrics,
      samples.metrics.url,
    ),
  ];

  if (success) {
    lines.push(
      `| \`${samples.failure.name}\` | Logs, screenshots, and reports | n/a | ${samples.retention.failure} days | Not produced (test did not fail) |`,
    );
    return lines.join("\n");
  }

  lines.push(
    artifactRow(
      samples.failure.name,
      "All failure files",
      samples.failure.bytes,
      samples.retention.failure,
      samples.failure.url,
    ),
    "",
    "#### Logs",
    "",
    "| File | Size | Retention | Download |",
    "| --- | --- | --- | --- |",
    ...samples.files.slice(0, 3).map(fileRow),
    "",
    "#### Screenshots",
    "",
    "| File | Size | Retention | Download |",
    "| --- | --- | --- | --- |",
    ...samples.files.slice(3, 7).map(fileRow),
    "",
    "#### Reports",
    "",
    "| File | Size | Retention | Download |",
    "| --- | --- | --- | --- |",
    ...samples.files.slice(7).map(fileRow),
  );

  return lines.join("\n");
}

function buildJson(success) {
  const outcome = success ? "success" : "failure";
  const files = success
    ? []
    : samples.files.map((file) => ({
        section: file.section,
        name: file.name,
        size_bytes: file.bytes,
        size: formatSize(file.bytes),
        retention_days: samples.retention.failure,
        url: file.url,
      }));

  return {
    schema_version: 1,
    outcome,
    threshold: samples.threshold,
    threshold_source: samples.source,
    duration_seconds: samples.duration[outcome],
    metrics_artifact: {
      name: samples.metrics.name,
      size_bytes: samples.metrics.bytes,
      size: formatSize(samples.metrics.bytes),
      retention_days: samples.retention.metrics,
      url: samples.metrics.url,
    },
    failure_artifact: {
      name: samples.failure.name,
      produced: !success,
      ...(success
        ? {}
        : {
            size_bytes: samples.failure.bytes,
            size: formatSize(samples.failure.bytes),
            url: samples.failure.url,
          }),
      retention_days: samples.retention.failure,
      files,
    },
  };
}

if (require.main === module) {
  const success = process.argv.includes("--success");
  if (process.argv.includes("--json")) {
    console.log(JSON.stringify(buildJson(success), null, 2));
  } else {
    console.log(buildSummary(success));
  }
}

module.exports = { buildJson, buildSummary, samples };
