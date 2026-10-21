# Samenerp ci.sh bootstrap (run under MIX_ENV=test): recreate + migrate the
# samenerp_test DB so the standalone verifier tasks (which query the LIVE DB) have a
# fully-migrated schema. Idempotent.

alias Samenerp.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "samenerp_keystore_ci_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

# Hardened against ci.sh's final tier, where the app gates run CONCURRENTLY against one local
# Postgres: a contended DROP/CREATE can outlast Ecto's DEFAULT 15s run_query timeout, so the
# old code's hard-matched `:ok = storage_up(...)` crashed on {:error, :already_up} (observed
# 2026-10-05). That hardening now lives in ONE place — the shared tolerant boot below, which
# gives the storage ops a generous timeout, tolerates the benign "already" answers, VERIFIES
# the final state with retries, and raises on anything genuinely wrong.
Samen.TestDb.boot!(Repo)

IO.puts("samenerp ci bootstrap: DB migrated")
