defmodule Samen.Scopes.Finance.VendorPaymentProfileRecord do
  @moduledoc """
  The durable bank profile for ONE vendor: the payee account an AP payment is
  wired to.

  This is a kernel **control table**, not a tenant catalog resource — the same
  posture as `Samen.Scopes.Finance.ApPaymentRunRecord`. The account number and
  routing number are stored ONLY as `vt_*` vault tokens
  (`pii_fvp_account_number`, `pii_fvp_routing_number`) encrypted under the
  profile row's own subject key; plaintext exists only transiently inside
  `Samen.Vault.reveal/3`, called by
  `Samen.Scopes.Finance.VendorPaymentProfile.payment_details/2` after the
  profile is verified.

  ## Verification and change control

  A profile is born `:unverified`. `:verified` records WHO verified the bank
  details and WHEN, and the database trigger refuses a verification by the same
  principal that registered/changed them (`verified_by = changed_by`). Any
  change to a bank detail must reset the profile to `:unverified` and clear the
  verification evidence in the SAME update — the trigger refuses the write
  otherwise — so a changed account can never keep spending under the old
  verification. Rows are never deleted: a vendee whose account changes gets a
  new change-of-details update, not a replacement row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :fvp_id}
  @foreign_key_type :binary_id

  @statuses [:unverified, :verified]
  @account_types [:checking, :savings]
  @rails [:ach_usd, :eft_cad]

  schema "fvp_vendor_payment_profile" do
    field(:org_id, :binary_id, source: :fvp_org_id)
    field(:vendor_id, :binary_id, source: :fvp_vendor_id)
    field(:bank_name, :string, source: :fvp_bank_name)
    field(:account_holder, :string, source: :fvp_account_holder)

    field(:rail, Ecto.Enum, values: @rails, default: :ach_usd, source: :fvp_rail)

    field(:account_type, Ecto.Enum,
      values: @account_types,
      default: :checking,
      source: :fvp_account_type
    )

    # 🔒 Vault tokens, never plaintext.
    field(:account_number, :string, source: :pii_fvp_account_number)
    field(:routing_number, :string, source: :pii_fvp_routing_number)
    field(:institution_number, :string, source: :pii_fvp_institution_number)
    field(:transit_number, :string, source: :pii_fvp_transit_number)

    # The only plaintext fragments, for the UI's recognition cue. The CAD
    # institution fingerprint is the three significant digits; the transit
    # fingerprint is its last four.
    field(:account_last4, :string, source: :fvp_account_last4)
    field(:institution_last4, :string, source: :fvp_institution_last4)
    field(:transit_last4, :string, source: :fvp_transit_last4)

    field(:status, Ecto.Enum, values: @statuses, default: :unverified, source: :fvp_status)

    field(:changed_by, :string, source: :fvp_changed_by)
    field(:changed_at, :utc_datetime_usec, source: :fvp_changed_at)
    field(:verified_by, :string, source: :fvp_verified_by)
    field(:verified_at, :utc_datetime_usec, source: :fvp_verified_at)

    field(:inserted_at, :utc_datetime_usec,
      source: :fvp_inserted_at,
      autogenerate: {__MODULE__, :now, []}
    )

    field(:updated_at, :utc_datetime_usec,
      source: :fvp_updated_at,
      autogenerate: {__MODULE__, :now, []}
    )
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc false
  def statuses, do: @statuses

  @doc false
  def account_types, do: @account_types

  @doc false
  def rails, do: @rails

  @doc "The first write: born unverified, with WHO registered the details."
  @spec register_changeset(map()) :: Ecto.Changeset.t()
  def register_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :org_id,
      :vendor_id,
      :rail,
      :bank_name,
      :account_holder,
      :account_type,
      :account_number,
      :routing_number,
      :institution_number,
      :transit_number,
      :account_last4,
      :institution_last4,
      :transit_last4,
      :status,
      :changed_by,
      :changed_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :org_id,
      :vendor_id,
      :rail,
      :account_holder,
      :account_type,
      :status,
      :changed_by,
      :changed_at
    ])
    |> validate_inclusion(:status, [:unverified])
    |> validate_inclusion(:account_type, @account_types)
    |> validate_inclusion(:rail, @rails)
    |> validate_rail_details()
    |> unique_constraint([:org_id, :vendor_id, :rail],
      name: :fvp_vendor_payment_profile_org_vendor_rail_index
    )
  end

  @doc """
  A bank-detail change: always resets verification and records the changer.

  The reset is written HERE (not left to the caller) because the DB trigger
  refuses a bank-detail change that keeps the old verification.
  """
  @spec change_details_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def change_details_changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :bank_name,
      :account_holder,
      :account_type,
      :account_number,
      :routing_number,
      :institution_number,
      :transit_number,
      :account_last4,
      :institution_last4,
      :transit_last4,
      :changed_by,
      :changed_at,
      :updated_at
    ])
    |> validate_required([
      :account_holder,
      :account_type,
      :account_number,
      :account_last4,
      :changed_by,
      :changed_at
    ])
    |> validate_inclusion(:account_type, @account_types)
    |> validate_rail_details()
    |> put_change(:status, :unverified)
    |> put_change(:verified_by, nil)
    |> put_change(:verified_at, nil)
  end

  @doc "The distinct-party verification transition."
  @spec verify_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def verify_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:status, :verified_by, :verified_at, :updated_at])
    |> validate_required([:status, :verified_by, :verified_at])
    |> validate_inclusion(:status, [:verified])
  end

  # The rail decides which bank identifiers exist. ACH rows carry a vaulted
  # routing number and no CAD branch fields; CAD rows carry vaulted institution
  # and transit numbers and no routing number. The database check is the second
  # belt; this keeps a bad changeset from ever reaching it.
  defp validate_rail_details(changeset) do
    case get_field(changeset, :rail) || :ach_usd do
      :ach_usd ->
        changeset
        |> validate_required([:account_number, :routing_number, :account_last4])
        |> validate_vault_token(:account_number)
        |> validate_vault_token(:routing_number)
        |> reject_unless_empty([
          :institution_number,
          :transit_number,
          :institution_last4,
          :transit_last4
        ])

      :eft_cad ->
        changeset
        |> validate_required([
          :account_number,
          :institution_number,
          :transit_number,
          :account_last4,
          :institution_last4,
          :transit_last4
        ])
        |> validate_vault_token(:account_number)
        |> validate_vault_token(:institution_number)
        |> validate_vault_token(:transit_number)
        |> reject_unless_empty([:routing_number])
    end
  end

  defp reject_unless_empty(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        nil -> acc
        _value -> add_error(acc, field, "must be empty on this rail")
      end
    end)
  end

  defp validate_vault_token(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      token when is_binary(token) ->
        if String.starts_with?(token, "vt_") do
          changeset
        else
          add_error(changeset, field, "must be a vault token")
        end

      _other ->
        add_error(changeset, field, "must be a vault token")
    end
  end
end
