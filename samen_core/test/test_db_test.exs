defmodule Samen.TestDbTest.ScratchRepo do
  @moduledoc false
  # A repo of this test file's own, so the `boot!/2` proofs can start/stop a pool without
  # touching the suite's `SamenCore.TestRepo`.
  use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
end

defmodule Samen.TestDbTest do
  @moduledoc """
  Proofs for the shared tolerant boot (`Samen.TestDb`) that every probe, emitted
  `ci_bootstrap.exs` and emitted `test_helper.exs` now uses.

  The point of the module is a specific, observed failure: under the root gate a harness runs
  moments after another BEAM has exited, its `storage_down` is refused because the previous
  pool still holds the database, and the `storage_up` that follows then answers
  `{:error, :already_up}` — a value the old `:ok = storage_up(...)` hard-match crashed on
  (2026-10-20, PawChart/SamenERP anti-tautology probes). These three tests pin, respectively:

    1. that benign pair is TOLERATED (green — and the database really is held by a live
       connection, so the drop genuinely fails: the race is reproduced, not simulated);
    2. a genuinely unreachable database still RAISES (the tolerance is not a swallowed error);
    3. an adapter that cannot manage storage is REFUSED loudly (fail-honest, never a silent
       "assume it is up").

  Two more pin the boot itself (2026-11-02, demo's adversarial `mix test`): a pool that is
  already running is STOPPED before the drop (a canary table proves the database really was
  rebuilt, not merely re-migrated under a live pool), and a pool a supervisor keeps restarting
  is REFUSED rather than dropped out from under.

  Everything runs against a scratch database of its own — never the suite's `samen_core_test`.
  """

  use ExUnit.Case, async: false

  alias Samen.TestDbTest.ScratchRepo
  alias SamenCore.TestRepo

  @scratch_db "samen_core_testdb_helper_test"

  defp scratch_config do
    TestRepo.config()
    |> Keyword.put(:database, @scratch_db)
    |> Keyword.put(:timeout, 30_000)
  end

  setup do
    on_exit(fn ->
      _ = Ecto.Adapters.Postgres.storage_down(scratch_config())
    end)

    :ok
  end

  test "ensure_up!/1 TOLERATES a held database whose drop is refused (the already_up race)" do
    assert :ok = Samen.TestDb.ensure_up!(scratch_config(), timeout: 15_000)

    # Hold the database open from this VM. `DROP DATABASE` is refused while another session is
    # connected, so the drop inside ensure_up! fails and its `storage_up` answers
    # `{:error, :already_up}` — exactly the pair the old hard match crashed on. The tolerant
    # boot must accept it (the database IS up) instead of killing the harness.
    holder_opts =
      scratch_config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Keyword.put(:pool_size, 1)
      |> Keyword.put(:name, :test_db_helper_holder)

    holder = start_supervised!({Postgrex, holder_opts})

    assert :ok = Samen.TestDb.ensure_up!(scratch_config(), timeout: 5_000, attempts: 3)

    # Positive control: the database the holder is connected to is the SAME one that is up.
    assert %{rows: [[1]]} = Postgrex.query!(holder, "SELECT 1", [])

    :ok = GenServer.stop(holder)
  end

  test "ensure_up!/1 still RAISES when the database genuinely cannot come up" do
    unreachable =
      scratch_config()
      |> Keyword.put(:port, 1)
      |> Keyword.put(:timeout, 500)

    assert_raise RuntimeError, ~r/could not bring up/, fn ->
      Samen.TestDb.ensure_up!(unreachable, attempts: 1)
    end
  end

  test "ensure_up!/1 refuses an adapter that cannot manage storage (never a silent pass)" do
    assert_raise ArgumentError, ~r/cannot manage storage/, fn ->
      Samen.TestDb.ensure_up!(scratch_config(), adapter: Samen.TestDb.NoSuchAdapter)
    end
  end

  test "boot!/2 stops a live pool BEFORE dropping (a canary table proves the database is rebuilt)" do
    scratch_repo!()
    :ok = Samen.TestDb.ensure_up!(ScratchRepo, timeout: 15_000)
    {:ok, _pid} = ScratchRepo.start_link()

    # Hold a table of our own. If the boot dropped the database under the live pool, the drop
    # would be refused (best-effort), the create would answer `:already_up`, and this row would
    # survive the "rebuild" — exactly the silent no-op the boot must never allow.
    assert {:ok, _} = ScratchRepo.query("CREATE TABLE boot_canary (id integer)")

    assert :ok = Samen.TestDb.boot!(ScratchRepo, timeout: 15_000)

    assert Process.whereis(ScratchRepo) |> is_pid(),
           "the boot must leave the repo running for its caller"

    assert {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} =
             ScratchRepo.query("SELECT 1 FROM boot_canary")

    # Migrated (Ecto's bookkeeping exists) and on the CONFIGURED pool again: only a sandbox
    # pool can be switched to :manual.
    assert {:ok, %{num_rows: 0}} = ScratchRepo.query("SELECT 1 FROM schema_migrations")
    assert :ok = Ecto.Adapters.SQL.Sandbox.mode(ScratchRepo, :manual)
  end

  test "boot!/2 REFUSES to drop a database under a pool a supervisor keeps restarting" do
    scratch_repo!()

    {:ok, supervisor} = Supervisor.start_link([ScratchRepo], strategy: :one_for_one)

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _ -> :ok
        end
      end

      Application.delete_env(:samen_core, ScratchRepo)
    end)

    assert_raise RuntimeError, ~r/was restarted by its supervisor/, fn ->
      Samen.TestDb.boot!(ScratchRepo, timeout: 15_000)
    end
  end

  # Point the scratch repo at the module's scratch database (on the SQL Sandbox, like every
  # host test config) and register the cleanup that must run BEFORE the module's `on_exit` can
  # drop the database (a drop is refused while the pool is attached). The caller starts it.
  defp scratch_repo! do
    config =
      scratch_config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)
      |> Keyword.put(:pool_size, 5)

    Application.put_env(:samen_core, ScratchRepo, config)

    on_exit(fn ->
      case Process.whereis(ScratchRepo) do
        nil ->
          :ok

        pid ->
          try do
            Supervisor.stop(pid, :normal, 30_000)
          catch
            :exit, _ -> :ok
          end
      end

      Application.delete_env(:samen_core, ScratchRepo)
    end)

    :ok
  end
end
