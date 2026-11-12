# Browser tests

`trash_target_test.js` is the browser-level proof for the archived-evidence → Docs trash focus
handoff. It boots the real Samenerp endpoint on an isolated test database, uses the installed
Chrome through the DevTools protocol, follows the close dashboard's `open trash` link, and asserts
the targeted row's Restore button is the active element.

It also runs a visual snapshot check: the page is cropped to the targeted trash row, two blurred
captures must be identical, the row must not move when Restore is focused, two focused captures
must be identical, and the focused capture must differ from the blurred one. The comparison is
deliberately against the same page in two states rather than a checked-in image, so it detects a
missing focus indicator without failing on OS- or Chrome-version font and anti-aliasing
differences.

Run it from the repository root:

```sh
node samenerp/test/browser/trash_target_test.js
```

Requirements:

- Node 24+ (the test uses the built-in `fetch` and `WebSocket`; no npm install is needed).
- Chrome or Chromium. Set `CHROME_PATH` if it is not in a standard location.
- Port `4013` and the `samenerp_browser_test` database must be free; the fixture drops/recreates
  and migrates that isolated database on each run.

CI runs the same test in the `browser` job. When the runner already has Chrome it reuses it;
otherwise the job installs Chrome for Testing before running the test. Mix dependencies are
cached by lockfile hash, and the Chrome download is cached for the current ISO week.

On failure the test writes `failure.png`, `page.html`, `browser-console.log`, `server.log`,
`chrome-stderr.log`, and `failure.txt` to `BROWSER_ARTIFACT_DIR` (default: a temporary
directory). Once the visual check has captured its snapshots, it also writes
`trash-restore-blurred.png`, `trash-restore-focused.png`, and a labeled side-by-side
`trash-restore-diff.png` there, so the two states can be compared directly. The diff image's third
panel is a pixel-difference heatmap: unchanged pixels are dark, sub-threshold changes are slate,
and tolerant changes run from yellow to red as the channel delta grows. `BROWSER_DIFF_THRESHOLD`
sets the tolerant cutoff (default `24`, clamped to `1..255`); sensitive counts include every
nonzero delta. `failure.txt` records both counts and both bounding boxes in row-crop coordinates.
CI reads the repository Actions variable `BROWSER_DIFF_THRESHOLD`, falling back to `24`, so the
cutoff can be tuned from repository settings without editing code. A manual `workflow_dispatch`
run can override it with the `browser_diff_threshold` input. To review the job-summary layout
without running CI, run `node samenerp/test/browser/preview_browser_summary.js`; add `--success`
to see the successful-run variant, or `--json` for a machine-readable sample (combinable with
`--success`). The JSON shape is defined by `preview_browser_summary.schema.json` and checked by
`validate_preview_browser_summary.js`; CI validates both outcomes and checks checked-in corrupt
fixtures under `fixtures/preview-summary/` are rejected for the expected reasons, including a
malformed-JSON parse-error fixture. The validator
also requires the expected failure bundle entries (logs, screenshots, and reports) when the
failure artifact is produced, and runs deterministic random-field mutations to ensure malformed
JSON is rejected without crashing the validator. The mutation seed defaults to `0x5eed1234`; run
`node samenerp/test/browser/test_preview_browser_summary.js --seed 1234` to exercise a different
payload set; a `--seed` flag without a value, or with a non-numeric, negative, fractional, or empty
value, exits with usage rather than falling back to the default. The test also asserts that a
second valid seed produces a different mutation payload set and runs that alternate set through
the validator. CI runs
`check_browser_summary_preview.js`, which executes the actual summary block with the preview's
sample data, runs both outcomes, and verifies that both embedded examples still match their
outputs. The test logs the resolved, clamped
value and its source as `browser diff threshold: <n> (source: <dispatch input|repository
variable|default>)` before starting the fixture. Local runs without the source variable report
`environment` or `default`. CI also writes the threshold, source, browser-test outcome and
duration to the run's job summary. Its browser artifact index keeps stable rows for the metrics
JSON and the failure bundle, linking to the metrics, logs, and screenshots when uploads succeed
and showing a fallback status otherwise. Download links require a signed-in GitHub session. The
directory is uploaded as the `browser-failure-<run>-<attempt>` artifact. On failure, the three
logs, four screenshots, `failure.txt`, and `page.html` are also uploaded as individual artifacts
so the summary can link each file separately; those links download a single-file artifact
archive. The metrics artifact is retained for 30 days; the failure bundle and per-file artifacts
for 7 days. Summary sizes are the actual compressed artifact sizes reported by the GitHub
Actions artifacts API; paginated run-level requests build the size map, and `n/a` is shown when an
artifact or its metadata is unavailable. Runs with up to 100 artifacts need one request; larger
runs fetch the remaining pages. Every run also uploads a
machine-readable `browser-metrics.json` as `browser-metrics-<run>-<attempt>`, containing the
browser-test outcome, `duration_seconds`, the clamped `threshold`, `threshold_source`, the
commit SHA, workflow run URL, run attempt, and job URL. Its shape is described by
`browser-metrics.schema.json`; the schema's `x-schema-version` is the single source of truth for
`schema_version`. CI reads it when writing the artifact, and
`validate_browser_metrics.js` rejects an artifact whose `schema_version` does not match it. The
validator runs before the artifact is uploaded. CI also installs a pinned `jsonschema` release in
an isolated temporary virtualenv and validates the schema document itself against the draft
2020-12 meta-schema before running the browser test.

