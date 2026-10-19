#!/usr/bin/env bash
# Pins the SCRATCH OWNERSHIP contract of scripts/gen_probe_guard.sh.
#
# WHY. `run_gen_probe` used to end every run with a blanket
# `rm -rf "$REPO_ROOT"/_gen_*_scratch*`. The probes share one repo root, so running two
# probes at once (or a probe while an orphaned one was still finishing) let one run delete
# the other's scratch app MID-RUN — observed three times on the post probe, each surfacing
# as a mysterious failure in the probe under test, not in the guard. The guard now creates
# THIS run's scratch dir itself (`mktemp -d _gen_probe_scratch.XXXXXX`), hands it to the
# probe as SAMEN_GEN_PROBE_SCRATCH, and removes exactly that path.
#
# WHAT THIS PROVES — against the REAL guard (sourced, not a reimplementation):
#   1. a sibling scratch dir, planted with the naming shape of a live concurrent probe,
#      SURVIVES the run untouched (marker bytes intact);
#   2. the probe really receives an owned scratch dir via SAMEN_GEN_PROBE_SCRATCH, can
#      write its app into it, and that dir is GONE after the guard returns;
#   3. no `_gen_probe_scratch.*` residue is left, and the registry stays byte-exact.
# NEGATIVE CONTROL — the same stub invoked RAW (`mix run`, no guard) exits 3 because no
# SAMEN_GEN_PROBE_SCRATCH exists: the positive handoff above is the guard's, not ambient,
# so assertions 1–3 cannot pass by accident.
#
# Usage: scripts/gen_probe_scratch_isolation_test.sh
# Exit:  0 only if every positive assertion holds AND the negative control reproduces the
#        missing-handoff failure. Never leaves scratch residue or a dirty registry.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$REPO_ROOT/samen_core/priv/abbrev_registry.json"

# Portable SHA-256 (Git Bash ships sha256sum, not the Perl-based shasum). A missing hasher
# must FAIL this proof, never leave PRISTINE_SHA empty — an empty-vs-empty comparison would
# make every registry assertion below vacuously true.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "FATAL: no SHA-256 hasher (sha256sum/shasum) available — cannot prove byte-exactness" >&2
    exit 1
  fi
}

# Elixir's `Path.expand` reports Windows drive paths (C:/...), bash uses /c/... — compare in
# the shell's own spelling.
to_shell_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s\n' "$1"
  fi
}

PRISTINE_SHA="$(sha256 "$REGISTRY")"
[[ -n "$PRISTINE_SHA" ]] || { echo "FATAL: empty pristine SHA" >&2; exit 1; }
OUTER_BACKUP="$(mktemp "${TMPDIR:-/tmp}/gen_probe_scratch_outer.XXXXXX")"
cp "$REGISTRY" "$OUTER_BACKUP"

# Naming shape of a LIVE probe's scratch dir (`_gen_post_scratch.<suffix>`), planted before
# the guarded run. `$$` keeps it unique against a real concurrent probe.
SIBLING="$REPO_ROOT/_gen_post_scratch.sibling$$"
STUB="$(mktemp "${TMPDIR:-/tmp}/gen_probe_scratch_stub.XXXXXX.exs")"

cleanup() {
  cp "$OUTER_BACKUP" "$REGISTRY" 2>/dev/null || true
  rm -f "$OUTER_BACKUP" "$STUB"
  rm -rf "$SIBLING"
}
trap cleanup EXIT

pass_count=0
fail_count=0

note() { echo "== $* =="; }
ok() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

# The stub stands in for a generated-app probe: it FAILS CLOSED when the guard did not hand
# it a scratch dir (exit 3), otherwise it writes an "app" into that dir.
cat >"$STUB" <<'ELIXIR'
case System.get_env("SAMEN_GEN_PROBE_SCRATCH") do
  nil ->
    IO.puts("STUB: no SAMEN_GEN_PROBE_SCRATCH in the environment")
    System.halt(3)

  dir ->
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stub-app.txt"), "generated app\n")
    IO.puts("STUB: scratch dir = #{dir}")
end
ELIXIR

mkdir -p "$SIBLING/app"
echo "another probe's live app" >"$SIBLING/app/marker.txt"
SIBLING_BYTES="$(cat "$SIBLING/app/marker.txt")"

