defmodule Samen.Scopes.Finance.JournalTemplateGeneration do
  @moduledoc """
  Materializes a journal template as one **ordinary draft** `JournalEntry`.

  The generator calls the entry resource's normal `:create` action with the
  template's stored lines. It never calls `:post` and never sets a status, so
  the resulting row is a plain draft with the same line materialization,
  balance checks, org guards and approval policy as a manually entered draft.

  Generation is idempotent per `{template, entry_date}`: the database's partial
  unique index on generated entries is the belt, and this change's read is the
  braces. Replaying a due run therefore advances the template's schedule
  without creating a second journal for the same period.

  `prepared_by` is stamped only when a person invoked `:generate`; a cron run
  passes no actor, leaving it NULL until the first human submits the draft.
  That is the same rule as any other system-created draft.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Scopes.Finance.JournalTemplate

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      generate(changeset, opts, context)
    end)
  end

  defp generate(changeset, opts, context) do
    entry_mod = Keyword.fetch!(opts, :entry)

    template =
      Ash.load!(changeset.data, [:org_id, :name, :memo, :frequency, :next_run_on, :lines],
        authorize?: false
      )

    org_id = template.org_id
    entry_date = Ash.Changeset.get_argument(changeset, :entry_date) || Date.utc_today()

    case existing_entry(entry_mod, org_id, template.id, entry_date) do
      {:ok, nil} ->
        create_entry(changeset, entry_mod, template, org_id, entry_date, context)

      {:ok, entry} ->
        mark_generated(changeset, template, entry, entry_date)

      {:error, reason} ->
        add_error(
          changeset,
          "the generated journal could not be checked for an existing instance: #{inspect(reason)}"
        )
    end
  end

  defp create_entry(changeset, entry_mod, template, org_id, entry_date, context) do
    attrs = %{
      org_id: org_id,
      entry_date: entry_date,
      memo: template.memo || template.name,
      source_key: JournalTemplate.source_key(),
      source_id: template.id,
      lines: template.lines
    }

    entry_changeset =
      entry_mod
      |> Ash.Changeset.for_create(:create, attrs,
        actor: context.actor,
        authorize?: false
      )

    case Ash.create(entry_changeset) do
      {:ok, entry} ->
        mark_generated(changeset, template, entry, entry_date)

      {:error, reason} ->
        add_error(
          changeset,
          "the generated journal could not be created: #{inspect(reason)}"
        )
    end
  end

  defp mark_generated(changeset, template, entry, entry_date) do
    next_run_on =
      JournalTemplate.next_run_on(template.next_run_on, template.frequency, entry_date)

    changeset
    |> Ash.Changeset.force_change_attribute(:last_generated_on, entry_date)
    |> Ash.Changeset.force_change_attribute(:last_entry_id, entry.id)
    |> Ash.Changeset.force_change_attribute(:next_run_on, next_run_on)
  end

  defp existing_entry(entry_mod, org_id, template_id, entry_date) do
    entry_mod
    |> Ash.Query.filter(
      org_id == ^org_id and
        source_key == ^JournalTemplate.source_key() and
        source_id == ^template_id and
        entry_date == ^entry_date
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp add_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end
end
