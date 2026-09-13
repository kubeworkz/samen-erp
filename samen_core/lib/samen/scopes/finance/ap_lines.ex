defmodule Samen.Scopes.Finance.ApLines do
  @moduledoc """
  The `ApInvoice` line-shape + state guard (WS-ERP E2; design §2.2).

  * LINE SHAPE: a bill carries at least one line and every `amount_cents` is a
    POSITIVE integer (an AP bill is what the vendor demands; credits are
    separate bills or the P2 credit-note carry, never a negative line). The
    embedded-argument constraints type the fields; this guard owns the business
    conditions the type system cannot express.
  * STATE: `lines`/`due_date`/`memo` are editable only while the bill is a
    DRAFT — `:approve`'s posted entry makes the bill a governed fact and
    immutability is the migration's trigger (the belt). A re-approval (or a
    `:pay`/`:void`-shaped second decide) is refused here exactly like E1's
    one-way state machine — the exactly-once mechanism behind the Gate's
    re-invocation.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # STATE (on the transition actions — before any write):
    changeset =
      if action == :approve do
        case Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status do
          :draft ->
            changeset

          other ->
            Ash.Changeset.add_error(changeset,
              field: :status,
              message:
                "illegal approve transition: the bill is #{inspect(other)} — only a :draft " <>
                  "bill can be approved (one-way state machine)"
            )
        end
      else
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

              if is_integer(amount) and amount > 0 do
                acc
              else
                Ash.Changeset.add_error(acc,
                  field: :lines,
                  message:
                    "every AP line amount_cents must be a positive integer (credits are " <>
                      "separate bills; the P2 credit-note carry) — got: #{inspect(amount)}"
                )
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
end
