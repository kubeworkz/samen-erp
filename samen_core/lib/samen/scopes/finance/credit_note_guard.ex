defmodule Samen.Scopes.Finance.CreditNoteGuard do
  @moduledoc """
  State and reference guard for Credit Notes and Vendor Credits (WS-ERP E12).

  The guard is intentionally action-based, not status-delta-based: the posting
  change stamps `:open`/`:applied`/`:void` AFTER this guard runs, so comparing
  the pending status to the persisted status would always see the same value.
  The valid edges are:

    * create → `:draft`
    * `:draft` → `:open` (positive amount and a target reference required)
    * `:open` → `:applied` (target reference required)
    * `:draft` or `:open` → `:void`

  On opening, when the host wired the target resource, the reference is read
  fail-honest: it must exist, belong to the same org and owner (customer for a
  credit note, vendor for a vendor credit), and be in an adjustable state.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &validate(&1, opts))
  end

  defp validate(changeset, opts) do
    case action_name(changeset) do
      :create -> validate_create(changeset, opts)
      :update -> require_status(changeset, [:draft], "only a draft adjustment can be edited")
      :open -> validate_open(changeset, opts)
      :apply -> validate_apply(changeset, opts)
      :void -> validate_void(changeset)
      _other -> changeset
    end
  end

  defp validate_create(changeset, opts) do
    with :ok <- positive_amount(changeset),
         :ok <- write_off_reference(changeset, opts) do
      changeset
    else
      {:error, field, message} -> error(changeset, field, message)
    end
  end

  defp validate_open(changeset, opts) do
    with :ok <- require_status(changeset, [:draft], "only a draft adjustment can be opened"),
         :ok <- positive_amount(changeset),
         {:ok, reference_id} <- require_reference(changeset, opts),
         :ok <- verify_reference(changeset, opts, reference_id) do
      changeset
    else
      {:error, field, message} -> error(changeset, field, message)
    end
  end

  defp validate_apply(changeset, opts) do
    with :ok <-
           require_status(changeset, [:open], "only an open adjustment can be applied"),
         {:ok, _reference_id} <- require_reference(changeset, opts) do
      changeset
    else
      {:error, field, message} -> error(changeset, field, message)
    end
  end

  defp validate_void(changeset) do
    case changeset.data.status do
      :draft ->
        changeset

      :open ->
        changeset

      :applied ->
        error(
          changeset,
          :status,
          "an applied adjustment cannot be voided — post a reversing adjustment instead"
        )

      :void ->
        error(changeset, :status, "this adjustment is already void")
    end
  end

  defp positive_amount(changeset) do
    case Ash.Changeset.get_attribute(changeset, :amount_cents) do
      amount when is_integer(amount) and amount > 0 ->
        :ok

      _other ->
        {:error, :amount_cents, "Amount must be a positive integer"}
    end
  end

  defp write_off_reference(changeset, opts) do
    reference = Keyword.fetch!(opts, :reference)

    case {Ash.Changeset.get_attribute(changeset, :kind), get_attr(changeset, reference)} do
      {:write_off, nil} ->
        {:error, reference, "A write-off must name the invoice it writes off"}

      _other ->
        :ok
    end
  end

  defp require_reference(changeset, opts) do
    reference = Keyword.fetch!(opts, :reference)

    case get_attr(changeset, reference) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, reference, reference_message(reference)}
    end
  end

  defp verify_reference(changeset, opts, reference_id) do
    resource = Keyword.get(opts, :reference_resource)
    owner_field = Keyword.fetch!(opts, :owner_field)
    statuses = Keyword.get(opts, :reference_statuses, [])

    cond do
      is_nil(resource) ->
        {:error, Keyword.fetch!(opts, :reference),
         "This host has not wired the #{reference_label(opts)} resource, so the adjustment cannot be opened"}

      true ->
        case Ash.get(resource, reference_id, authorize?: false) do
          {:ok, nil} ->
            {:error, Keyword.fetch!(opts, :reference),
             "The selected #{reference_label(opts)} does not exist"}

          {:error, _reason} ->
            {:error, Keyword.fetch!(opts, :reference),
             "The selected #{reference_label(opts)} could not be read"}

          {:ok, reference} ->
            verify_reference_record(changeset, opts, reference, owner_field, statuses)
        end
    end
  end

  defp verify_reference_record(changeset, opts, reference, owner_field, statuses) do
    org_id = get_attr(changeset, :org_id)
    owner_id = get_attr(changeset, owner_field)
    reference_field = Keyword.fetch!(opts, :reference)
    reference_org = field(reference, :org_id)
    reference_owner = field(reference, owner_field)
    reference_status = field(reference, :status)

    cond do
      reference_org != org_id ->
        {:error, reference_field,
         "The selected #{reference_label(opts)} belongs to a different organization"}

      reference_owner != owner_id ->
        {:error, reference_field,
         "The selected #{reference_label(opts)} belongs to a different #{owner_field}"}

      statuses != [] and reference_status not in statuses ->
        {:error, reference_field,
         "The selected #{reference_label(opts)} is #{inspect(reference_status)} and cannot be adjusted"}

      true ->
        :ok
    end
  end

  defp require_status(changeset, allowed, message) do
    if changeset.data.status in allowed do
      :ok
    else
      {:error, :status, message}
    end
  end

  defp action_name(%{action: %{name: name}}), do: name
  defp action_name(_changeset), do: nil

  defp get_attr(changeset, field) do
    case Ash.Changeset.get_attribute(changeset, field) do
      %Ash.NotLoaded{} -> field(changeset.data, field)
      value -> value
    end
  end

  defp field(record, field) do
    case Map.get(record, field) do
      %Ash.NotLoaded{} ->
        record
        |> Ash.load!([field], authorize?: false)
        |> Map.get(field)

      value ->
        value
    end
  end

  defp reference_label(opts) do
    Keyword.get(opts, :reference_label) ||
      opts
      |> Keyword.fetch!(:reference)
      |> Atom.to_string()
      |> String.replace("_id", "")
      |> String.replace("_", " ")
  end

  defp reference_message(:invoice_id), do: "Choose the invoice this adjustment applies to"
  defp reference_message(:bill_id), do: "Choose the bill this vendor credit applies to"
  defp reference_message(_field), do: "Choose the document this adjustment applies to"

  defp error(changeset, field, message) do
    Ash.Changeset.add_error(changeset, field: field, message: message)
  end
end
