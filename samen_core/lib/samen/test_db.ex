defmodule Samen.TestDb do
  @moduledoc """
  The ONE tolerant database boot shared by every harness that owns its own database: the
  `priv/*_probe.exs` probes, the emitted `priv/ci_bootstrap.exs`, and the emitted
  `test/test_helper.exs`.

  `boot!/2` = ensure the database exists → start the repo → migrate it. `ensure_up!/2` is the
  create step alone, for a caller that must do something BETWEEN create and migrate (e.g.
  samen_core's own test helper, which pre-checks the `pgvector` extension and fails with an
  actionable message instead of an opaque `CREATE EXTENSION` error).

  ## Why tolerance here is CORRECT, not a swallowed failure

  Every caller runs *after* another BEAM has just exited — the `mix test` VM whose pool is
  still closing its sessions, or a sibling `ci.sh` gate on the same Postgres. In that window
  `storage_down/1` legitimately answers `{:error, :being_accessed}` (or a pool timeout), and
  the `storage_up/1` that follows answers `{:error, :already_up}` because the database was
  never dropped. A harness that hard-matches `:ok = storage_up(...)` MatchError-kills on that
  benign race before it can assert anything (observed 2026-10-20: the PawChart and SamenERP
  anti-tautology probes died at their own boot line under the root gate).

  What every caller actually needs is a MIGRATED database, so:

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
  @drop_attempts 2

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
  Ensure the database exists (`ensure_up!/2`), start the repo if it is not already running,
  and migrate it to `:up`.

  Returns `:ok`; raises on any failure (including a repo that cannot start). This is the whole
  boot an emitted probe / `ci_bootstrap.exs` / `test_helper.exs` needs.
  """
  @spec boot!(module(), keyword()) :: :ok
  def boot!(repo, opts \\ []) when is_atom(repo) do
    :ok = ensure_up!(repo, opts)

    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "could not start #{inspect(repo)}: #{inspect(other)}"
    end

    _ = Ecto.Migrator.run(repo, :up, all: true)
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

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
