defmodule Samen.Web.Erp.OcrQuotaPruneWorkerTest do
  @moduledoc """
  The scheduled prune for the durable OCR budget:

    * windows older than two windows are deleted, recent ones are kept;
    * `perform/1` runs on the repo Oban itself runs on;
    * a host that never migrated `web_ocr_quota` is a clean no-op, not a failing
      cron;
    * the canonical crontab schedules the pruner once `samen_web` is loaded.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.OcrQuota
  alias Samen.Web.Erp.OcrQuota.PruneWorker
  alias Samen.WebTest.RateLimitFlood
  alias Samen.WebTest.Repo

  setup do
    RateLimitFlood.pin!(%{erp_invoice_ocr: {2, 86_400_000}})

    previous_oban = Application.get_env(:samen_core, Oban)
    Application.put_env(:samen_core, Oban, Keyword.put(previous_oban || [], :repo, Repo))
    on_exit(fn -> restore_oban(previous_oban) end)

    :ok
  end

  defp window(offset) do
    {_limit, window_ms} = OcrQuota.limit()
    div(System.system_time(:millisecond), window_ms) * window_ms - offset * window_ms
  end

  defp insert_row!(org_id, window_start) do
    Repo.query!(
      "INSERT INTO web_ocr_quota (org_id, window_start_ms, hits) " <>
        "VALUES ($1::text::uuid, $2::bigint, 1)",
      [org_id, window_start]
    )
  end

  defp rows do
    %{rows: rows} =
      Repo.query!(
        "SELECT org_id::text, window_start_ms FROM web_ocr_quota ORDER BY window_start_ms"
      )

    rows
  end

  test "deletes windows older than the retention floor and keeps recent ones" do
    expired = Ecto.UUID.generate()
    recent = Ecto.UUID.generate()

    insert_row!(expired, window(5))
    insert_row!(recent, window(1))

    assert {:ok, 1} = PruneWorker.prune(Repo)
    assert rows() == [[recent, window(1)]]
  end

  test "perform/1 prunes on the repo Oban runs on" do
    org = Ecto.UUID.generate()
    insert_row!(org, window(5))

    assert :ok = PruneWorker.perform(%Oban.Job{id: 1})
    assert rows() == []
  end

  test "an unmigrated host is a clean no-op" do
    Repo.query!("DROP TABLE web_ocr_quota")

    assert {:error, :undefined_table} = PruneWorker.prune(Repo)
    assert :ok = PruneWorker.perform(%Oban.Job{id: 2})
  end

  test "the canonical crontab schedules the pruner once the web layer is loaded" do
    assert {"15 4 * * *", PruneWorker} in Samen.Jobs.default_crontab()
  end

  test "each sweep reports how many windows it deleted" do
    handler = {:ocr_quota_prune_telemetry, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:samen, :erp, :ocr_quota, :prune],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:ocr_quota_pruned, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    insert_row!(Ecto.UUID.generate(), window(5))

    assert {:ok, 1} = PruneWorker.prune(Repo)
    assert_receive {:ocr_quota_pruned, %{deleted: 1}, %{result: :ok}}

    assert {:ok, 0} = PruneWorker.prune(Repo)
    assert_receive {:ocr_quota_pruned, %{deleted: 0}, %{result: :ok}}
  end

  defp restore_oban(nil), do: Application.delete_env(:samen_core, Oban)
  defp restore_oban(value), do: Application.put_env(:samen_core, Oban, value)
end
