defmodule Samen.Scopes.Finance.RecurringJournalRun do
  @moduledoc """
  The due-template sweep for recurring journal templates.

  Every active, recurring template whose `next_run_on` has arrived is asked to
  generate ONE ordinary draft through its own `:generate` action. The run never
  posts and never touches the approval queue: the generated draft is just a
  draft, and a person must submit it through the journal's normal `:post`
  action (where `JournalApprovalPolicy` applies).

  ## Host seam

  Templates are host-mounted resources, so the run needs the host's template
  module:

      config :samen_core, Samen.Scopes.Finance.RecurringJournalRun,
        template_module: Samenerp.Erp.JournalTemplate

  An unconfigured host is a no-op, not a failure. `today:` is injectable so
  tests state their own date rather than waiting for the wall clock.

  Failures are collected and returned: one malformed/out-of-policy template
  must not hide the templates that did generate, and a failed due run must be
  visible to Oban rather than silently counted as done.
  """

  require Ash.Query

  @config_key __MODULE__

  @doc "The host's mounted JournalTemplate module, or nil when unwired."
  def template_module do
    :samen_core
    |> Application.get_env(@config_key, [])
    |> Keyword.get(:template_module)
  end

  @doc """
  Generate every due recurring template's draft.

  Returns `{:ok, %{generated: [entry_id], failed: []}}` or
  `{:error, {:recurring_journal_failed, [{template_id, reason}]}}`.
  """
  def run(opts \\ []) do
    template_mod = Keyword.get(opts, :template_module, template_module())
    today = Keyword.get(opts, :today, Date.utc_today())

    if is_nil(template_mod) do
      {:ok, %{generated: [], failed: [], skipped: :not_configured}}
    else
      template_mod
      |> due(today)
      |> Enum.map(&generate/1)
      |> summarize()
    end
  end

  @doc "Every active recurring template due on or before `today`, oldest first."
  def due(template_mod, today) do
    # authz-scope: system sweep — templates are host-wide config rows, and the
    # generated entry's own OrgScope/approval guards decide every tenant write.
    template_mod
    |> Ash.Query.filter(
      active == true and
        frequency != :none and
        not is_nil(next_run_on) and
        next_run_on <= ^today
    )
    |> Ash.Query.sort(next_run_on: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp generate(template) do
    template
    |> Ash.Changeset.for_update(:generate, %{entry_date: template.next_run_on}, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, updated} -> {:ok, updated.last_entry_id}
      {:error, reason} -> {:error, {template.id, reason}}
    end
  end

  defp summarize(results) do
    generated = for {:ok, entry_id} <- results, not is_nil(entry_id), do: entry_id
    failed = for {:error, failure} <- results, do: failure

    if failed == [] do
      {:ok, %{generated: generated, failed: []}}
    else
      {:error, {:recurring_journal_failed, failed}}
    end
  end
end
