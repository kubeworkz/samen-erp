defmodule Mix.Tasks.SamenWeb.TestSetup do
  @shortdoc "Create + migrate the scratch samen_web_test DB for the render tests"
  @moduledoc """
  Sets up the throwaway `samen_web_test` database that backs `samen_web`'s standalone render
  tests (ADR-009 §6). Drops (if present), creates, and migrates the DB so the test-support
  scope resources + vault routing are live. Run automatically by the `mix test` alias.

  Idempotent: safe to run repeatedly. Only touches the `:test` repo config.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    # Force the test environment repo config.
    Mix.Task.run("loadpaths")
    Application.ensure_all_started(:ash_postgres)
    Application.ensure_all_started(:ecto_sql)

    # `Module.concat/1` (not a compile-time literal) so a HOST that pulls samen_web as a
    # dep — and therefore does NOT compile samen_web's `test/support` `Samen.WebTest.Repo`
    # — gets no "undefined module" warning when this task module is compiled. The module
    # still resolves at runtime in samen_web's own `:test` env, where the repo exists.
    repo = Module.concat([Samen.WebTest, Repo])

    # Drop + create the scratch DB (ignore "does not exist" on drop).
    #
    # Hardened against ci.sh's final tier, where 5 app gates run CONCURRENTLY against one
    # local Postgres: a contended DROP can outlast Ecto's DEFAULT 15s run_query timeout,
    # and a discarded `{:error, "command timed out"}` used to let the server-side DROP land
    # AFTER `storage_up` reported the DB present — the migrate below then died with
    # `FATAL 3D000 ... database "samen_web_test" does not exist` (observed 2026-10-05).
    # So: give the storage ops a generous timeout, surface unexpected drop errors, and let
    # ensure_created/2 VERIFY the final state (retrying) before anyone migrates.
    cfg = storage_cfg(repo)

    case repo.__adapter__().storage_down(cfg) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} ->
        # Possibly still in flight server-side; ensure_created/2 reconciles the real state.
        Mix.shell().info("#{inspect(__MODULE__)}: storage_down -> #{inspect(reason)}; reconciling")
    end

    :ok = ensure_created(repo)

    {:ok, _} = repo.start_link(pool_size: 2)

    # Quiet the per-column catalog_sync INSERT logging during the one-time migration.
    prev_level = Logger.level()
    Logger.configure(level: :warning)
    Ecto.Migrator.run(repo, migrations_path(), :up, all: true)
    Logger.configure(level: prev_level)

    # The `aud_event` migration creates only the FIXED launch-month (July 2026) partition; in
    # production the daily `Samen.AuditEvent.PartitionManager` Oban job rolls partitions forward,
    # but that job never runs under the render-test harness. Ensure the CURRENT + upcoming months'
    # partitions exist so audit-writing tests never hit "no partition of relation aud_event" once
    # the wall clock rolls past the launch month (forward-safe; the ensure is idempotent).
    Module.concat([Samen.AuditEvent, PartitionManager]).ensure_upcoming_partitions(
      repo,
      Date.utc_today(),
      2
    )

    # ...and the PREVIOUS month: audit fixtures backdate timestamps (e.g. a stale-window row at
    # `now - 25h`) that reach across the month boundary in the first days of each month — the
    # previous month's partition is then missing and the insert fails with 23514. Idempotent.
    # (Real regression observed in CI 2026-10-01 00:26 UTC.)
    Module.concat([Samen.AuditEvent, PartitionManager]).ensure_recent_partitions(repo, 1)

    :ok
  end

  # Storage ops get a generous timeout: see run/1 for the concurrent-gate DROP-timeout race.
  defp storage_cfg(repo), do: Keyword.merge(repo.config(), timeout: 60_000)

  defp ensure_created(repo, attempts \\ 20)

  defp ensure_created(repo, 0) do
    Mix.raise("Could not create #{inspect(repo)}: database is not up after retries")
  end

  defp ensure_created(repo, attempts) do
    cfg = storage_cfg(repo)
    adapter = repo.__adapter__()

    up_result =
      case adapter.storage_up(cfg) do
        :ok -> :ok
        {:error, :already_up} -> :ok
        {:error, reason} -> {:error, reason}
      end

    # storage_status/1 answers with BARE :up | :down in this ecto_sql version; normalize
    # both contract shapes so a version bump can't silently break the guard.
    status =
      case adapter.storage_status(cfg) do
        state when state in [:up, {:ok, :up}] -> :up
        state when state in [:down, {:ok, :down}] -> :down
        other -> {:error, other}
      end

    case {status, up_result} do
      {:up, :ok} ->
        :ok

      {:up, {:error, reason}} ->
        # storage_up reported a problem, but the DB verifiably exists (e.g. a concurrently
        # finishing CREATE after a timed-out drop) — safe to migrate.
        Mix.shell().info(
          "#{inspect(__MODULE__)}: storage_up -> #{inspect(reason)} but DB reports :up; continuing"
        )

        :ok

      {:down, _} when attempts > 1 ->
        # A timed-out DROP can land between storage_up's existence check and now; retry.
        Process.sleep(500)
        ensure_created(repo, attempts - 1)

      {:down, up_result} ->
        Mix.raise(
          "Could not create #{inspect(repo)}: DB reports :down (storage_up: #{inspect(up_result)})"
        )

      {{:error, _status_error}, _} when attempts > 1 ->
        Process.sleep(500)
        ensure_created(repo, attempts - 1)

      {{:error, status_error}, _} ->
        Mix.raise("Could not create #{inspect(repo)}: storage_status failed: #{inspect(status_error)}")
    end
  end

  defp migrations_path do
    Path.join([File.cwd!(), "priv", "repo", "migrations"])
  end
end
