# Samenerp ci.sh bootstrap (run under MIX_ENV=test): recreate + migrate the
# samenerp_test DB so the standalone verifier tasks (which query the LIVE DB) have a
# fully-migrated schema. Idempotent.

alias Samenerp.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "samenerp_keystore_ci_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

_ = Ecto.Adapters.Postgres.storage_down(Repo.config())
:ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

IO.puts("samenerp ci bootstrap: DB migrated")
