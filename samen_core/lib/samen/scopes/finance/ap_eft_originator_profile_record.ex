defmodule Samen.Scopes.Finance.ApEftOriginatorProfileRecord do
  @moduledoc """
  The durable **TD Business Central EFT originator profile** for one
  `{org, bank, environment}`.

  This is a kernel **control table**, not a tenant catalog resource. It holds the
  bank-assigned facts a CPA-005 file needs that must never be caller input:

    * the 10-digit TD client (originator) number;
    * the destination data centre (`00420` for TD);
    * the `0004` + 5-digit transit return institution;
    * the 11-digit TD Commercial return account, stored ONLY as a `vt_*` vault
      token (`pii_eop_return_account`);
    * the ASCII/CRLF framing the profile was certified with;
    * the next file creation number (FCN), allocated by
      `Samen.Scopes.Finance.ApEftOriginatorProfile`.

  Test and production are separate rows with independent FCN sequences, so a
  test upload can never advance the production counter. The environment is
  immutable and rows are never deleted — a deleted production row would reset
  the FCN to `0001` and invite a duplicate file.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :eop_id}
  @foreign_key_type :binary_id

  @environments [:test, :production]
  @bank "td_business_central"
  @destination_data_centre "00420"
  @encoding "ascii"
  @record_separator "crlf"

  schema "eop_ap_eft_originator_profile" do
    field(:org_id, :binary_id, source: :eop_org_id)
    field(:bank, :string, source: :eop_bank, default: @bank)

    field(:environment, Ecto.Enum,
      values: @environments,
      source: :eop_environment
    )

    field(:client_number, :string, source: :eop_client_number)

    field(:destination_data_centre, :string,
      source: :eop_destination_data_centre,
      default: @destination_data_centre
    )

    field(:return_institution, :string, source: :eop_return_institution)
    # 🔒 Vault token, never the plaintext return account.
    field(:return_account, :string, source: :pii_eop_return_account)

    field(:next_file_creation_number, :integer,
      source: :eop_next_file_creation_number,
      default: 1
    )

    field(:encoding, :string, source: :eop_encoding, default: @encoding)
    field(:record_separator, :string, source: :eop_record_separator, default: @record_separator)

    field(:inserted_at, :utc_datetime_usec,
      source: :eop_inserted_at,
      autogenerate: {__MODULE__, :now, []}
    )

    field(:updated_at, :utc_datetime_usec,
      source: :eop_updated_at,
      autogenerate: {__MODULE__, :now, []}
    )
  end

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @doc false
  def environments, do: @environments

  @doc false
  def bank, do: @bank

  @doc false
  def default_destination_data_centre, do: @destination_data_centre

  @doc "The first write: the org, bank and environment state their profile."
  @spec configure_changeset(map()) :: Ecto.Changeset.t()
  def configure_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :org_id,
      :bank,
      :environment,
      :client_number,
      :destination_data_centre,
      :return_institution,
      :return_account,
      :next_file_creation_number,
      :encoding,
      :record_separator
    ])
    |> validate_required([
      :id,
      :org_id,
      :bank,
      :environment,
      :client_number,
      :destination_data_centre,
      :return_institution,
      :return_account,
      :next_file_creation_number,
      :encoding,
      :record_separator
    ])
    |> validate_inclusion(:environment, @environments)
    |> validate_inclusion(:bank, [@bank])
    |> validate_format(:client_number, ~r/\A[0-9]{10}\z/)
    |> validate_inclusion(:destination_data_centre, [@destination_data_centre])
    |> validate_format(:return_institution, ~r/\A0004[0-9]{5}\z/)
    |> validate_vault_token(:return_account)
    |> validate_number(:next_file_creation_number,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 9999
    )
    |> validate_inclusion(:encoding, [@encoding])
    |> validate_inclusion(:record_separator, [@record_separator])
    |> unique_constraint([:org_id, :bank, :environment],
      name: :eop_ap_eft_originator_profile_org_bank_environment_index
    )
  end

  @doc """
  An update may correct TD-assigned fields, but never the environment.

  The database trigger refuses the same write; this changeset refuses it first
  so a caller gets a changeset error rather than a raw Postgres exception.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(profile, attrs) do
    if Map.has_key?(attrs, :environment) and
         to_string(Map.get(attrs, :environment)) != to_string(profile.environment) do
      profile
      |> change()
      |> add_error(:environment, "is immutable")
    else
      profile
      |> cast(attrs, [
        :client_number,
        :destination_data_centre,
        :return_institution,
        :return_account,
        :updated_at
      ])
      |> validate_required([:client_number, :destination_data_centre, :return_institution])
      |> validate_format(:client_number, ~r/\A[0-9]{10}\z/)
      |> validate_inclusion(:destination_data_centre, [@destination_data_centre])
      |> validate_format(:return_institution, ~r/\A0004[0-9]{5}\z/)
      |> validate_vault_token(:return_account)
    end
  end

  @doc "The FCN advance written by the allocator under a row lock."
  @spec allocate_changeset(%__MODULE__{}, pos_integer()) :: Ecto.Changeset.t()
  def allocate_changeset(profile, next) do
    profile
    |> cast(%{next_file_creation_number: next, updated_at: now()}, [
      :next_file_creation_number,
      :updated_at
    ])
    |> validate_required([:next_file_creation_number, :updated_at])
    |> validate_number(:next_file_creation_number,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 9999
    )
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
