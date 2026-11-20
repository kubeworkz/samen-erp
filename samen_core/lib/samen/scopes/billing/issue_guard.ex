defmodule Samen.Scopes.Billing.IssueGuard do
  @moduledoc """
  The Billing issuance guard (B0; ADR-054 amendment).

  A **local** invoice (`provider_invoice_ref` is nil/blank) is born a draft and
  may only reach an issued status through the explicit `:issue` action. A
  provider-mirror row is exempt: the webhook mirror writes provider snapshots
  through generic create/update, including `:open`/`:paid`.

  This is the application-level half of the exactly-once seam; the B0
  `ArInvoicePosting` change and the journal-anchor unique index are the posting
  half. The guard intentionally does not treat an unrelated update as a transition.
  """

  use Ash.Resource.Change

  @issued ~w(open paid uncollectible)

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type in [:create, :update] do
      # Validate in before_action, after the action's own set_attribute and
      # default application. A resource-level change runs before those in some
      # update paths, so checking at change/3 time would miss an explicit
      # status write.
      Ash.Changeset.before_action(changeset, &validate/1)
    else
      changeset
    end
  end

  defp validate(changeset) do
    cond do
      provider_mirror?(changeset) -> changeset
      changeset.action_type == :create -> guard_create(changeset)
      true -> guard_update(changeset)
    end
  end

  defp guard_create(changeset) do
    if draft?(status(changeset)) do
      changeset
    else
      error(changeset, "a local invoice is born a draft; use :issue to open it")
    end
  end

  defp guard_update(changeset) do
    action = changeset.action && changeset.action.name
    previous = current_status(changeset)
    next = status(changeset) || previous

    if action != :issue and draft?(previous) and issued?(next) do
      error(
        changeset,
        "only :issue may move a local invoice from draft to #{next}"
      )
    else
      changeset
    end
  end

  defp current_status(changeset) do
    case changeset.data.status do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:status], authorize?: false).status
      status -> status
    end
  end

  defp status(changeset) do
    case Ash.Changeset.get_attribute(changeset, :status) do
      %Ash.NotLoaded{} -> nil
      status -> status
    end
  end

  defp provider_mirror?(changeset) do
    ref =
      case Ash.Changeset.get_attribute(changeset, :provider_invoice_ref) do
        %Ash.NotLoaded{} -> load_provider_ref(changeset)
        nil -> changeset.data.provider_invoice_ref
        value -> value
      end

    is_binary(ref) and String.trim(ref) != ""
  end

  defp load_provider_ref(changeset) do
    Ash.load!(changeset.data, [:provider_invoice_ref], authorize?: false).provider_invoice_ref
  end

  defp draft?(status), do: status in [nil, :draft, "draft"]

  defp issued?(status) do
    status in [:open, :paid, :uncollectible] or to_string(status) in @issued
  end

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :status, message: message)
  end
end
