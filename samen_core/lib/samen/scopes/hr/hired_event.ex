defmodule Samen.Scopes.Hr.HiredEvent do
  @moduledoc """
  Materializes the `:hired` EmploymentEvent row when an `Employee` is created
  (WS-ERP E7; design §5 — the ledger is the SoT for employment state).

  Runs in the create's `after_action` (inside the action's transaction — the
  `ConvertLead`/`EntryLines` cross-row-cascade discipline): every employee is
  born with its `:hired` ledger row carrying the SAME effective facts
  (`effective_at` = the employee's `hired_at`), so the derived current-state
  read works by construction — an employee without a hired event is not a
  state the system can produce. A ledger failure rolls the whole create back.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    event_mod = Keyword.fetch!(opts, :event)

    Ash.Changeset.after_action(changeset, fn changeset, employee ->
      # org_id reads from the CREATE changeset (the caller named it there); the
      # returned record's scope-managed org_id is NotLoaded (the E2 lesson).
      org_id = Ash.Changeset.get_attribute(changeset, :org_id) || employee.org_id

      effective_at =
        DateTime.new!(employee.hired_at, ~T[09:00:00], "Etc/UTC")
        |> DateTime.truncate(:second)

      event_mod
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          employee_id: employee.id,
          kind: :hired,
          effective_at: effective_at,
          payload: %{"employment_type" => Atom.to_string(employee.employment_type)}
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _event} ->
          {:ok, employee}

        {:error, reason} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :base,
             message: "the hired ledger row failed to land: #{inspect(reason)}",
             value: nil
           )}
      end
    end)
  end
end
