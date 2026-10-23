defmodule Samen.ObanUniqueInsertDedupTest do
  @moduledoc """
  L4 (T90) insert-time exactly-once — the epmd-FREE leg of the multi-node uniqueness proof.

  `Samen.MultiNode.UniqueWorker` declares Oban's `unique: [keys: [:key], …]`, the INSERT-TIME
  exactly-once primitive: enqueuing the SAME logical job any number of times collapses to ONE
  `oban_jobs` row, so the side effect fires once. The two-node proof
  (`test/multinode/oban_multinode_test.exs`) shows the same collapse ACROSS two real BEAM nodes,
  but it needs `epmd` + working Erlang distribution, is therefore opt-in (`:multinode`), and is
  unrunnable on a host whose distribution cannot start.

  This file asserts the declaration's contract on ONE node, against the standard sandboxed test
  repo, so the guarantee stays refutable everywhere — it is the anchor for
  `scripts/sabotages/336-multinode-oban-unique-dedup-declaration-dropped.patch`. Drop `unique`
  from the worker and the 40-insert fan-out below lands 40 rows instead of 1. The negative control
  (`Samen.MultiNode.NoUniqueWorker` — identical body, NO `unique`) asserts the SAME fan-out lands
  many rows in the SAME run, so a green first assertion cannot be an accident of the harness.

  No distribution, no `:peer`, no dedicated database. `Oban.insert/1` (never `insert_all/1`,
  which bypasses `unique`) writes the job row inside the sandbox transaction — `config/test.exs`
  runs Oban in `testing: :manual`, so no queue executes and only the ROW COUNT is under test.

  The cross-node leg is unchanged: on a host with a working distribution the `:multinode` tier
  still fans the same worker out from two nodes and asserts one execution. This file is the leg
  that every host can run.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SamenCore.TestRepo
  alias Samen.MultiNode.{NoUniqueWorker, UniqueWorker}

  # The two-node proof fans out 40 inserts per node; the same order of magnitude here is enough
  # to make a dropped declaration unmistakable without slowing the default suite.
  @fanout 40

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  test "uniqueness dedup: the unique job fanned out 40x from ONE node lands ONE row (insert-time exactly-once)" do
    key = "dedup-#{System.unique_integer([:positive])}"

    for _ <- 1..@fanout do
      assert {:ok, _job} = Oban.insert(UniqueWorker.new(%{key: key}))
    end

    assert job_rows(UniqueWorker, key) == 1,
           "unique: [keys: [:key]] must collapse #{@fanout} inserts of ONE logical job into a " <>
             "single oban_jobs row — a count above 1 means the same side effect fans out per enqueue"
  end

  test "control: the SAME fan-out with NO unique declaration lands one row per enqueue (the check can fail)" do
    key = "control-#{System.unique_integer([:positive])}"

    for _ <- 1..@fanout do
      assert {:ok, _job} = Oban.insert(NoUniqueWorker.new(%{key: key}))
    end

    assert job_rows(NoUniqueWorker, key) == @fanout,
           "the negative control (identical body, no `unique`) must keep every insert — otherwise " <>
             "the dedup assertion above proves nothing about the declaration"
  end

  # The whole assertion is one number: how many `oban_jobs` rows carry this worker + logical key.
  defp job_rows(worker, key) do
    worker_name = inspect(worker)

    TestRepo.aggregate(
      from(j in Oban.Job, where: j.worker == ^worker_name and j.args["key"] == ^key),
      :count
    )
  end
end
