#!/usr/bin/env bash
# scripts/ci_tiers.sh — which tiers of ./ci.sh does a diff actually require?
#
# Prints a comma-separated tier list suitable for SAMEN_CI_TIERS, or `all` when it CANNOT vouch
# for the change in front of it.
#
# THE CONTRACT, in one sentence: this narrows a gate, so every answer it gives is the WIDEST
# defensible one, and the moment it is unsure it answers `all` — i.e. it refuses to narrow, it
# never refuses to check. `all` is the safe answer; a wrong subset is the only dangerous one.
#
# WHY IT NARROWS AT ALL. The root gate is a sequence of independent tiers and costs ~90 minutes on
# a Windows checkout. A change confined to one host does not need the other four hosts' gates, and
# the difference decides whether an operator runs a deploy gate or waits it out.
#
# WHAT MAKES AN ANSWER WIDEST-DEFENSIBLE (each rule is a dependency, not a guess):
#   * samen_core/**            ⇒ `all`. Every app, package and probe path-deps the kernel, so a
#                                kernel change can break any consumer — there is no safe subset.
#   * samen_web/**             ⇒ web + every host. driftwood/pawchart/samenerp path-dep it (demo
#                                does not, but it is kept in rather than trusted to stay out).
#   * samen_resend/**          ⇒ resend + samenerp (samenerp path-deps it — the only adapter any
#                                host depends on; the other four are standalone).
#   * spikes/**                ⇒ spikes only (frozen standalone mix projects).
#   * README.md, CLAUDE.md,
#     docs/**                  ⇒ core. samen_core's own suite READS them (doc_commands / doc_recipes /
#                                gen_app), so a docs edit is a kernel-suite change. This is not
#                                hypothetical: a README fence broke AC-G10-1/2 and the gate caught it.
#   * scripts/**, .github/**,
#     root tooling             ⇒ nothing beyond the baseline (no tier covers tooling; the harness
#                                regressions below exercise scripts/), except gen_probe_guard.sh,
#                                which drives the generator probes ⇒ gen.
#   * anything else            ⇒ `all`. A path this script does not recognise is a path it cannot
#                                reason about; new top-level dirs land here by design.
#
# BASELINE, always added to any narrowed set: `harness` (the two ~1s–2min regressions that pin the
#   sabotage selectors — the tooling that certifies everything else) and `verifiers` (the
#   whole-tree verifiers, which scan hosts and packages from outside them). Both are cheap next to
#   any app gate, and both are exactly the cross-cutting checks a per-app diff is most likely to
#   break invisibly.
#
# Usage: scripts/ci_tiers.sh [--repo <path>] [--since <sha>] <target-sha>
#   --repo  the checkout to diff (default: this script's repo) — exists so the mapping can be
#           asserted against throwaway fixture repos by scripts/ci_tiers_test.sh
#   stdout  the tier CSV, or `all`
#   stderr  the per-path reasoning (auditable: every path, and why the set is what it is)
#   exit    0 always when an answer was produced; 2 on usage error
#
# Callers: scripts/deploy.sh (the only one that relies on a narrowed set). CI runs `all` via ci.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINCE=""
TARGET=""
MAX_PATHS_REPORTED=40

