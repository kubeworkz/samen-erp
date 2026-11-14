defmodule Samen.Scopes.Finance.ApLines do
  @moduledoc """
  The `ApInvoice` line-shape + state guard (WS-ERP E2; design §2.2).

  * LINE SHAPE: a bill carries at least one line and every `amount_cents` is a
    POSITIVE integer (an AP bill is what the vendor demands; credits are
    separate bills or the P2 credit-note carry, never a negative line). A
    `receipt_line_id` without the matching `po_line_id` is malformed and
    refused before the approval gate has to discover it. The
    embedded-argument constraints type the fields; this guard owns the
    business conditions the type system cannot express.
  * STATE: `lines`/`due_date`/`memo` are editable only while the bill is a
    DRAFT — `:approve`'s posted entry makes the bill a governed fact and
    immutability is the migration's trigger (the belt). A re-approval is
    refused here exactly like E1's one-way state machine — the exactly-once
    mechanism behind the Gate's re-invocation. `:pay` and `:void` are the legal
    transitions after approval; `:pay` requires the persisted bill to still be
    `:approved` (a second payment is refused), and `:void` is governed by
    `VoidApInvoice`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # STATE (on the transition actions — before any write):
    changeset =
      case action do
        :approve ->
          require_status(
            changeset,
            :draft,
            "illegal approve transition: the bill is %s — only a :draft bill can be " <>
              "approved (one-way state machine)"
          )

        :pay ->
          require_status(
            changeset,
            :approved,
            "illegal pay transition: the bill is %s — only an :approved bill can be paid"
          )

        _other ->
          changeset
      end

    # LINE SHAPE (on every action accepting `lines` — an ATTRIBUTE in the
    # blueprint, so the pending value is read with get_attribute, not
    # get_argument). add_error RETURNS a new changeset — it is re-bound, not
    # called for side effect.
    changeset =
      if action in [:create, :update] do
        case Ash.Changeset.get_attribute(changeset, :lines) do
          nil ->
            # An :update without `lines` edits other fields only; the record's
            # own lines were shape-guarded when written.
            changeset

          [] ->
            Ash.Changeset.add_error(changeset,
              field: :lines,
              message: "an AP bill carries at least one line"
            )

          lines when is_list(lines) ->
            Enum.reduce(lines, changeset, fn line, acc ->
              amount = Map.get(line, :amount_cents) || Map.get(line, "amount_cents")
              po_line_id = Map.get(line, :po_line_id) || Map.get(line, "po_line_id")

              receipt_line_id =
                Map.get(line, :receipt_line_id) || Map.get(line, "receipt_line_id")

              cond do
                not (is_integer(amount) and amount > 0) ->
                  Ash.Changeset.add_error(acc,
                    field: :lines,
                    message:
                      "every AP line amount_cents must be a positive integer (credits are " <>
                        "separate bills; the P2 credit-note carry) — got: #{inspect(amount)}"
                  )

                is_nil(po_line_id) and not is_nil(receipt_line_id) ->
                  Ash.Changeset.add_error(acc,
                    field: :lines,
                    message:
                      "an AP line may not carry receipt_line_id without po_line_id — got: " <>
                        inspect(receipt_line_id)
                  )

                true ->
                  acc
              end
            end)

          _other ->
            changeset
        end
      else
        changeset
      end

    changeset
  end

  defp require_status(changeset, expected, message) do
    case Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status do
      ^expected ->
        changeset

      other ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: String.replace(message, "%s", inspect(other))
        )
    end
  end
end
