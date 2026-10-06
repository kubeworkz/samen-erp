# Samenerp ci.sh bootstrap (run under MIX_ENV=test): recreate + migrate the
# samenerp_test DB so the standalone verifier tasks (which query the LIVE DB) have a
# fully-migrated schema. Idempotent.

alias Samenerp.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "samenerp_keystore_ci_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

# Hardened against ci.sh's final tier, where 5 app gates run CONCURRENTLY against one local
# Postgres: a contended DROP/CREATE can outlast Ecto's DEFAULT 15s run_query timeout. The
# old code discarded the storage_down result and hard-matched `:ok = storage_up(...)`, so a
# timed-out drop (old DB still present) made storage_up return {:error, :already_up} and
# MatchError-killed the gate (observed 2026-10-05). Give the storage ops a generous timeout,
# tolerate benign results, and VERIFY the final state with retries before migrating.
cfg = Keyword.merge(Repo.config(), timeout: 60_000)

case Ecto.Adapters.Postgres.storage_down(cfg) do
  :ok -> :ok
  {:error, :already_down} -> :ok
  {:error, reason} -> IO.puts("samenerp ci bootstrap: storage_down -> #{inspect(reason)}; reconciling")
end

ensure_up = fn
  _retry, 0 ->
    raise "samenerp ci bootstrap: database is not up after retries"

  retry, attempts ->
    up_result =
      case Ecto.Adapters.Postgres.storage_up(cfg) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, reason} -> {:error, reason}
      end

    # storage_status/1 answers with BARE :up | :down in this ecto_sql version; normalize
    # both contract shapes so a version bump can't silently break the guard.
    status =
      case Ecto.Adapters.Postgres.storage_status(cfg) do
        state when state in [:up, {:ok, :up}] -> :up
        state when state in [:down, {:ok, :down}] -> :down
        other -> {:error, other}
      end

    case {status, up_result} do
      {:up, _} ->
        :ok

      {other, _} when attempts > 1 ->
        # {:down, _}: a timed-out DROP may land between storage_up's existence check and
        # now — retry. {:error, _}: storage_status itself flaked — retry too.
        IO.puts("samenerp ci bootstrap: state #{inspect(other)} (#{inspect(up_result)}); retrying")
        Process.sleep(500)
        retry.(retry, attempts - 1)

      {other, _} ->
        raise "samenerp ci bootstrap: database not up (status #{inspect(other)}, storage_up #{inspect(up_result)})"
    end
end

:ok = ensure_up.(ensure_up, 20)

{:ok, _} = Repo.start_link()
Ecto.Migrator.run(Repo, :up, all: true)

IO.puts("samenerp ci bootstrap: DB migrated")
