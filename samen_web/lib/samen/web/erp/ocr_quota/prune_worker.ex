defmodule Samen.Web.Erp.OcrQuota.PruneWorker do
  @moduledoc """
  Scheduled prune of expired `web_ocr_quota` windows.

  The durable OCR budget writes one row per `{org, window}`. The store prunes an
  org's older rows only when that org starts a fresh window, so an org that stops
  capturing leaves its last row behind forever. This worker deletes every window
  older than the retention floor across ALL orgs.

  The floor is two windows behind the current one (`Samen.Web.Erp.OcrQuota.limit/0`
  supplies the window), so the live and previous windows are never touched and a
  slow/retried request cannot lose a row it is still counted against.

  ## Repo and schedule

  It runs on the repo Oban itself runs on — `config :samen_core, Oban, repo: ...`
  — which is the same host repo the capture page mounts. It rides the canonical
  `Samen.Jobs.default_crontab/0` (`04:15` UTC daily, `:maintenance` queue) but is
  included only when the `samen_web` layer is loaded, since the worker ships with
  that layer.

  A host that has not migrated `web_ocr_quota` (or does not mount AP capture) is
  a clean no-op: the pruner logs and returns `:ok` instead of failing a cron for
  a table it never had.

  Each successful sweep emits `[:samen, :erp, :ocr_quota, :prune]` with
  `%{deleted: count}` — `count` may be `0`, so a handler can alert on any sweep
  that removed rows without treating a quiet day as a failure.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600]

  require Logger

  alias Samen.Web.Erp.OcrQuota

  @prune_event [:samen, :erp, :ocr_quota, :prune]

  @prune """
  DELETE FROM web_ocr_quota
  WHERE window_start_ms < $1::bigint
  """

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    with {:ok, repo} <- repo() do
      case prune(repo) do
        {:ok, deleted} ->
          Logger.info("[Samen.Web.Erp.OcrQuota.PruneWorker] job_id=#{job_id} deleted=#{deleted}")

          :ok

        {:error, :undefined_table} ->
          Logger.info(
            "[Samen.Web.Erp.OcrQuota.PruneWorker] job_id=#{job_id} web_ocr_quota not migrated; nothing to prune"
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_repo} ->
        Logger.info(
          "[Samen.Web.Erp.OcrQuota.PruneWorker] job_id=#{job_id} no Oban repo configured; nothing to prune"
        )

        :ok
    end
  end

  @doc """
  Delete windows older than two windows behind the current one.

  Public so an operator (or a test) can run one sweep without building a job.
  """
  @spec prune(module()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(repo) do
    {_limit, window_ms} = OcrQuota.limit()
    current = div(System.system_time(:millisecond), window_ms) * window_ms
    cutoff = current - 2 * window_ms

    case Ecto.Adapters.SQL.query(repo, @prune, [cutoff]) do
      {:ok, %{num_rows: deleted}} ->
        :telemetry.execute(@prune_event, %{deleted: deleted}, %{result: :ok})
        {:ok, deleted}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:error, :undefined_table}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo do
    oban = Application.get_env(:samen_core, Oban, [])

    case is_list(oban) && Keyword.get(oban, :repo) do
      repo when is_atom(repo) and not is_nil(repo) -> {:ok, repo}
      _other -> {:error, :no_repo}
    end
  end
end
