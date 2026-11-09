defmodule Samen.Scopes.Finance.ApAchArtifactRecord do
  @moduledoc """
  The durable audit row for one generated NACHA ACH file.

  This is a kernel **control table**, not a tenant catalog resource: it records
  which paid run produced the file, who generated it and when, the file's
  SHA-256 digest, the originator fields the operator used, and a fingerprint of
  the receiver (name + account/routing last four). The file itself contains
  plaintext bank account and routing numbers, so it is stored ONLY as a vault
  token in `ach_file_token`; `ach_file` is never a column.

  Rows are append-only: the trigger refuses every UPDATE and DELETE, so a
  generated file cannot be rewritten or removed below the service. A run may
  have more than one artifact (for example, a regenerated file with different
  originator details), which is why the row is not unique per run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :ach_id}

  schema "ach_ap_payment_ach_file" do
    field(:org_id, :binary_id, source: :ach_org_id)
    field(:run_id, :binary_id, source: :ach_run_id)
    field(:name, :string, source: :ach_name)
    field(:digest, :string, source: :ach_digest)
    field(:file_token, :string, source: :ach_file_token)
    field(:size_bytes, :integer, source: :ach_size_bytes)
    field(:originator_name, :string, source: :ach_originator_name)
    field(:originator_id, :string, source: :ach_originator_id)
    field(:originator_dfi_last4, :string, source: :ach_originator_dfi_last4)
    field(:receiver_name, :string, source: :ach_receiver_name)
    field(:receiver_account_last4, :string, source: :ach_receiver_account_last4)
    field(:receiver_routing_last4, :string, source: :ach_receiver_routing_last4)
    field(:generated_by, :string, source: :ach_generated_by)
    field(:generated_at, :utc_datetime_usec, source: :ach_generated_at)

    field(:inserted_at, :utc_datetime_usec,
      source: :ach_inserted_at,
      autogenerate: {__MODULE__, :now, []}
    )
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc false
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      # The service mints the id BEFORE storing the vault token under that id,
      # so the inserted row must keep it — a regenerated id would not match
      # the token's subject and every reveal would be refused.
      :id,
      :org_id,
      :run_id,
      :name,
      :digest,
      :file_token,
      :size_bytes,
      :originator_name,
      :originator_id,
      :originator_dfi_last4,
      :receiver_name,
      :receiver_account_last4,
      :receiver_routing_last4,
      :generated_by,
      :generated_at,
      :inserted_at
    ])
    |> validate_required([
      :id,
      :org_id,
      :run_id,
      :name,
      :digest,
      :file_token,
      :size_bytes,
      :generated_by,
      :generated_at,
      :inserted_at
    ])
    |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:file_token, ~r/\Avt_/)
    |> validate_number(:size_bytes, greater_than: 0)
  end
end
