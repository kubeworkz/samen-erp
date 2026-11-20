defmodule Samen.Scopes.Finance.ApEftOriginatorProfile do
  @moduledoc """
  The **TD Business Central EFT originator profile** and its file-creation-number
  (FCN) allocator.

  ## Why the FCN is allocated here

  A CPA-005 file must carry a 4-digit FCN that TD has not seen in its last 18
  submissions. That makes the number a server-side sequence, not a form field:
  `allocate_file_creation_number/3` locks the ONE profile row, returns its
  current `0001`–`9999` value, and advances the stored next value in the same
  transaction. `9999` wraps to `0001`; `0000` is never returned.

  Test and production profiles are separate `{org, bank, environment}` rows
  with independent sequences. The caller's environment must match the profile
  (`:environment_mismatch`), so allocating a test file cannot advance the
  production counter. There is no reset action and deletes are refused by the
  database trigger.

  ## Environment

  The environment is never guessed. `environment/0` reads
  `Application.fetch_env(:samen_core, :eft_environment)` and accepts only
  `:test` or `:production`; a missing value is `:environment_not_configured`
  and anything else is `:invalid_environment`. A CAD file is not rendered until
  the host has stated which environment it is paying from.

  ## What is never caller input

  The 10-digit TD client number, destination data centre `00420`, `0004` +
  transit return institution, and 11-digit return account are configured once
  per org and environment. The return account is stored as a `vt_*` vault token
  and revealed only to the server-side renderer, through `render_details/3`.
  """

  import Ecto.Query

  alias Samen.Scopes.Finance.ApEftOriginatorProfileRecord, as: Record
  alias Samen.Vault

  @vault :pii_bank
  @bank "td_business_central"
  @environments [:test, :production]

  @type profile :: Record.t()

  @doc """
  The host's EFT environment: `{:ok, :test | :production}` or a refusal.

  There is deliberately no default. A host that has not configured
  `:samen_core, :eft_environment` gets `{:error, :environment_not_configured}`.
  """
  @spec environment() :: {:ok, :test | :production} | {:error, term()}
  def environment do
    case Application.fetch_env(:samen_core, :eft_environment) do
      {:ok, value} -> normalize_environment(value)
      :error -> {:error, :environment_not_configured}
    end
  end

  @doc """
  Read the org's TD profile for one environment.

  The bank is pinned to `td_business_central`; the environment is explicit.
  Returns `{:ok, nil}` when this org has no profile for that environment.
  """
  @spec get(module(), String.t(), atom() | String.t()) ::
          {:ok, profile() | nil} | {:error, term()}
  def get(repo, org_id, environment) when is_binary(org_id) do
    with {:ok, environment} <- normalize_environment(environment) do
      {:ok,
       repo.get_by(Record,
         org_id: org_id,
         bank: @bank,
         environment: environment
       )}
    end
  rescue
    Ecto.Query.CastError -> {:ok, nil}
  end

  def get(_repo, _org_id, _environment), do: {:error, :org_required}

  @doc """
  Configure the org's TD profile for one environment. Admin-only.

  The environment is required and explicit; the return account is vaulted under
  the new row's own subject key. A second profile for the same
  `{org, bank, environment}` is refused (`:already_configured`) rather than
  silently replacing bank-assigned details.
  """
  @spec configure(keyword()) :: {:ok, profile()} | {:error, term()}
  def configure(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, org_id} <- org_id(scope),
         :ok <- admin_only(scope),
         {:ok, environment} <- normalize_environment(Keyword.get(opts, :environment)),
         :ok <- absent(repo, org_id, environment),
         {:ok, attrs} <- configure_attrs(org_id, environment, opts) do
      id = attrs.id

      case repo.transaction(fn ->
             case Vault.store_fields(
                    id,
                    @vault,
                    [return_account: attrs.return_account_plaintext],
                    repo
                  ) do
               {:ok, tokens} ->
                 attrs
                 |> Map.drop([:return_account_plaintext])
                 |> Map.put(:return_account, Map.fetch!(tokens, :return_account))
                 |> then(&Record.configure_changeset/1)
                 |> repo.insert()
                 |> case do
                   {:ok, profile} -> profile
                   {:error, changeset} -> repo.rollback({:insert_failed, changeset})
                 end

               {:error, reason} ->
                 repo.rollback({:vault_failed, reason})
             end
           end) do
        {:ok, profile} -> {:ok, profile}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The originator fields `ApEftFile` needs, including the revealed return account.

  The profile's environment must equal `environment`; a mismatched profile is
  `{:error, :environment_mismatch}` rather than a file built from the wrong
  sequence. Refuses a mangled encoding/separator and an unreadable vault.
  """
  @spec render_details(profile(), atom() | String.t(), module()) ::
          {:ok, map()} | {:error, term()}
  def render_details(%Record{} = profile, environment, repo) do
    with :ok <- same_environment(profile, environment),
         {:ok, separator} <- separator(profile.record_separator),
         :ok <- ascii_only(profile.encoding),
         {:ok, account} <- reveal_return_account(profile, repo) do
      {:ok,
       %{
         client_number: profile.client_number,
         destination_data_centre: profile.destination_data_centre,
         originator_return_institution: profile.return_institution,
         originator_return_account: account,
         encoding: :ascii,
         record_separator: separator
       }}
    end
  end

  @doc """
  Allocate the next FCN for `profile` (or the org's profile in `environment`).

  Locks only that row with `FOR UPDATE`, returns the current value as a
  4-character string, and advances the stored value (`9999` → `0001`). A
  mismatched environment refuses `:environment_mismatch`; a missing profile is
  `:originator_not_found`.
  """
  @spec allocate_file_creation_number(module(), profile() | String.t(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def allocate_file_creation_number(repo, %Record{} = profile, environment) do
    with {:ok, environment} <- normalize_environment(environment),
         :ok <- same_environment(profile, environment) do
      allocate_locked(repo, profile.id)
    end
  end

  def allocate_file_creation_number(repo, org_id, environment) when is_binary(org_id) do
    with {:ok, environment} <- normalize_environment(environment),
         {:ok, %Record{} = profile} <- fetch(repo, org_id, environment) do
      allocate_locked(repo, profile.id)
    end
  end

  @doc "The org's return-account fingerprint for display, without revealing it."
  @spec return_account_last4(profile()) :: String.t() | nil
  def return_account_last4(%Record{} = profile) do
    # The token is not the account; callers that need the last four must store a
    # fingerprint at configure time. This helper is retained for symmetry with
    # the artifact row and deliberately returns nil rather than pretending the
    # token is a number.
    _ = profile
    nil
  end

  # -- allocation -------------------------------------------------------------

  defp allocate_locked(repo, profile_id) do
    case repo.transaction(fn ->
           case repo.query(
                  """
                  SELECT eop_next_file_creation_number
                  FROM eop_ap_eft_originator_profile
                  WHERE eop_id = $1
                  FOR UPDATE
                  """,
                  [Ecto.UUID.dump!(profile_id)]
                ) do
             {:ok, %{rows: [[current]]}} ->
               next = if current >= 9999, do: 1, else: current + 1

               {1, _} =
                 repo.update_all(
                   from(p in Record, where: p.id == ^profile_id),
                   set: [
                     next_file_creation_number: next,
                     updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
                   ]
                 )

               current

             {:ok, %{rows: []}} ->
               repo.rollback(:originator_not_found)

             {:error, reason} ->
               repo.rollback({:lock_failed, reason})
           end
         end) do
      {:ok, fcn} -> {:ok, pad4(fcn)}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- values -----------------------------------------------------------------

  defp fetch(repo, org_id, environment) do
    case get(repo, org_id, environment) do
      {:ok, nil} -> {:error, :originator_not_found}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp absent(repo, org_id, environment) do
    case get(repo, org_id, environment) do
      {:ok, nil} -> :ok
      {:ok, _profile} -> {:error, :already_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp org_id(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id), do: {:ok, org_id}
  defp org_id(_scope), do: {:error, :org_required}

  defp admin_only(%Samen.Scope{actor: %{id: id, role: role}})
       when is_binary(id) and role in [:admin, :owner],
       do: :ok

  defp admin_only(_scope), do: {:error, :forbidden}

  defp configure_attrs(org_id, environment, opts) do
    now = Record.now()

    attrs = %{
      id: Ecto.UUID.generate(),
      org_id: org_id,
      bank: @bank,
      environment: environment,
      client_number: normalize_digits(Keyword.get(opts, :client_number)),
      destination_data_centre:
        normalize_digits(Keyword.get(opts, :destination_data_centre)) ||
          Record.default_destination_data_centre(),
      return_institution: normalize_digits(Keyword.get(opts, :return_institution)),
      return_account_plaintext: normalize_digits(Keyword.get(opts, :return_account)),
      return_account: "vt_pending",
      next_file_creation_number: 1,
      encoding: "ascii",
      record_separator: "crlf",
      inserted_at: now,
      updated_at: now
    }

    case Record.configure_changeset(attrs) do
      %Ecto.Changeset{valid?: true} -> {:ok, attrs}
      %Ecto.Changeset{} = changeset -> {:error, {:invalid_profile, changeset}}
    end
  end

  defp same_environment(%Record{environment: environment}, environment),
    do: :ok

  defp same_environment(%Record{}, _environment), do: {:error, :environment_mismatch}

  defp normalize_environment(environment) when environment in @environments,
    do: {:ok, environment}

  defp normalize_environment("test"), do: {:ok, :test}
  defp normalize_environment("production"), do: {:ok, :production}
  defp normalize_environment(nil), do: {:error, :environment_not_configured}
  defp normalize_environment(_environment), do: {:error, :invalid_environment}

  defp separator("crlf"), do: {:ok, "\r\n"}
  defp separator("cr"), do: {:ok, "\r"}
  defp separator(_separator), do: {:error, :record_separator_invalid}

  defp ascii_only("ascii"), do: :ok
  defp ascii_only(_encoding), do: {:error, :encoding_unsupported}

  defp reveal_return_account(%Record{return_account: token} = profile, repo)
       when is_binary(token) do
    token
    |> then(&%Samen.Masked{token: &1, label: :return_account})
    |> Vault.reveal(repo, subject_id: profile.id)
  end

  defp reveal_return_account(_profile, _repo), do: {:error, :return_account_missing}

  defp normalize_digits(value) when is_binary(value) do
    case String.replace(value, ~r/[\s-]/, "") do
      "" -> nil
      digits -> digits
    end
  end

  defp normalize_digits(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_digits(_value), do: nil

  defp pad4(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(4, "0")
  end
end
