#!/usr/bin/env bash
# prod_compile_gate.sh — "does the release still build?" — the MIX_ENV=prod gate.
#
# WHY THIS EXISTS (incident 2026-09-25 → 2026-09-28)
# ---------------------------------------------------------------------------
# `main` was green in CI for four days while EVERY production deploy failed
# `docker build`. The live container kept serving image `3a661fe` built
# 2026-09-24 from `1faaed7` — 14 commits and 4 days behind main — because the
# Dockerfile's first build step died every time:
#
#   cd samen_core && mix deps.get --only prod && mix compile
#   == Compilation error in file lib/samen/ai/assistant_conversation.ex ==
#   Cannot accept [:transcript], because they are not attributes.
#   FAIL: docker build failed — old container still running
#
# Root cause: `samen_core/config/config.exs` registered the :test-support
# domains (`SamenCore.Support.*` — one fixture domain per scope — plus
# `Core.Ctx`) under EVERY env, including :prod, where `elixirc_paths(:prod)` is
# `["lib"]` and `test/support` is never compiled. That raised ~222
# `ArgumentError: SamenCore.Support.Crm is not a Spark DSL module` exceptions
# during resource verification, which derailed Spark's verification pass — so
# `accept` no longer saw the attribute `MaterializePii` had materialised, and
# the compile died on a resource that is perfectly valid in :test.
#
# WHY NO EXISTING GATE SAW IT: ci.sh and ci-fast.sh compile in MIX_ENV=test
# only (that is what `mix test --warnings-as-errors` is). In :test the
# test-support modules ARE compiled and the :dev/:test dep set is what is
# loaded, so this break is structurally invisible — a green CI said nothing
# about whether the release builds. The first thing that ever compiles in :prod
# was the deploy: the worst possible moment to find out, and it fails *silently*
# in the sense that production simply keeps serving the old image while `main`
# moves on.
#
# WHAT THIS DOES: replays the Dockerfile's `build` stage exactly — each app in
# dependency order, `MIX_ENV=prod`, the :prod-only dep set, then the OTP release:
#
#   cd samen_core && mix deps.get --only prod && mix compile
#   cd samen_web  && mix deps.get --only prod && mix compile
#   cd samenerp   && mix deps.get --only prod && mix compile
#   cd samenerp   && mix release samenerp
#
# Three deliberate differences from the Dockerfile:
#
#   1. the app's own compiled output is deleted before every compile
#      (`rm -rf <build root>/<app>/lib/<app>`), so each run recompiles OUR
#      sources from source and a stale beam can never hide a :prod-only break
#      (the failing file existed only in the newer tree). This matters because
#      Mix does NOT recompile on a config/*.exs change — verified: `mix compile`
#      after editing config.exs prints nothing and touches no beam — and a
#      config change is exactly the incident class. Deps are compiled once per
#      build root and reused (`--force` would redo all 731 of samen_core's
#      files instead of its 131); a fresh root, which is what CI always has,
#      compiles them anyway.
#   2. `MIX_BUILD_PATH` points at a dedicated scratch root (`.prod_gate/<app>`,
#      gitignored) so the gate never touches the developer's `_build/test` or
#      `_build/dev`, never races the sabotage harness's throwaway worktree, and
#      cannot poison a byte-exact restore.
#   3. a POST-COMPILE REGISTRY SCAN (`scan_prod_absent_dsl`) that turns the
#      silent half of the incident into a hard failure: any `config/*.exs`
#      registering a module that this :prod build cannot compile is reported
#      even when the compile itself only *warns*. This is the part that makes
#      the verdict deterministic instead of Elixir-version-dependent — the
#      2026-09 break was a hard compile error in the Docker image
#      (Elixir 1.20.2 / OTP 27 / Alpine) and a warning-only verification error
#      on a newer local toolchain.
#
# COST: a cold build root ≈ 9–10 min (that IS the deploy build: every dep
# fetched and compiled once). Warm ≈ 4–5 min, paid only when the tree changed —
# an unchanged tree short-circuits in about a second off the recorded stamp (see
# below). Needs no database and no network beyond `mix deps.get`.
# SAMEN_PROD_GATE_FORCE=1 ignores the stamp and rebuilds.
#
# WIRED INTO: the `prod` job in .github/workflows/ci.yml — on every pull request
# and every push, in parallel with fast/full. Deliberately NOT part of ci.sh /
# ci-fast.sh / the `full` job: those are the local inner loop, and a cold
# `mix deps.get --only prod` build would roughly double the root gate's
# wall-clock for a verdict this job already gives on both events. Run it directly
# (`bash scripts/prod_compile_gate.sh`) when you want the local answer.
#
# Exits non-zero on the first failure; ends `==> PROD COMPILE GATE: ALL PASSED`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The scratch build root — one build path per app, mirroring the Dockerfile's
# per-app `_build/prod` (each package compiles its own, the next picks it up via
# path deps). Override with SAMEN_PROD_GATE_ROOT for a shared/cached root.
BUILD_ROOT="${SAMEN_PROD_GATE_ROOT:-$REPO_ROOT/.prod_gate}"
RELEASE_ROOT="$BUILD_ROOT/samenerp/rel/samenerp"
STAMP="$BUILD_ROOT/.gate-stamp"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/samen_prod_gate.XXXXXX")"