note() { printf '[ci-tiers] %s\n' "$*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^# Callers:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      SINCE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      note "unknown argument: $1"
      usage
      exit 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

[[ -n "$TARGET" ]] || { note "missing <target-sha>"; usage; exit 2; }

# `all` is the answer for every "I cannot vouch" path below — one helper, so no branch forgets it.
answer_all() { # answer_all <reason>
  note "⇒ all: $1"
  echo "all"
  exit 0
}

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || answer_all "not a git checkout"

TARGET_SHA="$(git -C "$REPO_ROOT" rev-parse --quiet --verify "${TARGET}^{commit}" 2>/dev/null)" \
  || answer_all "target '$TARGET' does not resolve to a commit"
[[ -n "$TARGET_SHA" ]] || answer_all "target '$TARGET' does not resolve to a commit"

[[ -n "$SINCE" ]] || answer_all "no --since given, so there is no baseline to diff against"
SINCE_SHA="$(git -C "$REPO_ROOT" rev-parse --quiet --verify "${SINCE}^{commit}" 2>/dev/null)" \
  || answer_all "baseline '$SINCE' does not resolve to a commit"

# A baseline that is not an ancestor of the target is a rewritten/divergent history: the set of
# changes is not a simple diff, so nothing can be excluded.
git -C "$REPO_ROOT" merge-base --is-ancestor "$SINCE_SHA" "$TARGET_SHA" 2>/dev/null \
  || answer_all "baseline $(git -C "$REPO_ROOT" rev-parse --short "$SINCE_SHA") is not an ancestor of $(git -C "$REPO_ROOT" rev-parse --short "$TARGET_SHA") (rewritten history?) — the change set is not a diff"

# all_reason <path> — WHY this path forces the full gate. The two cases are different decisions and
# must never be reported as one: the kernel is reasoned about and the answer is `all` because every
# consumer path-deps it, whereas an unrecognised path has no rule at all. Telling an operator the
# kernel "is not a path this selector can reason about" invites the one edit that would break the
# mapping — a finer rule for `samen_core/*` — so the reason names the dependency instead.
all_reason() {
  case "$1" in
    samen_core/*)
      printf '%s is the kernel: every app, adapter, spike and probe path-deps it, so no subset can be safe\n' "$1"
      ;;
    *)
      printf '%s matches no rule this selector can vouch for\n' "$1"
      ;;
  esac
}

map_path() { # prints the tiers a path requires; "ALL" = full gate; "" = baseline only
  case "$1" in
    samen_core/*) echo "ALL" ;;
    samen_web/*) echo "web demo driftwood pawchart samenerp" ;;
    spikes/*) echo "spikes" ;;
    samen_resend/*) echo "resend samenerp" ;;
    samen_stripe/*) echo "stripe" ;;
    samen_postmark/*) echo "postmark" ;;
    samen_ses/*) echo "ses" ;;
    samen_anthropic/*) echo "anthropic" ;;
    demo/*) echo "demo" ;;
    driftwood/*) echo "driftwood" ;;
    pawchart/*) echo "pawchart" ;;
    samenerp/*) echo "samenerp" ;;
    scripts/gen_probe_guard.sh) echo "gen" ;;
    README.md | CLAUDE.md | docs/*) echo "core" ;;
    scripts/* | .github/* | .freebuff/* | .gitignore | ci.sh | ci-fast.sh) echo "" ;;
    *) echo "ALL" ;;
  esac
}

FILES="$(git -C "$REPO_ROOT" diff --name-only "$SINCE_SHA" "$TARGET_SHA" 2>/dev/null)"
if [[ -z "$FILES" ]]; then
  answer_all "no files differ between $(git -C "$REPO_ROOT" rev-parse --short "$SINCE_SHA") and $(git -C "$REPO_ROOT" rev-parse --short "$TARGET_SHA") — there is nothing to narrow on (a redeploy of the same commit still runs the whole gate)"
fi

AFFECTED=""
count=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  count=$((count + 1))
  tiers="$(map_path "$path")"
  if [[ "$tiers" == "ALL" ]]; then
    note "  $path ⇒ FULL GATE"
    answer_all "$(all_reason "$path")"
  fi
  [[ -n "$tiers" ]] && AFFECTED="$AFFECTED $tiers"
  if (( count <= MAX_PATHS_REPORTED )); then
    note "  $path ⇒ ${tiers:-<baseline only>}"
  fi
done <<<"$FILES"
(( count > MAX_PATHS_REPORTED )) && note "  … $((count - MAX_PATHS_REPORTED)) more path(s)"

# Baseline: the fast cross-cutting regressions. Sorted, de-duplicated, comma-joined.
CSV="$(printf '%s\n' harness verifiers $AFFECTED |
  tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd, -)"

note "$count path(s) since $(git -C "$REPO_ROOT" rev-parse --short "$SINCE_SHA"); narrowed to: $CSV"
echo "$CSV"
