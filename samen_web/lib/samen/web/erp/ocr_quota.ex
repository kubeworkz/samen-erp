defmodule Samen.Web.Erp.OcrQuota do
  @moduledoc """
  Per-organization budget for hosted OCR, durable and shared across nodes.

  Invoice capture is the ERP surface that spends real money per action: every
  PDF or image handed to `Samen.Scopes.Finance.InvoiceOcr` is a billable
  provider call, so a single operator (or a stuck client retrying) could run up
  the provider account. Pasting text and uploading a `.txt`/`.csv` are free and
  are never counted — only a document that will actually reach the adapter
  consumes a slot.

  ## Durable, not ETS

  The counter lives in Postgres (`web_ocr_quota`, one row per `{org, window}`),
  not in the rate limiter's node-local Hammer ETS store. That makes the budget
  the fleet shares:

    * every node sees the same `hits` for the current window;
    * a restart does not hand the org a fresh allowance;
    * two nodes consuming at the same instant still allow exactly `limit`
      documents, because the increment is a single
      `INSERT … ON CONFLICT … RETURNING` statement — there is no read-then-write
      step to race through.

  The window comes from the DATABASE clock (`now()`), so node clock skew cannot
  split one org's budget across two windows. Windows are aligned to
  `div(now_ms, window_ms)`, the same shape the Hammer-backed surfaces use.

  Hosts must run the migration that creates `web_ocr_quota` (reference:
  `samen_web/priv/repo/migrations/20261110120000_add_ocr_quota.exs`). Without
  it, capture refuses documents with `:ocr_quota_unavailable` — pasted text
  still works — rather than spending unmetered.

  ## Configuration

  The limit and window reuse the shared `Samen.Web.RateLimit` surface config:

      config :samen_web, Samen.Web.RateLimit,
        limits: %{erp_invoice_ocr: {120, 3_600_000}}

  Default: **60 documents per hour per org**. The key is the org id (a bounded
  internal identifier, not PII), so a workspace's whole team shares one budget
  and one org cannot spend another's.

  Over the limit, capture refuses the document and points at the paste path; it
  never silently drops the upload and never calls the provider anyway. The page
  shows the org's remaining budget before an upload (`remaining/2`, `budget/2`).

  ## Telemetry

  Two content-free events let a host alert without scraping logs:

    * `[:samen, :erp, :ocr_quota, :exhausted]` — emitted once per org per window,
      on the charge that first crosses the limit. Measurements `limit` and
      `window_ms`; metadata `org_id` and `window_start_ms`. `org_id` is the same
      bounded internal key the budget uses; no document content or operator
      identity is carried.
    * `[:samen, :erp, :ocr_quota, :prune]` — emitted after each scheduled (or
      manual) sweep by `Samen.Web.Erp.OcrQuota.PruneWorker`. Measurement
      `deleted` (may be `0`); metadata `result: :ok`.

  ## Realtime

  `check/2` accepts `:pubsub`, a running `Phoenix.PubSub` server name. When a
  charge is allowed it publishes `{:ocr_quota_changed, org_id}` on that org's
  `Samen.Web.Erp.OcrQuota.PubSub` topic, so another page showing the budget can
  re-read it. The message carries the bounded org id only — no count, document
  or operator identity — and callers that omit `:pubsub` publish nothing.

  `window_remaining_ms/1` reads the database clock's distance to the next
  window boundary (a read, never a charge). The ERP dashboard and AP capture
  page use it with `format_window_remaining/1` and `refresh_delay_ms/1` to keep
  the "Resets in" label counting down and to re-read just after the boundary,
  so an exhausted card does not outlive the window that caused it.

  ## The repo

  The counter is raw SQL against the host repo the page already mounts
  (`Samen.Web.Mount.repo`), passed as `:repo`. No separate repo seam is
  introduced, and a missing repo is reported as `:ocr_quota_unavailable` rather
  than metered in memory.
  """

  alias Samen.Web.Erp.OcrQuota.PubSub
  alias Samen.Web.Erp.OcrQuota.Store
  alias Samen.Web.RateLimit

  @surface :erp_invoice_ocr

  # A page refresh at the exact boundary can land in the window that just ended;
  # one second past it is unambiguous. Otherwise re-read once a minute so a
  # whole-minute reset label keeps counting down.
  @window_refresh_grace_ms 1_000
  @refresh_interval_ms 60_000

  @doc """
  Charge one document to `org_id`'s OCR budget.

  Returns `:ok` while the org is under its limit, `{:error, :ocr_rate_limited}`
  once over it, and `{:error, :ocr_quota_unavailable}` when the durable counter
  cannot be read (no repo, table not migrated, database error). An allowed
  charge also publishes `{:ocr_quota_changed, org_id}` when `:pubsub` names a
  running server. A nil/blank org id is not metered here — the page has already
  refused to act without an org, so there is no provider call to bound.
  """
  @spec check(String.t() | nil, keyword()) ::
          :ok | {:error, :ocr_rate_limited} | {:error, :ocr_quota_unavailable}
  def check(org_id, opts \\ [])

  def check(org_id, opts) when is_binary(org_id) and org_id != "" do
    {limit, window_ms} = limit()

    case repo(opts) do
      nil ->
        {:error, :ocr_quota_unavailable}

      repo ->
        case Store.consume(repo, org_id, limit, window_ms) do
          :ok ->
            announce(opts, org_id)
            :ok

          error ->
            error
        end
    end
  end

  def check(_org_id, _opts), do: :ok

  @doc """
  How many documents `org_id` has left in the current window, floored at zero.

  A read: showing the budget never consumes it. `nil` when the durable counter
  cannot be read (see `check/2`).
  """
  @spec remaining(String.t() | nil, keyword()) :: non_neg_integer() | nil
  def remaining(org_id, opts \\ []) do
    {limit, window_ms} = limit()

    with org_id when is_binary(org_id) and org_id != "" <- org_id,
         repo when is_atom(repo) and not is_nil(repo) <- repo(opts),
         {:ok, hits} <- Store.remaining(repo, org_id, window_ms) do
      max(limit - hits, 0)
    else
      _unavailable -> nil
    end
  end

  @doc "The org's remaining budget plus the limit it is measured against."
  @spec budget(String.t() | nil, keyword()) :: %{
          remaining: non_neg_integer() | nil,
          limit: pos_integer()
        }
  def budget(org_id, opts \\ []) do
    {limit, _window_ms} = limit()
    %{remaining: remaining(org_id, opts), limit: limit}
  end

  @doc """
  Milliseconds until the current budget window ends, measured by the database
  clock — the same clock that starts windows, so node clock skew cannot schedule
  a refresh into the wrong window.

  A read: it never consumes a document. `{:error, :ocr_quota_unavailable}` when
  the counter cannot be read.
  """
  @spec window_remaining_ms(keyword()) ::
          {:ok, pos_integer()} | {:error, :ocr_quota_unavailable}
  def window_remaining_ms(opts \\ []) do
    {_limit, window_ms} = limit()

    case repo(opts) do
      nil -> {:error, :ocr_quota_unavailable}
      repo -> Store.window_remaining(repo, window_ms)
    end
  end

  @doc """
  Formats a `window_remaining_ms/1` value for the ERP budget pages.

  Whole-minute units; a window under a minute reads "less than a minute"
  rather than "0m". `nil` (no readable window) formats as `nil`.
  """
  @spec format_window_remaining(nil | non_neg_integer()) :: String.t() | nil
  def format_window_remaining(nil), do: nil

  def format_window_remaining(remaining_ms) when is_integer(remaining_ms) do
    cond do
      remaining_ms < 60_000 ->
        "less than a minute"

      remaining_ms < 3_600_000 ->
        "#{div(remaining_ms, 60_000)}m"

      true ->
        hours = div(remaining_ms, 3_600_000)
        minutes = div(rem(remaining_ms, 3_600_000), 60_000)

        if minutes == 0, do: "#{hours}h", else: "#{hours}h #{minutes}m"
    end
  end

  @doc """
  Milliseconds until an ERP budget page should refresh its window label.

  At most one minute, or just past the boundary plus a short grace when the
  boundary is sooner. A failed clock read retries in a minute.
  """
  @spec refresh_delay_ms(nil | non_neg_integer()) :: pos_integer()
  def refresh_delay_ms(remaining_ms) when is_integer(remaining_ms) do
    min(remaining_ms + @window_refresh_grace_ms, @refresh_interval_ms)
  end

  def refresh_delay_ms(_remaining_ms), do: @refresh_interval_ms

  @doc "The configured `{limit, window_ms}` this module enforces."
  @spec limit() :: {pos_integer(), pos_integer()}
  def limit, do: RateLimit.limit_for(@surface)

  # A spent slot is the budget change another page can observe from a distance;
  # a refused attempt changes nothing, so only an allowed charge is published.
  defp announce(opts, org_id) do
    case Keyword.get(opts, :pubsub) do
      server when is_atom(server) and not is_nil(server) -> PubSub.broadcast(server, org_id)
      _other -> :ok
    end
  end

  defp repo(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_atom(repo) and not is_nil(repo) -> repo
      _other -> nil
    end
  end
end
