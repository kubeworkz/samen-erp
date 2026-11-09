defmodule Samen.Web.Erp.OcrQuota.Store do
  @moduledoc false
  # The durable counter behind `Samen.Web.Erp.OcrQuota`.
  #
  # One row per `{org_id, window_start_ms}`. The increment is a SINGLE
  # `INSERT … ON CONFLICT … RETURNING` statement, so two nodes consuming the
  # same window at the same instant cannot both read "one left" and both spend
  # it — Postgres serializes the conflicting upsert and returns the real count.
  #
  # The window start is computed from the DATABASE clock (`now()`), not each
  # node's, so clock skew cannot split one org's budget across two windows.

  @consume """
  INSERT INTO web_ocr_quota (org_id, window_start_ms, hits)
  VALUES (
    $1::text::uuid,
    (floor(extract(epoch FROM now()) * 1000)::bigint / $2::bigint) * $2::bigint,
    1
  )
  ON CONFLICT (org_id, window_start_ms)
  DO UPDATE SET hits = web_ocr_quota.hits + 1
  RETURNING hits, window_start_ms
  """

  @prune """
  DELETE FROM web_ocr_quota
  WHERE org_id = $1::text::uuid AND window_start_ms < $2::bigint
  """

  @remaining """
  SELECT hits FROM web_ocr_quota
  WHERE org_id = $1::text::uuid
    AND window_start_ms =
      (floor(extract(epoch FROM now()) * 1000)::bigint / $2::bigint) * $2::bigint
  """

  # Milliseconds from the DATABASE clock to the next window boundary. The same
  # `floor(now_ms / window_ms)` arithmetic the charge uses, inverted, so a node
  # clock skew cannot schedule a refresh into the wrong window.
  @window_remaining """
  SELECT $1::bigint - (floor(extract(epoch FROM now()) * 1000)::bigint % $1::bigint)
  """

  # Once per org per window: the charge that carries the row from `limit` to
  # `limit + 1`. Later denials in the same window stay quiet.
  @exhausted_event [:samen, :erp, :ocr_quota, :exhausted]

  @spec consume(module(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :ocr_rate_limited} | {:error, :ocr_quota_unavailable}
  def consume(repo, org_id, limit, window_ms) do
    case query(repo, @consume, [org_id, window_ms]) do
      {:ok, %{rows: [[hits, window_start]]}} ->
        # A fresh window is the cheap moment to drop this org's older rows.
        if hits == 1, do: _ = query(repo, @prune, [org_id, window_start])

        if hits == limit + 1 do
          :telemetry.execute(
            @exhausted_event,
            %{limit: limit, window_ms: window_ms},
            %{org_id: org_id, window_start_ms: window_start}
          )
        end

        if hits <= limit, do: :ok, else: {:error, :ocr_rate_limited}

      {:error, _reason} ->
        {:error, :ocr_quota_unavailable}
    end
  end

  @spec remaining(module(), String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :ocr_quota_unavailable}
  def remaining(repo, org_id, window_ms) do
    case query(repo, @remaining, [org_id, window_ms]) do
      {:ok, %{rows: []}} -> {:ok, 0}
      {:ok, %{rows: [[hits]]}} -> {:ok, hits}
      {:error, _reason} -> {:error, :ocr_quota_unavailable}
    end
  end

  @spec window_remaining(module(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :ocr_quota_unavailable}
  def window_remaining(repo, window_ms) do
    case query(repo, @window_remaining, [window_ms]) do
      {:ok, %{rows: [[ms]]}} when is_integer(ms) and ms > 0 -> {:ok, ms}
      {:ok, _unexpected} -> {:error, :ocr_quota_unavailable}
      {:error, _reason} -> {:error, :ocr_quota_unavailable}
    end
  end

  defp query(repo, sql, params), do: Ecto.Adapters.SQL.query(repo, sql, params)
end
