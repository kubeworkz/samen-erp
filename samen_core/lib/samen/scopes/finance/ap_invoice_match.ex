defmodule Samen.Scopes.Finance.ApInvoiceMatch do
  @moduledoc """
  The AP approval-time three-way match gate (WS-ERP gap #9).

  A bill line may carry `po_line_id` and/or `receipt_line_id`. On
  `ApInvoice.:approve`, this change asks `ThreeWayMatch.line_variance/4` for
  the line-level arithmetic using the bill's `match_tolerance_cents` /
  `match_tolerance_pct`, and REFUSES approval when a referenced line bills
  more than the received value plus tolerance. The refusal happens before the
  approval Gate opens, so no pending approval is left behind.

  A line without a PO reference is a non-PO line and is not matched; a
  receipt reference without a PO reference is malformed and refused. A host
  that has no purchasing resources configured fails closed when a bill does
  carry a reference (the alternative — silently approving a claimed match —
  would defeat the control).

  This is deliberately a BLOCK at approval, unlike the vendor-level
  `ThreeWayMatch.variance/4` read, which remains a variance flag. The AP
  control is the gate; the read stays useful for reporting.
  """
  use Ash.Resource.Change

  alias Samen.Scopes.Inventory.ThreeWayMatch

  require Ash.Query

  @config_key __MODULE__

  @impl true
  def change(changeset, _opts, _context) do
    # before_transaction runs before the Gate's own before_transaction hook
    # (declared after this change), so an over-tolerance bill is refused
    # before any pending approval is opened.
    Ash.Changeset.before_transaction(changeset, &match/1)
  end

  @doc """
  Read-only line-level match for the AP detail page.

  Uses the host's configured procurement resources and the bill's own
  tolerance. A bill with no PO/receipt references is not an error: it simply
  returns an empty result with the bill's tolerance so the panel can say that
  three-way matching does not apply. A referenced bill with no host wiring
  returns `{:error, :not_configured}` (fail closed, like approval).
  """
  @spec match(struct(), String.t(), module()) :: {:ok, map()} | {:error, term()}
  def match(bill, org_id, repo) do
    if referenced_line?(bill.lines) do
      with {:ok, resources} <- resources() do
        ThreeWayMatch.line_variance(repo, org_id, bill, resources)
      end
    else
      {:ok,
       %{
         billed_cents: 0,
         received_cents: 0,
         variance_cents: 0,
         tolerance_cents: Map.get(bill, :match_tolerance_cents) || 0,
         tolerance_pct: Map.get(bill, :match_tolerance_pct) || 0,
         flagged?: false,
         lines: []
       }}
    end
  end

  @doc false
  def error_message(reason), do: reason_message(reason)

  defp match(changeset) do
    case reload_bill(changeset) do
      {:ok, bill} ->
        if referenced_line?(bill.lines) do
          do_match(changeset, bill)
        else
          changeset
        end

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "Three-way match could not reload the bill: #{inspect(reason)}"
        )
    end
  end

  # The Gate re-invokes the action from a decision transaction whose changeset
  # data is partial (not every attribute is loaded). Reload from the resource
  # so the org and persisted lines are facts, never a NotLoaded sentinel.
  defp reload_bill(changeset) do
    bill = changeset.data

    changeset.resource
    |> Ash.Query.filter(id == ^bill.id)
    |> Ash.Query.ensure_selected([
      :org_id,
      :vendor_id,
      :lines,
      :match_tolerance_cents,
      :match_tolerance_pct
    ])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_match(changeset, bill) do
    with {:ok, resources} <- resources(),
         {:ok, result} <-
           ThreeWayMatch.line_variance(repo(changeset), bill.org_id, bill, resources) do
      if result.flagged? do
        Ash.Changeset.add_error(changeset, field: :lines, message: variance_message(result))
      else
        changeset
      end
    else
      {:error, :not_configured} ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message:
            "This bill references a purchase order, but three-way matching is not configured on this host."
        )

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "Three-way match failed: #{reason_message(reason)}"
        )
    end
  end

  defp resources do
    case Application.get_env(:samen_core, @config_key) do
      opts when is_list(opts) ->
        with po when is_atom(po) and not is_nil(po) <- Keyword.get(opts, :purchase_order),
             po_line when is_atom(po_line) and not is_nil(po_line) <-
               Keyword.get(opts, :po_line),
             receipt_line when is_atom(receipt_line) and not is_nil(receipt_line) <-
               Keyword.get(opts, :receipt_line) do
          {:ok,
           [
             po_resource: po,
             po_line_resource: po_line,
             receipt_line_resource: receipt_line
           ]}
        else
          _other -> {:error, :not_configured}
        end

      _other ->
        {:error, :not_configured}
    end
  end

  defp repo(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)
  end

  defp referenced_line?(lines) do
    lines
    |> List.wrap()
    |> Enum.any?(fn line ->
      not is_nil(Map.get(line, :po_line_id) || Map.get(line, "po_line_id")) or
        not is_nil(Map.get(line, :receipt_line_id) || Map.get(line, "receipt_line_id"))
    end)
  end

  defp variance_message(result) do
    line = Enum.find(result.lines, & &1.flagged?)

    "Three-way match failed on line #{line.line}: billed #{money(line.billed_cents)} " <>
      "against #{money(line.received_cents)} received (variance #{money(line.variance_cents)} " <>
      "> tolerance #{money(line.tolerance_cents)}). Attach a receipt or raise the bill tolerance " <>
      "before approving."
  end

  defp reason_message({:po_line_not_found, id}),
    do: "PO line #{id} was not found in this organization"

  defp reason_message({:purchase_order_not_found, id}),
    do: "the purchase order behind PO line #{id} was not found in this organization"

  defp reason_message({:vendor_mismatch, po_id}),
    do: "PO #{po_id} belongs to a different vendor than this bill"

  defp reason_message({:receipt_line_not_found, id}),
    do: "receipt line #{id} was not found in this organization"

  defp reason_message({:receipt_line_mismatch, id}),
    do: "receipt line #{id} does not belong to the referenced PO line"

  defp reason_message({:receipt_without_po_line, id}),
    do: "receipt line #{id} is referenced without a PO line"

  defp reason_message(other), do: inspect(other)

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)
end