# Dependency order — identical to the Dockerfile's three RUN steps.
APPS=(samen_core samen_web samenerp)

fail() {
  echo ""
  echo "==> PROD COMPILE GATE: FAILED — $1"
  exit 1
}

dump_log() {
  local app="$1" log="$2"
  echo ""
  echo "==> ----- begin $app :prod build log ($log) -----"
  cat "$log"
  echo "==> ----- end $app :prod build log -----"
}

# --- the "nothing to do" stamp -------------------------------------------------
# The compiles below are forced, so re-running on an unchanged tree would burn
# ~7 minutes to re-derive a verdict already known. Record the tree fingerprint
# and the tree's verdict together: only a tree with the SAME fingerprint as the
# last green run short-circuits.
#
# The fingerprint covers git's view of the whole repo — HEAD, every tracked
# modification (config/*.exs included: a config-only edit must NOT short-
# circuit), and the contents of untracked files (`git status` alone reports
# untracked files by name, so a new file's contents are hashed explicitly).
# Ignored paths (the build root itself, deps/, _build/) are excluded, so the
# gate never invalidates its own cache.
tree_fingerprint() {
  {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "no-git"
    git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -z 2>/dev/null |
      xargs -0 -r git -C "$REPO_ROOT" hash-object 2>/dev/null || true
  } | sha256sum | cut -d' ' -f1
}

FINGERPRINT="$(tree_fingerprint)"

if [ "${SAMEN_PROD_GATE_FORCE:-0}" != "1" ] &&
  [ -f "$STAMP" ] &&
  [ -x "$RELEASE_ROOT/bin/samenerp" ] &&
  [ "$(cat "$STAMP")" = "$FINGERPRINT" ]; then
  echo "==> Prod compile gate: tree unchanged since the last green :prod build (${FINGERPRINT:0:12}) — reusing it."
  echo "    (SAMEN_PROD_GATE_FORCE=1 ./scripts/prod_compile_gate.sh rebuilds every app from source.)"
  echo ""
  echo "==> PROD COMPILE GATE: ALL PASSED (${#APPS[@]} apps built in MIX_ENV=prod from source; samenerp release assembled)"
  exit 0
fi

# --- registry honesty: no config may name a module :prod does not compile ----
# The 2026-09 root cause, made deterministic. A `SamenCore.Support.Crm is not a
# Spark DSL module` exception means something (an `ash_domains` / `extra:`
# registry, typically a config.exs) referenced a module this :prod build never
# produced. Warning-only on some toolchains, fatal on others — either way the
# release is assembled from a config that lies, so the gate fails closed.
#
# The module name is checked against the build root's ebin dirs rather than a
# `test/` path heuristic: a host domain that legitimately exists in :prod (e.g.
# `Samenerp.Billing`, named while a path dep compiles before it is itself
# compiled — the samen_core dep inside the samenerp build verifies the HOST's
# `config :samen_core, :ash_domains` before the host's own lib/ compiles, and
# emits exactly these `not a Spark DSL module` lines) DOES have a beam by the
# time the compile finishes and is therefore fine; a test-support fixture never
# has one. NB: Elixir writes beam files as `Elixir.<Module>.beam`, so both
# names must be probed — matching only `<Module>.beam` flags every Elixir
# module as absent (that false positive failed this gate's first CI run,
# 2026-09-28, while the samenerp compile itself was green).
scan_prod_absent_dsl() {
  local app="$1" log="$2"
  local -a offenders=()
  local mod

  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    if ! compgen -G "$BUILD_ROOT/$app/lib/*/ebin/$mod.beam" >/dev/null &&
      ! compgen -G "$BUILD_ROOT/$app/lib/*/ebin/Elixir.$mod.beam" >/dev/null; then
      offenders+=("$mod")
    fi
  done < <(
    grep -oE '`[A-Z][A-Za-z0-9_.]*` is not a Spark DSL module' "$log" 2>/dev/null |
      sed -E 's/^`//; s/` is not a Spark DSL module$//' |
      sort -u || true
  )

  if [ "${#offenders[@]}" -gt 0 ]; then
    dump_log "$app" "$log"
    echo ""
    echo "==> $app: :prod registered ${#offenders[@]} module(s) that this :prod build cannot compile:"
    printf '      %s\n' "${offenders[@]}"
    echo ""
    echo "    A config/*.exs names a module that only exists outside lib/ (a"
    echo "    test/support fixture domain such as SamenCore.Support.* / Core.Ctx,"
    echo "    excluded by elixirc_paths(:prod) = [\"lib\"]). The deploy build dies on"
    echo "    exactly this (2026-09-25 → 09-28: four days of failed deploys). Move the"
    echo "    registration behind \`if config_env() != :prod do ... end\`, or point it at a"
    echo "    module :prod actually compiles."
    fail "$app's :prod config references a module :prod never compiles (see above)."
  fi
}

