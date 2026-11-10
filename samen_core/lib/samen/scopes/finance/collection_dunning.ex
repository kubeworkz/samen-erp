defmodule Samen.Scopes.Finance.CollectionDunning do
  @moduledoc """
  Scheduled dunning over the ledger-AR collection cases.

  This sweep reads every OPEN `CollectionCase` whose `next_action_on` has
  arrived and appends the next step in the existing dunning ladder:
  `:reminder -> :notice -> :final_notice -> :collections`. `:collections` is
  the last rung and repeats its follow-up cadence; the case stays open until a
  person resolves it.

  Each org can override the escalation intervals and disable individual
  escalation stages through `CollectionCadence`. A missing cadence row keeps
  the defaults, so adding this feature does not change existing behavior.

  It is deliberately a thin, ledger-free automation layer. It never reads
  cash, never posts a journal entry and never sends a delivery itself — the
  action is recorded on the case timeline for the collections desk, exactly
  like a manual action. A missed sweep does not backfill multiple steps: one
  run advances one step and schedules the next contact from the run date.

  ## Idempotency

  Every scheduled event carries a key derived from the case id and the due
  date it is replacing (`dunning:<case_id>:<YYYY-MM-DD>`). The action service
  returns the existing case without appending when that key is already in the
  bounded timeline, so an Oban retry cannot duplicate a dunning step. The
  case's `next_action_on` moving forward is the first guard; the key is the
  belt for a retry that races the read.

  ## Host seam

  A scope is materialized per host namespace, so the case resource is read
  from host config (the `Samen.Scopes.Finance.RecognitionRun` posture):

      config :samen_core, Samen.Scopes.Finance.CollectionDunning,
        collection_case: Samenerp.Erp.CollectionCase,
        collection_cadence: Samenerp.Erp.CollectionCadence

  An unconfigured host is a NO-OP that names itself (`:not_configured`), not
  a silent success.

  ## Testability

  `run/1` accepts `today:` and `collection_case:` so a suite can state its own
  date and mount without touching host config.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.{ArCollections, CollectionCadence}

  @config_key __MODULE__

  @doc "The host's mounted CollectionCase module, or nil when it is not wired."
  @spec collection_case_module() :: module() | nil
  def collection_case_module do
    :samen_core
    |> Application.get_env(@config_key, [])
    |> Keyword.get(:collection_case)
  end

  @doc "The host's mounted CollectionCadence module, or nil when it is not wired."
  @spec collection_cadence_module() :: module() | nil
  def collection_cadence_module do
    :samen_core
    |> Application.get_env(@config_key, [])
    |> Keyword.get(:collection_cadence)
  end

  @doc """
  Advance every open case due on or before `today`.

  Pass `:case_id` to restrict the sweep to one case for a targeted on-demand
  run; the due-date guard still applies. Without it the run spans every org.
  `:at` sets the recorded event time for targeted/backfill runs; the system
  sweep leaves it unset and records at execution time.

  Returns `{:ok, %{today: date, recorded: [...], skipped: [...]}}`, or
  `{:error, {:dunning_failed, [{case_id, reason}]}}` naming every case whose
  action refused so Oban can retry and dead-letter it visibly.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    resource = Keyword.get(opts, :collection_case, collection_case_module())
    cadence_resource = Keyword.get(opts, :collection_cadence, collection_cadence_module())
    case_id = Keyword.get(opts, :case_id)
    at = Keyword.get(opts, :at)

    case resource do
      nil ->
        {:ok, %{today: today, recorded: [], skipped: [], state: :not_configured}}

      resource ->
        sweep(resource, cadence_resource, today, case_id, at)
    end
  end

  @doc """
  Open cases due on or before `today`, oldest due date first.

  This is the system sweep's read: it spans every org by design, and the
  caller writes each row through its own org-pinned case id.
  """
  @spec due(module(), Date.t()) :: [struct()]
  def due(resource, today) do
    resource
    |> Ash.Query.filter(status == :open and next_action_on <= ^today)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(next_action_on: :asc, inserted_at: :asc)
    # authz-scope: system sweep — collections is a cross-tenant desk. Every
    # update below is pinned to the case's own org id and appended by the
    # system path; pinning this read to one org would strand every other
    # tenant's dunning cadence.
    |> Ash.read!(authorize?: false)
  end

  defp sweep(resource, cadence_resource, today, case_id, at) do
    collection_cases =
      resource
      |> due(today)
      |> only_case(case_id)

    org_ids = collection_cases |> Enum.map(& &1.org_id) |> Enum.uniq()
    cadences = CollectionCadence.for_orgs(cadence_resource, org_ids)

    results =
      Enum.map(collection_cases, fn collection_case ->
        cadence = Map.get(cadences, collection_case.org_id, CollectionCadence.defaults())
        advance(resource, collection_case, cadence, today, at)
      end)

    recorded = for {:recorded, entry} <- results, do: entry
    skipped = for {:skip, entry} <- results, do: entry
    failed = for {:error, failure} <- results, do: failure

    if failed == [] do
      {:ok, %{today: today, recorded: recorded, skipped: skipped}}
    else
      {:error, {:dunning_failed, failed}}
    end
  end

  defp only_case(collection_cases, nil), do: collection_cases

  defp only_case(collection_cases, case_id) do
    Enum.filter(collection_cases, &(&1.id == case_id))
  end

  defp advance(resource, collection_case, cadence, today, at) do
    case CollectionCadence.next_stage(collection_case.stage, cadence) do
      nil ->
        {:skip, %{id: collection_case.id, reason: :no_enabled_stage}}

      stage ->
        due_on = collection_case.next_action_on
        key = idempotency_key(collection_case.id, due_on)
        before = event_count(collection_case)

        case ArCollections.record_action(
               collection_case: resource,
               case_id: collection_case.id,
               kind: stage,
               note: "Scheduled dunning: #{stage_label(stage)}.",
               next_action_on: CollectionCadence.next_action_on(stage, today, cadence),
               idempotency_key: key,
               at: at,
               org_id: collection_case.org_id,
               system?: true
             ) do
          {:ok, updated} ->
            if event_count(updated) > before do
              {:recorded, %{id: updated.id, stage: stage}}
            else
              {:skip, %{id: updated.id, reason: :already_recorded}}
            end

          {:error, reason} ->
            {:error, {collection_case.id, reason}}
        end
    end
  end

  defp event_count(collection_case), do: length(timeline(collection_case))

  defp idempotency_key(case_id, due_on) do
    "dunning:#{case_id}:#{Date.to_iso8601(due_on)}"
  end

  defp timeline(%{actions: actions}) when is_map(actions) do
    case Map.get(actions, "events") || Map.get(actions, :events) do
      events when is_list(events) -> events
      _other -> []
    end
  end

  defp timeline(_collection_case), do: []

  defp stage_label(:notice), do: "notice"
  defp stage_label(:final_notice), do: "final notice"
  defp stage_label(:collections), do: "collections"
end
