# Sabotage harness certification — 344 patches

The adversarial tier's own certification record: for every patch in `scripts/sabotages/`, did its
named tests actually FLIP under the sabotage, and did the replay tree come back byte-exact? Every
number below comes from the harness's own per-patch output (`flip confirmed: <named test>`,
`restore: byte-exact (sha-256 verified)`, `SABOTAGE HARNESS: ALL PASSED`), not from inspection.

Raw logs are gitignored scratch under `.sabotage-parallel/logs/` (same posture as the dogfood
campaign's `_orch/`: this doc is the tracked pointer to that evidence).

## Run: 2026-10-16 · HEAD `1174b116`

`1174b116` (*fix(ci): pin the pool width wherever the intra harness asserts a LAYOUT*) on top of
`0daa098e` (*feat(tenant): make the shared chrome structural, not a convention every page repeats* —
the tenant-LiveView migration this run certifies against). Host: the local 8 GB Windows box,
PostgreSQL 18 in the `samenpg` container, harness driven at the parallel driver's documented
MINGW/MSYS pool width (2).

| | |
|---|---|
| patches in the harness | **344** |
| certified (named tests flipped **and** restore byte-exact) | **343** |
| uncertified | **1** — `336-multinode-oban-unique-dedup-declaration-dropped.patch`, unverifiable on this host (below) |
| patches whose named tests stopped flipping | **0** |
| patches that failed their byte-exact restore | **0** |

Per app: `samen_core 175/176` · `samen_web 130/130` · `driftwood 17/17` · `pawchart 13/13` ·
`samenerp 3/3` · `demo 3/3` · `samen_stripe 1/1` · `samen_postmark 1/1`.

Supporting counts from that run's logs: **552** named-test confirmations · **343** byte-exact
restores · **24** `ALL PASSED` verdict lines (9 slices + 15 chunks) · **26** `main checkout:
byte-exact` assertions · `scripts/sabotage_residue.sh` clean at the end (no patch left applied
anywhere; no tracked file in the main checkout changed).

### Slice and chunk verdicts

| slice | app | range | selected | result |
|---|---|---|---|---|
| `samen_core` | samen_core | 1-118 | 59 | ALL PASSED |
| `samen_core-2` | samen_core | 119-251 | 59 | 20 certified, then a host-level setup failure at 198 → remainder replayed in chunks |
| `samen_core-3` | samen_core | 252-340 | 58 | 0 certified, then a host-level setup failure at 252 → remainder replayed in chunks (336 excluded) |
| `samen_web` | samen_web | 5-137 | 65 | ALL PASSED |
| `samen_web-2` | samen_web | 138-344 | 65 | ALL PASSED |
| `pawchart` | pawchart | 23-334 | 13 | ALL PASSED |
| `driftwood` | driftwood | 17-333 | 17 | ALL PASSED |
| `demo` | demo | 21-52 | 3 | ALL PASSED |
| `samenerp` | samenerp | 322-331 | 3 | ALL PASSED |
| `samen_stripe` | samen_stripe | 29-29 | 1 | ALL PASSED |
| `samen_postmark` | samen_postmark | 301-301 | 1 | ALL PASSED |

Chunk tail: `finish.log` — 18 rounds, 17 chunks, 15 `ALL PASSED`, nothing quarantined for a
patch-level reason.

### The one uncertified patch

`336-multinode-oban-unique-dedup-declaration-dropped.patch` targets
`test/multinode/oban_multinode_test.exs` with `ENV: SAMEN_MULTINODE=1`. Its `setup_all` dies before
any test runs:

```text
0) Samen.MultiNode.ObanMultiNodeTest: failure on setup_all callback, all tests have been invalidated
   ** (RuntimeError) could not start distribution (is epmd up?):
      {{:shutdown, {:failed_to_start_child, :net_kernel, {:EXIT, :nodistribution}}}, ...}
      (samen_core 0.1.0) test/support/multinode/harness.ex:99: Samen.MultiNode.Harness.ensure_distribution!/0
Result: 0 tests, 3 invalid
```

Reproduced **with and without the sabotage** — `evidence-336.log` (the harness replaying 336 alone,
which correctly REFUSED a green rather than reporting a vacuous one) and
`evidence-336-unpatched.log` (`SAMEN_MULTINODE=1 mix test test/multinode/oban_multinode_test.exs`
on a pristine tree, exactly as the opt-in tier in `ci.sh` runs it) fail identically.
`:net_kernel.start([:"samen_primary@127.0.0.1", :longnames])` cannot start Erlang distribution on
this machine, so the L4 two-node tier's three named tests never execute here with or without a
patch. That is a host limitation, not a regression, and the patch itself is applicable: the
structural preflight (residue / EOLs / apply / anchors) passed for all 344 patches. Certifying 336
needs a host where distribution boots (the `SAMEN_MULTINODE=1` tier).

### Host-level interruptions (all classified; none patch-level)

The box ran with ~0.5 GB free RAM for most of the window, which is what the four surviving
`SABOTAGE HARNESS: FAILED` lines are — each inside a slice's own `test_helper` setup, before any
test executed, and since `scripts/sabotage.sh` is fail-fast each one ended its invocation:

| where | patch reached | cause |
|---|---|---|
| `samen_core-2` (119-251) | 198 | `storage_up failed: [Ecto.Adapters.SQL.Supervisor] connection not available and request was dropped from queue after 4000ms` (`test_helper.exs:32`) |
| `samen_core-3` (252-340) | 252 | `storage_up failed: {:error, "command timed out"}` — `CREATE DATABASE` under memory pressure |
| chunk 204-209 | 205 | same class; attempt 2 replayed the chunk green |
| chunk 305-316 | 313 | same class; attempt 2 replayed the chunk green |

Remainders were replayed in ≤10-patch chunks (up to 3 attempts each, never two chunks sharing a
replay tree or database). One chunk, `332-336`, exhausted its attempts — leaving 336 as the only
uncertified patch.

### Reconciliation (three independent derivations of 343)

1. Per log, the harness's own `ALL PASSED (N of 344 …)` count equals the number of certified patch
   blocks in that log — 24 verdict lines, 0 mismatches.
2. Those counts sum to 321; plus the certified patches inside the two invocations that died
   host-level and were finished in chunks (`samen_core-2` 20, the quarantined `332-336` chunk 2) =
   **343**; plus `336` = **344**.
3. The sum of per-log certified blocks is **343** and no patch name appears in two logs, so the
   union of slice/chunk coverage is exact and not double-counted.

The harness's five regression signals occur **0** times in that run's logs:
`suite PASSED under sabotage` (vacuous gate) · `named test did not flip` ·
`SHA mismatch after revert` · `revert failed` · `the MAIN checkout changed`.

### How to re-run

The structural preflight is `scripts/sabotage_preflight.sh` (read-only). A full serial
certification is `SAMEN_SABOTAGE=1 ./ci.sh`; the parallel sweep is
`scripts/sabotage_parallel.sh` (its default width on MINGW/MSYS is 2), and a single app is
`scripts/sabotage.sh --app <app> --range <lo>-<hi>`. Per-slice trees and databases stay warm for
cheap reruns: reclaim them with `rm -rf .sabotage-parallel && git worktree prune` and
`dropdb --if-exists <app>_test_sab<N>`.