echo "==> Prod compile gate: MIX_ENV=prod build of ${APPS[*]} + the samenerp release (deploy parity)"
echo "    build root: $BUILD_ROOT"

# The loop below `rm -rf`s <app>/lib/<app> inside the build root; never let a
# mis-set SAMEN_PROD_GATE_ROOT point that at something real.
case "$BUILD_ROOT" in
  "" | "/" | "$REPO_ROOT" | "$REPO_ROOT/") fail "refusing to clean build root '$BUILD_ROOT'" ;;
esac

for app in "${APPS[@]}"; do
  log="$LOG_DIR/$app.log"
  echo ""
  echo "==> [prod] $app: mix deps.get --only prod && mix compile (project, from source)"

  if ! (
    cd "$REPO_ROOT/$app"
    MIX_ENV=prod MIX_BUILD_PATH="$BUILD_ROOT/$app" mix deps.get --only prod
    rm -rf "$BUILD_ROOT/$app/lib/$app"
    MIX_ENV=prod MIX_BUILD_PATH="$BUILD_ROOT/$app" mix compile
  ) >"$log" 2>&1; then
    dump_log "$app" "$log"
    fail "the MIX_ENV=prod build of $app FAILED — this commit cannot be deployed. Reproduce with: cd $app && MIX_ENV=prod mix compile"
  fi

  scan_prod_absent_dsl "$app" "$log"

  files="$(grep -oE 'Compiling [0-9]+ files?' "$log" | tail -1 || true)"
  echo "==> [prod] $app: PASSED (${files:-project recompiled}; 0 references to :prod-absent modules)"
done

# --- the release itself (the Dockerfile's last build step) -------------------
# `mix release samenerp` produces the artifact the container ships
# (`_build/prod/rel/samenerp`, COPYed into the runtime stage). Compiling alone
# would miss a release-assembly break (a missing config/runtime.exs, a bad
# releases.exs, an application the release cannot assemble).
echo ""
echo "==> [prod] samenerp: mix release samenerp --overwrite (the Dockerfile's release step)"
release_log="$LOG_DIR/samenerp-release.log"
if ! (
  cd "$REPO_ROOT/samenerp"
  MIX_ENV=prod MIX_BUILD_PATH="$BUILD_ROOT/samenerp" mix release samenerp --overwrite
) >"$release_log" 2>&1; then
  dump_log "samenerp (release)" "$release_log"
  fail "the samenerp OTP release did not assemble — the deploy would fail at the release step."
fi

# Fail closed on a silent no-op: a "release" that wrote no start script ships nothing.
if [ ! -x "$RELEASE_ROOT/bin/samenerp" ]; then
  cat "$release_log"
  fail "mix release samenerp exited 0 but $RELEASE_ROOT/bin/samenerp is missing — nothing to ship."
fi
if ! compgen -G "$RELEASE_ROOT/releases/*/samenerp.rel" >/dev/null; then
  cat "$release_log"
  fail "the release is missing releases/*/samenerp.rel — a partial release assembled."
fi
echo "==> [prod] samenerp release: PASSED ($RELEASE_ROOT)"

# Verdict recorded — only a tree with this exact fingerprint may short-circuit.
mkdir -p "$BUILD_ROOT"
printf '%s' "$FINGERPRINT" >"$STAMP"

rm -rf "$LOG_DIR"

echo ""
echo "==> PROD COMPILE GATE: ALL PASSED (${#APPS[@]} apps built in MIX_ENV=prod from source; samenerp release assembled)"
