defmodule Samen.Scopes.Finance.ApPaymentReversalRecord do
  @moduledoc """
  The durable audit row for one reversal of a paid AP payment run.

  The original run is a closed audit record: it stays `:paid` and immutable.
  A reversal is its own control row, born `:pending_approval` by an admin and
  approved by a DIFFERENT admin. Approval voids each `ap_payment` journal entry
  (the ledger's `:void` transition posts the linked reversing entry) and returns
  the bills to `:approved`, all in one transaction. A run can have at most one
  reversal row; the unique `(org_id, run_id)` index is the database belt.

  Statuses: `:pending_approval`, `:reversed`, `:rejected`, `:cancelled`. The
  trigger refuses a rewritten snapshot/reason, a second decision, a
  self-approval, and every DELETE.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :prv_id}

  @statuses [:pending_approval, :reversed, :rejected, :cancelled]

  schema "prv_ap_payment_reversal" do
    field(:org_id, :binary_id, source: :prv_org_id)
    field(:run_id, :binary_id, source: :prv_run_id)
    field(:reason, :string, source: :prv_reason)

    field(:status, Ecto.Enum,
      values: @statuses,
      default: :pending_approval,
      source: :prv_status
    )

    field(:total_cents, :integer, default: 0, source: :prv_total_cents)
    field(:bill_count, :integer, default: 0, source: :prv_bill_count)

    field(:payments, Samen.Scopes.Finance.ApPaymentRunRecord.Payments,
      default: [],
      source: :prv_payments
    )

    field(:requested_by, :string, source: :prv_requested_by)
    field(:requested_at, :utc_datetime_usec, source: :prv_requested_at)

    field(:approved_by, :string, source: :prv_approved_by)
    field(:approved_at, :utc_datetime_usec, source: :prv_approved_at)
    field(:executed_at, :utc_datetime_usec, source: :prv_executed_at)

    field(:rejected_by, :string, source: :prv_rejected_by)
    field(:rejected_at, :utc_datetime_usec, source: :prv_rejected_at)

    field(:cancelled_by, :string, source: :prv_cancelled_by)
    field(:cancelled_at, :utc_datetime_usec, source: :prv_cancelled_at)

    field(:inserted_at, :utc_datetime_usec,
      source: :prv_inserted_at,
      autogenerate: {__MODULE__, :now, []}
    )

    field(:updated_at, :utc_datetime_usec,
      source: :prv_updated_at,
      autogenerate: {__MODULE__, :now, []}
    )
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc "The request-time changeset; decision fields are written by the service."
  @spec request_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def request_changeset(reversal, attrs) do
    reversal
    |> cast(attrs, [
      :org_id,
      :run_id,
      :reason,
      :status,
      :total_cents,
      :bill_count,
      :payments,
      :requested_by,
      :requested_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :org_id,
      :run_id,
      :reason,
      :status,
      :total_cents,
      :bill_count,
      :payments,
      :requested_by,
      :requested_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:total_cents, greater_than: 0)
    |> validate_number(:bill_count, greater_than: 0)
    |> unique_constraint(:run_id, name: :prv_ap_payment_reversal_org_run_index)
  end
end
