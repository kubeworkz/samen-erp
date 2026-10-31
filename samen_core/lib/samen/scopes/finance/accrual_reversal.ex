defmodule Samen.Scopes.Finance.AccrualReversal do
  @moduledoc """
  The scheduled-reversal RUN (WS-ACCT Phase 5; ADR-054 D6): find every draft
  reversal whose date has arrived and POST it through the ordinary governed
  `:post` action.

  ## Exactly once, and why that is structural

  The run never "posts a reversal"; it asks the entry to post ITSELF, and
  `Samen.Scopes.Finance.PostGuard` only lets a `:draft` row become `:posted`.
  So a second run over the same row finds it no longer a draft (either excluded
  by the read, or refused by the one-way state machine), and a completed
  reversal's `posted_at` cannot move. There is nothing to dedupe by hand — the
  state machine *is* the anchor, the same way `:void` cannot run twice.

  The reversal is dated in the period it belongs to, so `PeriodGuard`,
  `PostBalance` and `DimensionBalance` all run on it. A reversal that cannot
  post is REPORTED, never skipped: the run returns an error so the job retries
  and finally lands in the dead-letter bucket, which is honest — a silently
  dropped month-end reversal is exactly the double-count the manual's control
  exists to prevent.

  ## The host seam

  A scope is materialized per host namespace, so the entry resource is read from
  host config (the `Samen.Automation.workflow_module/0` posture):

      config :samen_core, Samen.Scopes.Finance.AccrualReversal,
        entry_module: Samenerp.Erp.JournalEntry

  An unconfigured host is a NO-OP, not a failure: there are no books to reverse
  in. It is not a silent lie either — `run/1` names the state in its summary.

  ## Testability

  `run/1` takes `today:` so a suite can state its own date instead of waiting
  for a wall clock (the house red-path discipline).
  """

  require Ash.Query

  alias Samen.Scopes.Finance.AccrualGuard

  @config_key __MODULE__

  @doc "The host's JournalEntry module, or nil when the host has not wired one."
  def entry_module do
    :samen_core
    |> Application.get_env(@config_key, [])
    |> Keyword.get(:entry_module)
  end

  @doc """
  Every DRAFT scheduled reversal dated on or before `today`, oldest first.
  """
  def due(entry_module, today) do
    # authz-scope: system sweep — the scheduled run is org-agnostic BY DESIGN: it posts
    # every tenant's due reversal, and each row's own governed `:post` action (OrgScope,
    # PeriodGuard, PostBalance on the entry's org) is what decides whether it may land.
    # Narrowing this read to one org would strand every other tenant's month-end.
    entry_module
    |> Ash.Query.filter(
      source_key == ^AccrualGuard.source_key() and
        status == :draft and entry_date <= ^today
    )
    |> Ash.Query.sort(entry_date: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  Post every due reversal. Returns `{:ok, %{posted: [...], failed: []}}` — or
  `{:error, {:reversal_post_failed, [...]}}` naming each row that refused, so a
  blocked reversal is visible rather than counted as done.
  """
  def run(opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())

    case entry_module() do
      nil ->
        {:ok, %{posted: [], failed: [], skipped: :not_configured}}

      entry_module ->
        results = entry_module |> due(today) |> Enum.map(&post/1)

        posted = for {:ok, id} <- results, do: id
        failed = for {:error, failure} <- results, do: failure

        if failed == [] do
          {:ok, %{posted: posted, failed: []}}
        else
          {:error, {:reversal_post_failed, failed}}
        end
    end
  end

  defp post(entry) do
    entry
    |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, posted} -> {:ok, posted.id}
      {:error, reason} -> {:error, {entry.id, reason}}
    end
  end
end