A representative failure summary, generated by `preview_browser_summary.js` (the links are
placeholders):

```markdown
### Browser visual diff

- Threshold: **96**
- Source: repository variable
- Outcome: **failure**
- Duration: **15 s**

### Browser artifacts

| Artifact | Contents | Size | Retention | Link |
| --- | --- | --- | --- | --- |
| `browser-metrics-123-1` | Metrics JSON | 1.3 KB | 30 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/1) |
| `browser-failure-123-1` | All failure files | 24.9 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/10) |

#### Logs

| File | Size | Retention | Download |
| --- | --- | --- | --- |
| `browser-console.log` | 2.0 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/11) |
| `server.log` | 1.5 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/12) |
| `chrome-stderr.log` | 500 B | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/13) |

#### Screenshots

| File | Size | Retention | Download |
| --- | --- | --- | --- |
| `failure.png` | 4.0 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/14) |
| `trash-restore-blurred.png` | 4.0 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/15) |
| `trash-restore-focused.png` | 4.0 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/16) |
| `trash-restore-diff.png` | 8.0 KB | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/17) |

#### Reports

| File | Size | Retention | Download |
| --- | --- | --- | --- |
| `failure.txt` | 300 B | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/18) |
| `page.html` | 600 B | 7 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/19) |
```

A representative successful summary has no failure-artifact section:

```markdown
### Browser visual diff

- Threshold: **96**
- Source: repository variable
- Outcome: **success**
- Duration: **12 s**

### Browser artifacts

| Artifact | Contents | Size | Retention | Link |
| --- | --- | --- | --- | --- |
| `browser-metrics-123-1` | Metrics JSON | 1.3 KB | 30 days | [Download](https://github.com/example/samen/actions/runs/123/artifacts/1) |
| `browser-failure-123-1` | Logs, screenshots, and reports | n/a | 7 days | Not produced (test did not fail) |
```

## Schema changes

Use this checklist when changing the metrics artifact:

- [ ] Update `browser-metrics.schema.json` first. `x-schema-version` is the only version source;
      the CI writer and `validate_browser_metrics.js` both read it.
- [ ] Update the metrics writer in `.github/workflows/ci.yml` for every added, removed, or
      renamed artifact field. The writer must keep emitting the version read from the schema.
- [ ] Bump `x-schema-version` for incompatible changes: removing or renaming fields, changing a
      field's type or meaning, or adding a required field. Additive optional fields normally do
      not need a bump, but still require schema/writer updates.
- [ ] Update `validate_browser_metrics.js` and `lint_browser_metrics_schema.js` if the schema
      uses a keyword or construct outside the supported subset: `type`, `const`, `enum`,
      `required`, `properties`, `additionalProperties`, `pattern`, `minLength`, `maxLength`,
      `minimum`, `maximum`, and `items`. `$ref`, `oneOf`, `format`, and other keywords are not
      interpreted by the local artifact validator. The `Lint browser schemas` CI step enforces
      this subset; the `jsonschema` meta-check separately proves both schema documents are
      well-formed.
- [ ] Apply the same versioning rules to `preview_browser_summary.schema.json`. Bump its
      `x-schema-version` when the preview JSON changes incompatibly, keep `schema_version` in
      `preview_browser_summary.js` in sync, and update `validate_preview_browser_summary.js` for
      outcome-specific fields.
- [ ] Run the browser schema meta-check (the `Validate browser schemas` CI step) and validate
      generated artifacts:
      `node samenerp/test/browser/validate_browser_metrics.js <browser-metrics.json>` and
      `node samenerp/test/browser/validate_preview_browser_summary.js <preview-summary.json>`.
- [ ] Run the browser test, then update the artifact documentation and changelog.
