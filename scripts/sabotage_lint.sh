#!/usr/bin/env bash
# scripts/sabotage_lint.sh — fast header preflight for scripts/sabotages/*.patch.
#
# Checks EVERY patch's APP/TEST_FILES/MUST_FAIL headers up front, before any
# patch is applied. A missing header can never silently swallow the remainder
# of the sabotage harness run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

shopt -s nullglob
patches=("$SABOTAGE_DIR"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
  echo "SABOTAGE LINT: FAILED — no patches found in $SABOTAGE_DIR"
  exit 1
fi

# Parse all files in one process. The former implementation spawned three sed
# processes per patch; on Git Bash that made the supposedly instant preflight
# scale poorly enough to time out before selection was even evaluated.
awk '
  function report_missing(file, missing) {
    if (missing != "") {
      sub(/^.*[\\/]/, "", file)
      print "SABOTAGE LINT: " file " — missing header(s):" missing
      bad++
    }
  }
  FNR == 1 {
    if (seen) {
      missing = ""
      if (!have_app) missing = missing " APP"
      if (!have_test) missing = missing " TEST_FILES"
      if (!have_fail) missing = missing " MUST_FAIL"
      report_missing(file, missing)
    }
    file = FILENAME
    have_app = have_test = have_fail = 0
    total++
    seen = 1
  }
  /^# APP: / && length($0) > 8 { have_app = 1 }
  /^# TEST_FILES: / && length($0) > 14 { have_test = 1 }
  /^# MUST_FAIL: / && length($0) > 13 { have_fail = 1 }
  END {
    missing = ""
    if (!have_app) missing = missing " APP"
    if (!have_test) missing = missing " TEST_FILES"
    if (!have_fail) missing = missing " MUST_FAIL"
    report_missing(file, missing)
    if (bad > 0) {
      print ""
      print "SABOTAGE LINT: FAILED — " bad " of " total " patch(es) missing required headers"
      exit 1
    }
    print "SABOTAGE LINT: ALL PASSED (" total " patches, headers present)"
  }
' "${patches[@]}"
