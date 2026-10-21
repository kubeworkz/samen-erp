# Driftwood ci.sh bootstrap (run under MIX_ENV=test): recreate + migrate the
# driftwood_test DB and register the reviewed non_pii! rows, so the standalone
# verifier tasks (which query the LIVE DB) have a fully-migrated schema and the
# non_pii registry the pii_classify verifier reads. Idempotent.

alias Driftwood.Repo

# Per-run KMS key store (mirrors the test helper) so vault/shred paths are wired.
kms_key_dir =
  Path.join(System.tmp_dir!(), "driftwood_keystore_ci_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

# Tolerant boot (create-if-absent + migrate): the root gate runs sibling app gates
# concurrently against one Postgres, so a contended DROP/CREATE must not crash the bootstrap.
# See `Samen.TestDb`.
Samen.TestDb.boot!(Repo)

# The `aud_event` migration creates only the FIXED launch-month partition; the daily
# `Samen.AuditEvent.PartitionManager` Oban job that rolls partitions forward in production does
# not run under this bootstrap, so on a wall clock past the launch month the current month's
# partition is absent — and the gamedays/verifiers that write audit rows on the freshly-migrated
# DB would hit "no partition of relation aud_event". Provision current + upcoming months up front
# (forward-safe; the ensure is idempotent — exactly what the daily job does).
Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(Repo, Date.utc_today(), 2)

:ok = Driftwood.NonPiiSetup.register_all()

IO.puts("driftwood ci bootstrap: DB migrated + non_pii! registered")