note "guarded run: own scratch dir handed down, then removed; sibling untouched"
GUARD_OUT="$(
  REPO_ROOT="$REPO_ROOT" bash -c \
    "REPO_ROOT='$REPO_ROOT'; source '$REPO_ROOT/scripts/gen_probe_guard.sh'; run_gen_probe '$STUB' 'scratch isolation (guarded)'" 2>&1
)"
guard_code=$?
RUN_DIR="$(printf '%s\n' "$GUARD_OUT" | sed -n 's/^STUB: scratch dir = //p' | head -1)"
RUN_DIR_SHELL="$(to_shell_path "$RUN_DIR")"

if [[ "$guard_code" == 0 ]]; then
  ok "guarded run exited 0"
else
  bad "guarded run exited $guard_code (expected 0)"
  printf '%s\n' "$GUARD_OUT" | tail -20 | sed 's/^/    /'
fi

if [[ -n "$RUN_DIR" ]]; then
  ok "probe received SAMEN_GEN_PROBE_SCRATCH=$RUN_DIR"
else
  bad "probe never reported a SAMEN_GEN_PROBE_SCRATCH dir (guard handoff broken)"
fi

case "$RUN_DIR_SHELL" in
  "$REPO_ROOT"/_gen_probe_scratch.*) ok "handed-down dir is the guard's own _gen_probe_scratch.* dir" ;;
  "") : ;; # already failed above
  *) bad "handed-down dir '$RUN_DIR' is not a guard-owned _gen_probe_scratch.* dir" ;;
esac

if [[ -n "$RUN_DIR_SHELL" && ! -e "$RUN_DIR_SHELL" ]]; then
  ok "the run's own scratch dir was removed by the guard"
elif [[ -n "$RUN_DIR_SHELL" ]]; then
  bad "the run's own scratch dir survived: $RUN_DIR_SHELL"
fi

# Non-vacuity: the sibling must actually match the OLD blanket glob shape — otherwise
# surviving it would prove nothing about the sweep.
if ls -d "$REPO_ROOT"/_gen_*_scratch* 2>/dev/null | grep -Fxq "$SIBLING"; then
  ok "planted sibling matches the old blanket glob (surviving it is meaningful)"
else
  bad "planted sibling '$SIBLING' is not matched by _gen_*_scratch* — the proof would be vacuous"
fi

if [[ -f "$SIBLING/app/marker.txt" && "$(cat "$SIBLING/app/marker.txt")" == "$SIBLING_BYTES" ]]; then
  ok "a concurrent probe's scratch dir survived byte-intact ($SIBLING)"
else
  bad "the guard deleted/corrupted a concurrent probe's scratch dir ($SIBLING)"
fi

leftover="$(ls -d "$REPO_ROOT"/_gen_probe_scratch.* 2>/dev/null || true)"
if [[ -z "$leftover" ]]; then
  ok "zero _gen_probe_scratch.* residue"
else
  bad "residue left behind: $leftover"
fi

if [[ "$(sha256 "$REGISTRY")" == "$PRISTINE_SHA" ]]; then
  ok "registry byte-exact after the guarded run"
else
  bad "registry NOT byte-exact after the guarded run"
fi

note "negative control: the same stub RAW (no guard) must fail closed"
RAW_OUT="$(cd "$REPO_ROOT/samen_core" && mix run "$STUB" 2>&1)"
raw_code=$?
if [[ "$raw_code" == 3 ]] && printf '%s' "$RAW_OUT" | grep -q "no SAMEN_GEN_PROBE_SCRATCH"; then
  ok "raw mix run exits 3 (no handoff) — the guarded proof above is not a tautology"
else
  bad "raw mix run exited $raw_code without the missing-handoff marker (expected 3)"
  printf '%s\n' "$RAW_OUT" | tail -10 | sed 's/^/    /'
fi

# Nothing to sweep: the negative control exits before it creates anything, and the guarded
# run removed its own dir. Deliberately no `rm -rf _gen_probe_scratch.*` here — that is the
# exact glob this file exists to forbid.

echo ""
echo "== gen-probe scratch isolation: $pass_count passed, $fail_count failed =="
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
