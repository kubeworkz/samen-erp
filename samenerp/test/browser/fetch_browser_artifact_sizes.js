#!/usr/bin/env node
// Write the compressed sizes of this run's artifacts as { "<artifact-id>": bytes }.
// One request is made to the run-level artifacts endpoint.

const fs = require("node:fs");

const outputPath = process.argv[2];

if (!outputPath) {
  console.error(
    "usage: node samenerp/test/browser/fetch_browser_artifact_sizes.js <output-json>",
  );
  process.exit(2);
}

const apiUrl = process.env.GITHUB_API_URL || "https://api.github.com";
const repository = process.env.GITHUB_REPOSITORY;
const runId = process.env.GITHUB_RUN_ID;
const token = process.env.GITHUB_TOKEN;

if (!repository || !runId || !token) {
  console.error("GITHUB_REPOSITORY, GITHUB_RUN_ID, and GITHUB_TOKEN are required");
  process.exit(2);
}

const perPage = 100;

async function fetchPage(page) {
  const response = await fetch(
    `${apiUrl}/repos/${repository}/actions/runs/${runId}/artifacts?per_page=${perPage}&page=${page}`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "X-GitHub-Api-Version": "2022-11-28",
      },
    },
  );

  if (!response.ok) {
    throw new Error(`GitHub API returned ${response.status}`);
  }

  const data = await response.json();
  if (!Array.isArray(data.artifacts)) {
    throw new Error("GitHub API response has no artifacts array");
  }
  if (!Number.isInteger(data.total_count) || data.total_count < 0) {
    throw new Error("GitHub API response has no valid total_count");
  }

  return data;
}

function addSizes(sizes, artifacts) {
  for (const artifact of artifacts) {
    if (
      Number.isInteger(artifact.id) &&
      Number.isInteger(artifact.size_in_bytes) &&
      artifact.size_in_bytes >= 0
    ) {
      sizes[String(artifact.id)] = artifact.size_in_bytes;
    }
  }
}

async function fetchSizes() {
  const firstPage = await fetchPage(1);
  const sizes = {};
  addSizes(sizes, firstPage.artifacts);

  const pageCount = Math.max(1, Math.ceil(firstPage.total_count / perPage));
  for (let page = 2; page <= pageCount; page += 1) {
    const nextPage = await fetchPage(page);
    addSizes(sizes, nextPage.artifacts);
  }

  return sizes;
}

fetchSizes()
  .then((sizes) => {
    fs.writeFileSync(outputPath, JSON.stringify(sizes, null, 2) + "\n");
    console.log(`browser artifact sizes: ${Object.keys(sizes).length} artifacts`);
  })
  .catch((error) => {
    console.error(`browser artifact sizes lookup failed: ${error.message}`);
    process.exit(1);
  });
