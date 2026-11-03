defmodule Samen.TestDb do
  @moduledoc """
  The ONE tolerant database boot shared by every harness that owns its own database: the
  `priv/*_probe.exs` probes, the emitted `priv/ci_bootstrap.exs`, and the emitted
  `test/test_helper.exs`.

  `boot!/2` = quiesce any running pool → ensure the database exists → migrate it through a
  pool of its OWN → start the repo on its CONFIGURED pool. `ensure_up!/2` is the create step
  alone, for a caller that must do something BETWEEN create and migrate (e.g. samen_core's own
  test helper, which pre-checks the `pgvector` extension and fails with an actionable message
  instead of an opaque `CREATE EXTENSION` error).

  ## Why tolerance here is CORRECT, not a swallowed failure

  Every caller runs *after* another BEAM has just exited — the `mix test` VM whose pool is
  still closing its sessions, or a sibling `ci.sh` gate on the same Postgres. In that window
  `storage_down/1` legitimately answers `{:error, :being_accessed}` (or a pool timeout), and
  the `storage_up/1` that follows answers `{:error, :already_up}` because the database was
  never dropped. A harness that hard-matches `:ok = storage_up(...)` MatchError-kills on that
  benign race before it can assert anything (observed 2026-10-20: the PawChart and SamenERP
  anti-tautology probes died at their own boot line under the root gate).

  What every caller actually needs is a MIGRATED database, so:

    * a pool that is ALREADY RUNNING is stopped first, and the boot REFUSES (loudly) to drop
      a database under a pool its supervisor keeps restarting — see `stop_repo!/1`;
    * migrations run on a dedicated, non-sandbox pool (Ecto's minimum two connections), so a
      SQL Sandbox never answers the migrator's second connection with a redirect to its own
      busy proxy — see `migrate_on_its_own_pool!/2`;
    * the drop is BEST-EFFORT — it only converges the schema, and whatever survives is
      re-migrated by the caller anyway — but a drop that did not COMPLETE is retried until it
      does (see `drop_best_effort/2`: a `psql` timeout means the DROP is still running
      server-side, and it must not land after the create);
    * the create is RETRIED (20 × 500ms by default) until the database verifiably reports
      `:up`, tolerating both "already up" answers;
    * everything else RAISES — an uncreatable database, an exhausted retry budget, or an
      adapter that cannot manage storage at all stops the harness loudly with the adapter's
      own reason.

  This is a tolerant boot, never a silent bypass: it does not weaken a single assertion in the
  harness that calls it, and it never turns a real failure into a green run.
  """

  @default_timeout 60_000
  @default_attempts 20
  @retry_interval 500

  # DBConnection's default `:ownership_timeout` is 120s, and `Ecto.Migrator` holds ONE
  # checked-out connection — and the migration advisory lock on it — for the WHOLE run.
  # A host with a long migration history (samen_web: 89 versions, samenerp: 41) can exceed
  # that ceiling when the root gate's five app tiers migrate concurrently against one
  # Postgres: observed 2026-11-02, `samen_web_test` and `samenerp_test` both died at
  # 13:32:36 with `{:error, :rollback}` from `do_lock_for_migrations` after samenerp had
  # spent 102s on 31 versions. The fix is headroom for a legitimate long migrate, not a
  # weaker gate: every migration still runs, every assertion still fires.
  @default_ownership_timeout 300_000
  @drop_attempts 2

  # Ecto's own migration guard: "When migrations run, Ecto uses one connection to maintain a
  # lock and another to run migrations", and it raises for any pool smaller than this.
  @migration_pool_size 2

  @stop_timeout 30_000
  # A supervisor restarts a stopped child asynchronously; the boot waits this long after the
  # repo vanishes before concluding that nothing is going to bring it back.
  @restart_grace 100

  @typedoc "A repo module (the emitted harnesses) or an explicit repo config (a scratch DB)."
  @type repo_or_config :: module() | keyword()

  @doc """
  Bring the database up, tolerating the benign drop/create races described in the moduledoc.

  Accepts a repo module (as every emitted harness uses) or an explicit `config` keyword (as a
  verifier's scratch database does). Returns `:ok`; raises when the database cannot be brought
  up — never returns `{:error, _}`.

  ## Options

    * `:timeout` — per-storage-op timeout in ms (default `#{@default_timeout}`); a contended
      DROP/CREATE on a busy local Postgres can outlast Ecto's own 15s default.
    * `:attempts` — create retries before raising (default `#{@default_attempts}`).
  """
  @spec ensure_up!(repo_or_config(), keyword()) :: :ok
  def ensure_up!(repo_or_config, opts \\ [])

  def ensure_up!(repo, opts) when is_atom(repo) do
    ensure_up!(repo.config(), Keyword.put(opts, :adapter, repo.__adapter__()))
  end

  def ensure_up!(config, opts) when is_list(config) do
    adapter = Keyword.get(opts, :adapter, Ecto.Adapters.Postgres)
    config = Keyword.put_new(config, :timeout, Keyword.get(opts, :timeout, @default_timeout))
    attempts = Keyword.get(opts, :attempts, @default_attempts)

    # `function_exported?/3` does NOT load the module, and under `mix run --no-start` the
    # adapter is often not loaded yet — ensure it first, or a perfectly capable adapter would
    # be refused.
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :storage_up, 1) do
      _ = drop_best_effort(adapter, config)
      wait_until_up!(adapter, config, attempts, attempts)
    else
      raise ArgumentError,
            "#{inspect(adapter)} cannot manage storage (no storage_up/1) — cannot create " <>
              "#{inspect(config[:database])}. Pass a Postgres-backed repo or config."
    end
  end

  @doc """
  Bring the database up and leave the repo running on its configured pool, migrated to `:up`:
  stop any pool that is already running, ensure the database exists (`ensure_up!/2`), migrate
  it through a pool of the boot's own, then start the repo for its caller.

  Returns `:ok`; raises on any failure (including a repo that cannot start, or one a supervisor
  keeps restarting). This is the whole boot an emitted probe / `ci_bootstrap.exs` /
  `test_helper.exs` needs.
  """
  @spec boot!(module(), keyword()) :: :ok
  def boot!(repo, opts \\ []) when is_atom(repo) do
    :ok = stop_repo!(repo)
    :ok = ensure_up!(repo, opts)

    ownership_timeout = Keyword.get(opts, :ownership_timeout, @default_ownership_timeout)

    :ok = migrate_on_its_own_pool!(repo, ownership_timeout)
    :ok = start_repo!(repo, ownership_timeout)
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Never drop a database under a pool that is connected to it: `DROP DATABASE` is refused
  # while a session is attached (so the drop silently becomes best-effort and the old schema
  # survives), and a forced drop leaves the pool reconnecting to a database that may be gone.
  # Stopping the pool first is what makes the drop deterministic.
  #
  # If the pool is a SUPERVISED child, stopping it makes its supervisor start a replacement
  # immediately — and a boot that went on to drop the database would be back to racing a live
  # pool, silently. That case is refused with an actionable message instead.
  defp stop_repo!(repo) do
    case Process.whereis(repo) do
      nil ->
        :ok

      pid ->
        _ =
          try do
            Supervisor.stop(pid, :normal, @stop_timeout)
          catch
            :exit, reason ->
              log("stopping #{inspect(repo)} exited (#{inspect(reason)}); waiting for it to go")
              :ok
          end

        await_down!(repo, pid, 100)
    end
  end

  defp await_down!(repo, pid, attempts) do
    case Process.whereis(repo) do
      nil ->
        # The repo is gone. Give a supervisor time to prove it will NOT put it back before the
        # caller is allowed to rebuild the database it was connected to.
        Process.sleep(@restart_grace)

        case Process.whereis(repo) do
          nil -> :ok
          restarted -> raise_restarted!(repo, restarted)
        end

      ^pid when attempts > 0 ->
        Process.sleep(20)
        await_down!(repo, pid, attempts - 1)

      restarted ->
        raise_restarted!(repo, restarted)
    end
  end

  defp raise_restarted!(repo, pid) do
    raise "#{inspect(repo)} was restarted by its supervisor (#{inspect(pid)}) while its test " <>
            "database was being rebuilt. The harness owns the repo lifecycle during boot: set " <>
            "`start_repo?: false` for the test environment (as every shipped host does) so the " <>
            "boot can stop the pool before dropping the database it is connected to."
  end

  # `Ecto.Migrator` asks the repo for TWO connections at once (its own pool-size guard spells
  # this out), and a SQL Sandbox pool answers the second request with a redirect to the caller's
  # OWN single-connection proxy — which then simply queues, because that proxy is busy holding
  # the first. Observed 2026-11-02: demo's adversarial `mix test` died at `test_helper.exs:18`
  # with `could not checkout the connection owned by #PID<0.94.0> ... dropped from queue after
  # 5978ms` while four sibling gates hammered the same Postgres. Migrating through a pool of
  # its own — plain `DBConnection.ConnectionPool`, Ecto's minimum two connections, never the
  # sandbox — takes the ownership machinery (and the configured 20-connection array) out of the
  # boot path entirely. The caller's configured pool is started afterwards, exactly as before.
  defp migrate_on_its_own_pool!(repo, ownership_timeout) do
    start_opts = [
      pool: DBConnection.ConnectionPool,
      pool_size: @migration_pool_size,
      ownership_timeout: ownership_timeout
    ]

    case repo.start_link(start_opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "could not start #{inspect(repo)} for migration: #{inspect(other)}"
    end

    result =
      try do
        _ = Ecto.Migrator.run(repo, :up, all: true)
        :ok
      rescue
        exception -> {:raised, exception, __STACKTRACE__}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    # Always tear the migration pool down: the caller must find its CONFIGURED pool (the SQL
    # Sandbox for every host test helper) running when `boot!` returns.
    :ok = stop_repo!(repo)

    case result do
      :ok -> :ok
      {:raised, exception, stacktrace} -> reraise(exception, stacktrace)
      {:caught, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp start_repo!(repo, ownership_timeout) do
    case repo.start_link(ownership_timeout: ownership_timeout) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "could not start #{inspect(repo)}: #{inspect(other)}"
    end
  end

  # A failed drop is usually "the schema did not converge" — the caller re-migrates whatever
  # database it finds, so that is a note, not a failure. The exception is a drop that did not
  # FINISH: `DROP DATABASE` that outlives Ecto's client timeout keeps running server-side, and it
  # can land AFTER the `storage_up/1` that follows — the caller then migrates a database that no
  # longer exists (observed 2026-10-24 in the root gate's concurrent tier: `drop skipped
  # ("command timed out"); re-migrating the existing database`, then every pool connection
  # `FATAL 3D000 database "pawchart_test" does not exist`). Re-issuing the (idempotent) drop is
  # what makes the state deterministic: Postgres serialises the two DDLs on the same name, so the
  # retry either performs the drop now or answers `:already_down` once the first one lands.
  defp drop_best_effort(adapter, config) do
    case adapter.storage_down(config) do
      :ok ->
        :ok

      {:error, :already_down} ->
        :ok

      {:error, reason} ->
        retry_drop(adapter, config, reason, @drop_attempts)
    end
  end

  defp retry_drop(adapter, config, reason, attempts) when attempts > 0 do
    log(
      "drop did not complete (#{inspect(reason)}); retrying to settle the state " <>
        "(#{attempts} attempt(s) left)"
    )

    Process.sleep(@retry_interval)

    case adapter.storage_down(config) do
      :ok ->
        :ok

      {:error, :already_down} ->
        :ok

      {:error, other} ->
        retry_drop(adapter, config, other, attempts - 1)
    end
  end

  defp retry_drop(_adapter, _config, reason, 0) do
    log("drop still not completing (#{inspect(reason)}); re-migrating whatever database is there")
    :ok
  end

  defp wait_until_up!(adapter, config, attempts, total) do
    up =
      case adapter.storage_up(config) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, reason} -> {:error, reason}
      end

    # `storage_status/1` answers with BARE :up | :down in current ecto_sql; normalize both
    # contract shapes so a version bump cannot silently break the guard.
    case {status(adapter, config), up} do
      {:up, _} ->
        :ok

      {:unknown, :ok} ->
        :ok

      {state, _} when attempts > 1 ->
        log(
          "database is #{inspect(state)} (storage_up: #{inspect(up)}); " <>
            "retrying (#{attempts - 1} attempt(s) left)"
        )

        Process.sleep(@retry_interval)
        wait_until_up!(adapter, config, attempts - 1, total)

      {state, _} ->
        raise "could not bring up #{inspect(config[:database])}: database reports " <>
                "#{inspect(state)} and storage_up answered #{inspect(up)} " <>
                "after #{total} attempt(s)"
    end
  end

  defp status(adapter, config) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :storage_status, 1) do
      case adapter.storage_status(config) do
        state when state in [:up, {:ok, :up}] -> :up
        state when state in [:down, {:ok, :down}] -> :down
        other -> {:error, other}
      end
    else
      :unknown
    end
  rescue
    e -> {:error, e}
  end

  defp log(message), do: IO.puts("Samen.TestDb: " <> message)
end
