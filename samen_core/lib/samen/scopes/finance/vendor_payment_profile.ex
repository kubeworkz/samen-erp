defmodule Samen.Scopes.Finance.VendorPaymentProfile do
  @moduledoc """
  The **vendor payment profile**: the verified bank account an AP payment run
  sends money to.

  ## Why this is not a caller-supplied ACH field

  A NACHA file routes money. Letting the ACH form accept a vendor's routing and
  account numbers per run means the payment rail's destination is whatever the
  operator typed that minute — there is no record of what account the vendor
  registered, no second pair of eyes on it, and no way to notice that a
  familiar vendor's account silently changed (the classic BEC / invoice-fraud
  pattern). This module makes the destination a durable, org-pinned fact:

    * `register/1` stores the account and routing numbers as vault tokens
      (`Samen.Vault.store_fields/4`) under the profile row's own DEK; plaintext
      never lands in a column.
    * `prevalidate/1` enforces the ABA checksum and the ACH field limits BEFORE
      anything is stored. It is also exposed for the UI's inline feedback.
    * `verify/1` requires an admin/owner who is a **different principal** from
      the one that registered or last changed the details. The database trigger
      is the second belt.
    * `change_bank_details/1` stores new tokens and resets the profile to
      `:unverified` in the same update, clearing the old evidence. A changed
      account cannot spend under the previous verification.
    * `payment_details/2` is the ONLY read that returns plaintext, and it
      refuses an unverified profile. `ApAchFile` is rendered from this map, so
      the ACH destination is always the verified profile — never caller input.

  ## Org pinning

  Every lookup is `(org_id, vendor_id)`-pinned from the caller's
  `Samen.Scope`, not from a client-supplied org. A vendor profile from another
  tenant is invisible (`{:error, :not_found}`), exactly like an Ash read under
  `OrgScope`.
  """

  alias Samen.Scopes.Finance.ApAchFile
  alias Samen.Scopes.Finance.VendorPaymentProfileRecord, as: Record
  alias Samen.Vault

  @vault :pii_bank
  @max_account_length 17
  @max_holder_length 22

  @type profile :: Record.t()

  @doc """
  Read one org-pinned profile. Returns `{:ok, nil}` when the vendor has none.
  """
  @spec get(module(), String.t(), String.t()) :: {:ok, profile() | nil} | {:error, term()}
  def get(repo, org_id, vendor_id) when is_binary(org_id) and is_binary(vendor_id) do
    {:ok, repo.get_by(Record, org_id: org_id, vendor_id: vendor_id)}
  rescue
    error -> {:error, {:read_failed, error}}
  end

  def get(_repo, _org_id, _vendor_id), do: {:error, :vendor_required}

  @doc """
  The org's profiles, for a vendor picker. Newest first.
  """
  @spec list(module(), String.t()) :: [profile()]
  def list(repo, org_id) when is_binary(org_id) do
    import Ecto.Query

    repo.all(
      from(p in Record,
        where: p.org_id == ^org_id,
        order_by: [desc: p.updated_at]
      )
    )
  rescue
    _error -> []
  end

  @doc """
  Prevalidate bank details before storing them.

  Returns `{:ok, normalized}` with atom keys (`:bank_name`, `:account_holder`,
  `:account_number`, `:routing_number`, `:account_type`, `:account_last4`) or
  `{:error, reason}` naming the field. Routing numbers must pass the ABA
  checksum; account numbers must be alphanumeric and fit the 17-character ACH
  entry field (never truncated — a shortened account is the wrong account).
  """
  @spec prevalidate(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def prevalidate(attrs) when is_list(attrs), do: prevalidate(Map.new(attrs))

  def prevalidate(attrs) when is_map(attrs) do
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
           bank_name: bank_name,
           account_holder: holder,
           account_number: account,
           routing_number: routing,
           account_type: type,
           account_last4: String.slice(account, -4, 4)
         }}
    end
  end

  @doc """
  Register a vendor's bank details as a new `:unverified` profile.

  Options: `:repo`, `:scope`, `:vendor_id` (all required), plus
  `:bank_name`, `:account_holder`, `:account_number`, `:routing_number`,
  `:account_type` (`:checking` by default).

  Refuses a second profile for the same `{org, vendor}` (`:already_registered`)
  — a change is `change_bank_details/1`, so the row keeps its history.
  """
  @spec register(keyword()) :: {:ok, profile()} | {:error, term()}
  def register(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- actor_id(scope),
         {:ok, vendor_id} <- uuid(Keyword.get(opts, :vendor_id)),
         {:ok, details} <- prevalidate(opts),
         :ok <- absent(repo, org_id, vendor_id) do
      id = Ecto.UUID.generate()
      now = Record.now()

      attrs = %{
        # The row id IS the vault subject id: `store_tokens!` encrypts under it.
        id: id,
        org_id: org_id,
        vendor_id: vendor_id,
        bank_name: details.bank_name,
        account_holder: details.account_holder,
        account_type: details.account_type,
        account_last4: details.account_last4,
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
  Replace a vendor's bank details and reset verification.

  Options: `:repo`, `:scope`, `:vendor_id` (required) plus the same bank fields
  as `register/1`. The row keeps its identity and history; the previous vault
  ciphertext is left untouched, the new tokens are written, and the profile
  becomes `:unverified` with cleared evidence in the same update.
  """
  @spec change_bank_details(keyword()) :: {:ok, profile()} | {:error, term()}
  def change_bank_details(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- actor_id(scope),
         {:ok, vendor_id} <- uuid(Keyword.get(opts, :vendor_id)),
         {:ok, details} <- prevalidate(opts),
         {:ok, %Record{} = profile} <- fetch(repo, org_id, vendor_id) do
      now = Record.now()

      attrs = %{
        bank_name: details.bank_name,
        account_holder: details.account_holder,
        account_type: details.account_type,
        account_last4: details.account_last4,
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
  Verify a profile as an admin/owner who is NOT the principal that registered
  or last changed its bank details.

  Returns `{:error, :self_verification}` for the same principal,
  `{:error, :already_verified}` for a verified profile, and
  `{:error, :forbidden}` for a non-admin.
  """
  @spec verify(keyword()) :: {:ok, profile()} | {:error, term()}
  def verify(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- admin_id(scope),
         {:ok, vendor_id} <- uuid(Keyword.get(opts, :vendor_id)),
         {:ok, %Record{} = profile} <- fetch(repo, org_id, vendor_id),
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
  The verified profile's ACH receiver fields, with plaintext revealed through
  the ONE vault chokepoint.

  Refuses an unverified profile (`{:error, :unverified}`) and a shredded key
  (`{:error, :shredded}`) rather than sending money to a stale or unreadable
  destination.
  """
  @spec payment_details(profile(), module()) :: {:ok, map()} | {:error, term()}
  def payment_details(%Record{status: :verified} = profile, repo) do
    with {:ok, account} <- reveal(profile.account_number, :account_number, profile, repo),
         {:ok, routing} <- reveal(profile.routing_number, :routing_number, profile, repo) do
      {:ok,
       %{
         receiver_name: profile.account_holder,
         receiver_account: account,
         receiver_dfi: routing,
         account_type: profile.account_type
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
    fields = [
      account_number: details.account_number,
      routing_number: details.routing_number
    ]

    case Vault.store_fields(id, @vault, fields, repo) do
      {:ok, tokens} ->
        %{
          account_number: Map.fetch!(tokens, :account_number),
          routing_number: Map.fetch!(tokens, :routing_number)
        }

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

  # -- validation -------------------------------------------------------------

  defp absent(repo, org_id, vendor_id) do
    case get(repo, org_id, vendor_id) do
      {:ok, nil} -> :ok
      {:ok, _profile} -> {:error, :already_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(repo, org_id, vendor_id) do
    case get(repo, org_id, vendor_id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_allowed(%Record{status: :verified}, _actor), do: {:error, :already_verified}
  defp verify_allowed(%Record{changed_by: actor}, actor), do: {:error, :self_verification}
  defp verify_allowed(%Record{}, _actor), do: :ok

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil

  defp normalize_routing(value) when is_binary(value),
    do: normalize(String.replace(value, ~r/[\s-]/, ""))

  defp normalize_routing(_value), do: nil

  defp normalize_type(nil), do: :checking
  defp normalize_type(:checking), do: :checking
  defp normalize_type(:savings), do: :savings
  defp normalize_type("checking"), do: :checking
  defp normalize_type("savings"), do: :savings
  defp normalize_type(_value), do: :invalid

  # -- actor ------------------------------------------------------------------

  defp org_id(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id), do: {:ok, org_id}
  defp org_id(_scope), do: {:error, :org_required}

  defp actor_id(%Samen.Scope{actor: %{id: id}}) when is_binary(id), do: {:ok, id}
  defp actor_id(_scope), do: {:error, :actor_required}

  defp admin_id(%Samen.Scope{actor: %{id: id, role: role}})
       when is_binary(id) and role in [:admin, :owner],
       do: {:ok, id}

  defp admin_id(_scope), do: {:error, :forbidden}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :vendor_id_invalid}
    end
  end

  defp uuid(_value), do: {:error, :vendor_id_required}
end
