defmodule Samen.Scopes.Finance.VendorPaymentProfile do
  @moduledoc """
  The **vendor payment profile**: the verified bank account an AP payment run
  sends money to, on one of two rails.

  ## Why this is not a caller-supplied ACH/EFT field

  A NACHA or CPA-005 file routes money. Letting the payment form accept a
  vendor's routing/account (ACH) or institution/transit/account (CAD) per run
  means the payment rail's destination is whatever the operator typed that
  minute — there is no record of what account the vendor registered, no second
  pair of eyes on it, and no way to notice that a familiar vendor's account
  silently changed (the classic BEC / invoice-fraud pattern). This module makes
  the destination a durable, org-pinned fact:

    * `register/1` stores the account and the rail's routing identifiers as
      vault tokens (`Samen.Vault.store_fields/4`) under the profile row's own
      DEK; plaintext never lands in a column.
    * `prevalidate/2` enforces the rail's rules BEFORE anything is stored: the
      ABA checksum and 17-character ACH account, or a 3-digit institution,
      5-digit transit and 12-character CAD account.
    * `verify/1` requires an admin/owner who is a **different principal** from
      the one that registered or last changed the details. The database trigger
      is the second belt.
    * `change_bank_details/1` stores new tokens and resets the profile to
      `:unverified` in the same update, clearing the old evidence. The rail
      itself is immutable: a different rail is a different profile row, never a
      rewrite of a verified ACH account into a CAD account.
    * `payment_details/2` is the ONLY read that returns plaintext, and it
      refuses an unverified profile. `ApAchFile` and `ApEftFile` are rendered
      from this map, so the destination is always the verified profile — never
      caller input.

  ## Org and rail pinning

  Every lookup is `(org_id, vendor_id, rail)`-pinned from the caller's
  `Samen.Scope`, not from a client-supplied org. A vendor profile from another
  tenant or the other rail is invisible (`{:ok, nil}`), exactly like an Ash read
  under `OrgScope`. One vendor may hold both a USD ACH profile and a CAD EFT
  profile; no lookup or render falls back from one rail to the other.
  """

  alias Samen.Scopes.Finance.ApAchFile
  alias Samen.Scopes.Finance.VendorPaymentProfileRecord, as: Record
  alias Samen.Vault

  @vault :pii_bank
  @max_account_length 17
  @max_cad_account_length 12
  @max_holder_length 22
  @rails [:ach_usd, :eft_cad]

  @type profile :: Record.t()

  @doc """
  Read one org/rail-pinned profile. Returns `{:ok, nil}` when the vendor has no
  profile on that rail. The default rail is `:ach_usd`, so existing callers keep
  their behavior.
  """
  @spec get(module(), String.t(), String.t(), atom() | String.t()) ::
          {:ok, profile() | nil} | {:error, term()}
  def get(repo, org_id, vendor_id, rail \\ :ach_usd)

  def get(repo, org_id, vendor_id, rail) when is_binary(org_id) and is_binary(vendor_id) do
    with {:ok, rail} <- normalize_rail(rail) do
      {:ok, repo.get_by(Record, org_id: org_id, vendor_id: vendor_id, rail: rail)}
    end
  rescue
    error -> {:error, {:read_failed, error}}
  end

  def get(_repo, _org_id, _vendor_id, _rail), do: {:error, :vendor_required}

  @doc """
  The org's profiles, for a vendor picker. Newest first. Pass a rail to narrow.
  """
  @spec list(module(), String.t(), atom() | nil) :: [profile()]
  def list(repo, org_id, rail \\ nil) when is_binary(org_id) do
    import Ecto.Query

    query =
      from(p in Record,
        where: p.org_id == ^org_id,
        order_by: [desc: p.updated_at]
      )

    query =
      case rail do
        nil ->
          query

        rail ->
          case normalize_rail(rail) do
            {:ok, rail} -> where(query, [p], p.rail == ^rail)
            {:error, _reason} -> where(query, [p], false)
          end
      end

    repo.all(query)
  rescue
    _error -> []
  end

  @doc """
  Prevalidate bank details before storing them.

  `rail` defaults to `:ach_usd`. ACH requires an ABA-valid 9-digit routing
  number and an alphanumeric account of at most 17 characters; CAD requires a
  3-digit institution, 5-digit transit and an alphanumeric account of at most
  12 characters. Accounts are never truncated — a shortened account is the
  wrong account.
  """
  @spec prevalidate(keyword() | map(), atom() | String.t()) ::
          {:ok, map()} | {:error, term()}
  def prevalidate(attrs, rail \\ :ach_usd)

  def prevalidate(attrs, rail) when is_list(attrs), do: prevalidate(Map.new(attrs), rail)

  def prevalidate(attrs, rail) when is_map(attrs) do
    case normalize_rail(rail) do
      {:ok, :ach_usd} -> prevalidate_ach(attrs)
      {:ok, :eft_cad} -> prevalidate_cad(attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Register a vendor's bank details as a new `:unverified` profile on `rail`.

  Options: `:repo`, `:scope`, `:vendor_id` (all required), `:rail` (default
  `:ach_usd`), plus the rail's bank fields. Refuses a second profile for the
  same `{org, vendor, rail}` (`:already_registered`) — a change is
  `change_bank_details/1`, so the row keeps its history.
  """
  @spec register(keyword()) :: {:ok, profile()} | {:error, term()}
  def register(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    rail = Keyword.get(opts, :rail, :ach_usd)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- actor_id(scope),
         {:ok, vendor_id} <- uuid(Keyword.get(opts, :vendor_id)),
         {:ok, rail} <- normalize_rail(rail),
         {:ok, details} <- prevalidate(opts, rail),
         :ok <- absent(repo, org_id, vendor_id, rail) do
      id = Ecto.UUID.generate()
      now = Record.now()

      attrs = %{
        # The row id IS the vault subject id: `store_tokens!` encrypts under it.
        id: id,
        org_id: org_id,
        vendor_id: vendor_id,
        rail: rail,
        bank_name: details.bank_name,
        account_holder: details.account_holder,
        account_type: details.account_type,
        account_last4: details.account_last4,
        institution_last4: Map.get(details, :institution_last4),
        transit_last4: Map.get(details, :transit_last4),
        status: :unverified,
        changed_by: actor,
        changed_at: now,
        updated_at: now
      }

      repo.transaction(fn ->
        attrs = Map.merge(attrs, store_tokens!(repo, id, details))

        case Record.register_changeset(attrs) |> repo.insert() do
          {:ok, profile} -> profile
          {:error, changeset} -> repo.rollback({:insert_failed, changeset})
        end
      end)
    end
  end

  @doc """
  Replace a vendor's bank details on `rail` and reset verification.

  Options: `:repo`, `:scope`, `:vendor_id`, `:rail` (default `:ach_usd`) plus
  the rail's bank fields. The row keeps its identity and history; the previous
  vault ciphertext is left untouched, the new tokens are written, and the
  profile becomes `:unverified` with cleared evidence in the same update. The
  rail is never changed by this call.
  """
  @spec change_bank_details(keyword()) :: {:ok, profile()} | {:error, term()}
  def change_bank_details(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    rail = Keyword.get(opts, :rail, :ach_usd)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- actor_id(scope),
         {:ok, vendor_id} <- uuid(Keyword.get(opts, :vendor_id)),
         {:ok, rail} <- normalize_rail(rail),
         {:ok, details} <- prevalidate(opts, rail),
         {:ok, %Record{} = profile} <- fetch(repo, org_id, vendor_id, rail) do
      now = Record.now()

      attrs = %{
        bank_name: details.bank_name,
        account_holder: details.account_holder,
        account_type: details.account_type,
        account_last4: details.account_last4,
        institution_last4: Map.get(details, :institution_last4),
        transit_last4: Map.get(details, :transit_last4),
        changed_by: actor,
        changed_at: now,
        updated_at: now
      }

      repo.transaction(fn ->
        attrs = Map.merge(attrs, store_tokens!(repo, profile.id, details))

        case profile |> Record.change_details_changeset(attrs) |> repo.update() do
          {:ok, updated} -> updated
          {:error, changeset} -> repo.rollback({:update_failed, changeset})
        end
      end)
    end
  end

  @doc """
  Verify a profile on `rail` as an admin/owner who is NOT the principal that
  registered or last changed its bank details.

  Returns `{:error, :self_verification}` for the same principal,
  `{:error, :already_verified}` for a verified profile, and
  `{:error, :forbidden}` for a non-admin.
  """
  @spec verify(keyword()) :: {:ok, profile()} | {:error, term()}
  def verify(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    rail = Keyword.get(opts, :rail, :ach_usd)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- admin_id(scope),
         {:ok, vendor_id} <- uuid(Keyword.get(opts, :vendor_id)),
         {:ok, rail} <- normalize_rail(rail),
         {:ok, %Record{} = profile} <- fetch(repo, org_id, vendor_id, rail),
         :ok <- verify_allowed(profile, actor) do
      now = Record.now()

      case profile
           |> Record.verify_changeset(%{
             status: :verified,
             verified_by: actor,
             verified_at: now,
             updated_at: now
           })
           |> repo.update() do
        {:ok, verified} -> {:ok, verified}
        {:error, changeset} -> {:error, {:update_failed, changeset}}
      end
    end
  end

  @doc """
  The verified profile's rail-specific receiver fields, with plaintext revealed
  through the ONE vault chokepoint.

  ACH returns `%{receiver_name, receiver_account, receiver_dfi, account_type,
  rail: :ach_usd}`; CAD returns `%{receiver_name, receiver_account,
  receiver_institution, receiver_transit, account_type, rail: :eft_cad}`.
  Refuses an unverified profile (`{:error, :unverified}`) and a shredded key
  (`{:error, :shredded}`) rather than sending money to a stale destination.
  """
  @spec payment_details(profile(), module()) :: {:ok, map()} | {:error, term()}
  def payment_details(%Record{status: :verified, rail: :ach_usd} = profile, repo) do
    with {:ok, account} <- reveal(profile.account_number, :account_number, profile, repo),
         {:ok, routing} <- reveal(profile.routing_number, :routing_number, profile, repo) do
      {:ok,
       %{
         receiver_name: profile.account_holder,
         receiver_account: account,
         receiver_dfi: routing,
         account_type: profile.account_type,
         rail: :ach_usd
       }}
    end
  end

  def payment_details(%Record{status: :verified, rail: :eft_cad} = profile, repo) do
    with {:ok, account} <- reveal(profile.account_number, :account_number, profile, repo),
         {:ok, institution} <-
           reveal(profile.institution_number, :institution_number, profile, repo),
         {:ok, transit} <- reveal(profile.transit_number, :transit_number, profile, repo) do
      {:ok,
       %{
         receiver_name: profile.account_holder,
         receiver_account: account,
         receiver_institution: institution,
         receiver_transit: transit,
         account_type: profile.account_type,
         rail: :eft_cad
       }}
    end
  end

  def payment_details(%Record{}, _repo), do: {:error, :unverified}

  @doc "Whether `actor_id` may verify this profile (a different principal)."
  @spec verifiable_by?(profile(), String.t() | nil) :: boolean()
  def verifiable_by?(%Record{status: :unverified, changed_by: changed_by}, actor_id) do
    is_binary(actor_id) and actor_id != changed_by
  end

  def verifiable_by?(_profile, _actor_id), do: false

  # -- storage ----------------------------------------------------------------

  defp store_tokens!(repo, id, details) do
    fields =
      case details.rail do
        :ach_usd ->
          [
            account_number: details.account_number,
            routing_number: details.routing_number
          ]

        :eft_cad ->
          [
            account_number: details.account_number,
            institution_number: details.institution_number,
            transit_number: details.transit_number
          ]
      end

    case Vault.store_fields(id, @vault, fields, repo) do
      {:ok, tokens} ->
        tokens
        |> Map.take([:account_number, :routing_number, :institution_number, :transit_number])
        |> Map.new()

      {:error, reason} ->
        repo.rollback({:vault_failed, reason})
    end
  end

  defp reveal(token, label, profile, repo) when is_binary(token) do
    token
    |> masked(label)
    |> Vault.reveal(repo, subject_id: profile.id)
  end

  defp reveal(_token, _label, _profile, _repo), do: {:error, :not_found}

  defp masked(token, label), do: %Samen.Masked{token: token, label: label}

  # -- prevalidation ----------------------------------------------------------

  defp prevalidate_ach(attrs) do
    bank_name = normalize(attrs[:bank_name])
    holder = normalize(attrs[:account_holder])
    account = normalize(attrs[:account_number])
    routing = normalize_routing(attrs[:routing_number])
    type = normalize_type(attrs[:account_type])

    cond do
      is_nil(holder) ->
        {:error, :account_holder_required}

      String.length(holder) > @max_holder_length ->
        {:error, :account_holder_too_long}

      is_nil(account) ->
        {:error, :account_number_required}

      not Regex.match?(~r/\A[A-Za-z0-9]+\z/, account) ->
        {:error, :account_number_invalid}

      String.length(account) > @max_account_length ->
        {:error, :account_number_too_long}

      is_nil(routing) ->
        {:error, :routing_number_required}

      not ApAchFile.valid_routing?(routing) ->
        {:error, :routing_number_invalid}

      type == :invalid ->
        {:error, :account_type_invalid}

      is_nil(bank_name) ->
        {:error, :bank_name_required}

      true ->
        {:ok,
         %{
           rail: :ach_usd,
           bank_name: bank_name,
           account_holder: holder,
           account_number: account,
           routing_number: routing,
           account_type: type,
           account_last4: String.slice(account, -4, 4)
         }}
    end
  end

  defp prevalidate_cad(attrs) do
    bank_name = normalize(attrs[:bank_name])
    holder = normalize(attrs[:account_holder])
    account = normalize(attrs[:account_number])
    institution = normalize_digits(attrs[:institution_number])
    transit = normalize_digits(attrs[:transit_number])
    type = normalize_type(attrs[:account_type])

    cond do
      is_nil(holder) ->
        {:error, :account_holder_required}

      String.length(holder) > @max_holder_length ->
        {:error, :account_holder_too_long}

      is_nil(account) ->
        {:error, :account_number_required}

      not Regex.match?(~r/\A[A-Za-z0-9]+\z/, account) ->
        {:error, :account_number_invalid}

      String.length(account) > @max_cad_account_length ->
        {:error, :account_number_too_long}

      not digits?(institution, 3) ->
        {:error, :institution_number_invalid}

      not digits?(transit, 5) ->
        {:error, :transit_number_invalid}

      type == :invalid ->
        {:error, :account_type_invalid}

      is_nil(bank_name) ->
        {:error, :bank_name_required}

      true ->
        {:ok,
         %{
           rail: :eft_cad,
           bank_name: bank_name,
           account_holder: holder,
           account_number: account,
           institution_number: institution,
           transit_number: transit,
           account_type: type,
           account_last4: String.slice(account, -4, 4),
           institution_last4: String.slice(institution, -4, 4),
           transit_last4: String.slice(transit, -4, 4)
         }}
    end
  end

  # -- validation -------------------------------------------------------------

  defp absent(repo, org_id, vendor_id, rail) do
    case get(repo, org_id, vendor_id, rail) do
      {:ok, nil} -> :ok
      {:ok, _profile} -> {:error, :already_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(repo, org_id, vendor_id, rail) do
    case get(repo, org_id, vendor_id, rail) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_allowed(%Record{status: :verified}, _actor), do: {:error, :already_verified}
  defp verify_allowed(%Record{changed_by: actor}, actor), do: {:error, :self_verification}
  defp verify_allowed(%Record{}, _actor), do: :ok

  defp normalize_rail(rail) when rail in @rails, do: {:ok, rail}
  defp normalize_rail("ach_usd"), do: {:ok, :ach_usd}
  defp normalize_rail("eft_cad"), do: {:ok, :eft_cad}
  defp normalize_rail(rail), do: {:error, {:invalid_rail, rail}}

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil

  defp normalize_routing(value) when is_binary(value),
    do: value |> String.replace(~r/[\s-]/, "") |> normalize()

  defp normalize_routing(_value), do: nil

  defp normalize_digits(value) when is_binary(value),
    do: value |> String.replace(~r/[\s-]/, "") |> normalize()

  defp normalize_digits(_value), do: nil

  defp digits?(value, width) when is_binary(value),
    do: byte_size(value) == width and String.match?(value, ~r/\A[0-9]+\z/)

  defp digits?(_value, _width), do: false

  defp normalize_type(type) when type in [:checking, :savings], do: type
  defp normalize_type("checking"), do: :checking
  defp normalize_type("savings"), do: :savings
  defp normalize_type(nil), do: :checking
  defp normalize_type(_type), do: :invalid

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :vendor_id_invalid}
    end
  end

  defp uuid(_value), do: {:error, :vendor_id_required}

  defp org_id(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id), do: {:ok, org_id}
  defp org_id(_scope), do: {:error, :org_required}

  defp actor_id(%Samen.Scope{actor: %{id: id}}) when is_binary(id), do: {:ok, id}
  defp actor_id(_scope), do: {:error, :actor_required}

  defp admin_id(%Samen.Scope{actor: %{id: id, role: role}})
       when is_binary(id) and role in [:admin, :owner],
       do: {:ok, id}

  defp admin_id(_scope), do: {:error, :forbidden}
end
