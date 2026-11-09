defmodule Samen.Scopes.Finance.ApPaymentRunRecord do
  @moduledoc """
  The durable audit row for one AP payment run.

  This is a kernel **control table**, not a tenant catalog resource: it records
  who requested a run, the exact bill snapshot they requested, who approved or
  rejected it (always a different party), and the remittance CSV that the
  approval produced. The table's database trigger refuses a self-approved run,
  a rewritten snapshot, and every DELETE, so the row remains the audit trail
  even below the service that writes it.

  A run is born `:pending_approval`; the only decisions are `:paid` (the
  approval posted every bill), `:rejected` (a different admin refused it), and
  `:cancelled` (the requester withdrew it). `payments` is the immutable
  request-time snapshot — `bill_id`, `number`, `due_date`, `amount_cents` — so
  the  approved amounts cannot drift from the bills that were reviewed.
  `vendor_name` and `remittance_address` are the optional payee details the
  requester captured with the request; they are frozen with the rest of the
  snapshot so the printed advice keeps showing what was reviewed.
  """

  defmodule Payments do
    @moduledoc false
    use Ecto.Type

    @impl true
    def type, do: :map

    @impl true
    def cast(value) when is_list(value) do
      if Enum.all?(value, &is_map/1), do: {:ok, value}, else: :error
    end

    def cast(_value), do: :error

    @impl true
    def load(value) when is_list(value), do: {:ok, value}
    def load(_value), do: :error

    @impl true
    def dump(value) when is_list(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :prn_id}
  @foreign_key_type :binary_id

  @statuses [:pending_approval, :paid, :rejected, :cancelled]

  schema "prn_ap_payment_run" do
    field(:org_id, :binary_id, source: :prn_org_id)
    field(:reference, :string, source: :prn_reference)
    field(:vendor_id, :binary_id, source: :prn_vendor_id)
    field(:vendor_name, :string, source: :prn_vendor_name)
    field(:remittance_address, :string, source: :prn_remittance_address)
    field(:payment_date, :date, source: :prn_payment_date)
    field(:memo, :string, source: :prn_memo)

    field(:status, Ecto.Enum, values: @statuses, default: :pending_approval, source: :prn_status)
    field(:total_cents, :integer, default: 0, source: :prn_total_cents)
    field(:bill_count, :integer, default: 0, source: :prn_bill_count)
    field(:payments, Payments, default: [], source: :prn_payments)
    field(:remittance_csv, :string, source: :prn_remittance_csv)

    field(:requested_by, :string, source: :prn_requested_by)
    field(:requested_at, :utc_datetime_usec, source: :prn_requested_at)

    field(:approved_by, :string, source: :prn_approved_by)
    field(:approved_at, :utc_datetime_usec, source: :prn_approved_at)
    field(:executed_at, :utc_datetime_usec, source: :prn_executed_at)

    field(:rejected_by, :string, source: :prn_rejected_by)
    field(:rejected_at, :utc_datetime_usec, source: :prn_rejected_at)

    field(:cancelled_by, :string, source: :prn_cancelled_by)
    field(:cancelled_at, :utc_datetime_usec, source: :prn_cancelled_at)

    field(:inserted_at, :utc_datetime_usec,
      source: :prn_inserted_at,
      autogenerate: {__MODULE__, :now, []}
    )

    field(:updated_at, :utc_datetime_usec,
      source: :prn_updated_at,
      autogenerate: {__MODULE__, :now, []}
    )
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc """
  The request-time changeset. Only the request fields are cast; decision
  fields are written by the service's approval/rejection transitions.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :org_id,
      :reference,
      :vendor_id,
      :vendor_name,
      :remittance_address,
      :payment_date,
      :memo,
      :status,
      :total_cents,
      :bill_count,
      :payments,
      :requested_by,
      :requested_at
    ])
    |> validate_required([
      :org_id,
      :reference,
      :vendor_id,
      :payment_date,
      :status,
      :total_cents,
      :bill_count,
      :payments,
      :requested_by,
      :requested_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:total_cents, greater_than: 0)
    |> validate_number(:bill_count, greater_than: 0)
    |> unique_constraint(:reference, name: :prn_ap_payment_run_org_reference_index)
  end
end
