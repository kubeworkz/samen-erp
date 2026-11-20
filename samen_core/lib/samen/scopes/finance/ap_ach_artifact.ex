defmodule Samen.Scopes.Finance.ApAchArtifact do
  @moduledoc """
  The durable payment-file artifact for a paid AP payment run, on either rail.

  The payments page renders `Samen.Scopes.Finance.ApAchFile` (USD NACHA) or
  `Samen.Scopes.Finance.ApEftFile` (CAD CPA-005) from the run and the vendor's
  verified payment profile, then hands the bytes to this service. The service:

    * refuses a run that is not `:paid` and is not in the caller's org;
    * requires a member-or-above actor (the page's operator plane never reaches
      here, because its write guard already refuses);
    * refuses a rail whose currency does not match the run, so a CAD store can
      never default to `ach_usd`;
    * digests the file (SHA-256) and stores the bytes through `Samen.Vault` —
      both file formats contain receiver account/routing identifiers, so
      storing one in a plain column would undo the vendor-profile PII control;
    * snapshots only display-safe metadata: the rail, originator name/id, the
      allocated FCN and last-four fingerprints.

  The table is one append-only artifact table for both rails
  (`ach_rail = 'ach_usd' | 'eft_cad'`), not a sibling table: rows stay
  immutable and undeletable, and `list/3`/`reveal/2` return both rails without a
  second read path. An ACH row carries no CAD fields; a CAD row carries a
  4-digit non-`0000` FCN and the originator/receiver branch fingerprints, with
  no routing last-four.

  `reveal/2` is the one path that returns the file bytes again, and it
  re-verifies the digest before returning them. A changed/missing artifact is
  therefore an integrity error, not a silent download.

  Every lookup is `(org_id, run_id)`-pinned from the caller's `Samen.Scope`,
  never from a client-supplied org.
  """

  import Ecto.Query, only: [from: 2]

  alias Samen.Scopes.Finance.ApAchArtifactRecord, as: Record
  alias Samen.Scopes.Finance.ApPaymentRunRecord
  alias Samen.Vault

  @vault :pii_bank
  @max_name_length 120
  @rails [:ach_usd, :eft_cad]

  @type artifact :: Record.t()

  @doc """
  Store one rendered payment file for `run`.

  Options: `:repo`, `:scope`, `:run` (required); `:file` (required);
  `:rail` (`:ach_usd` default); `:name`, `:originator`, `:receiver`,
  `:file_creation_number` (optional except the CAD FCN).

  Returns `{:ok, artifact}` or `{:error, reason}` where reason is
  `:forbidden`, `:run_not_found`, `:run_not_paid`, `:file_required`,
  `{:rail_currency_mismatch, rail, currency}`, `:file_creation_number_required`,
  `{:vault_failed, reason}`, or `{:insert_failed, changeset}`.
  """
  @spec store(keyword()) :: {:ok, artifact()} | {:error, term()}
  def store(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    run = Keyword.fetch!(opts, :run)
    file = Keyword.get(opts, :file)
    rail = Keyword.get(opts, :rail, :ach_usd)
    originator = Keyword.get(opts, :originator, %{})
    receiver = Keyword.get(opts, :receiver, %{})
    name = artifact_name(Keyword.get(opts, :name), rail, run)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- member_id(scope),
         :ok <- paid_run(repo, org_id, run),
         {:ok, rail} <- normalize_rail(rail),
         :ok <- rail_currency(rail, run),
         :ok <- validate_file(file),
         {:ok, name} <- validate_name(name),
         {:ok, rail_fields} <- rail_fields(rail, opts, originator, receiver) do
      id = Ecto.UUID.generate()
      now = Record.now()

      attrs = %{
        id: id,
        org_id: org_id,
        run_id: run.id,
        rail: rail,
        name: name,
        digest: digest(file),
        size_bytes: byte_size(file),
        originator_name: text(fetch(originator, :name)),
        originator_id: text(fetch(originator, :id)),
        originator_dfi_last4: Map.get(rail_fields, :originator_dfi_last4),
        originator_institution_last4: Map.get(rail_fields, :originator_institution_last4),
        originator_return_account_last4: Map.get(rail_fields, :originator_return_account_last4),
        receiver_name: text(fetch(receiver, :receiver_name) || fetch(receiver, :account_holder)),
        receiver_account_last4:
          last4(fetch(receiver, :receiver_account) || fetch(receiver, :account_number)),
        receiver_routing_last4: Map.get(rail_fields, :receiver_routing_last4),
        receiver_institution_last4: Map.get(rail_fields, :receiver_institution_last4),
        receiver_transit_last4: Map.get(rail_fields, :receiver_transit_last4),
        file_creation_number: Map.get(rail_fields, :file_creation_number),
        generated_by: actor,
        generated_at: now,
        inserted_at: now
      }

      case repo.transaction(fn ->
             case Vault.store_field(id, @vault, :ach_file, file, repo) do
               {:ok, token} ->
                 attrs
                 |> Map.put(:file_token, token)
                 |> then(&Record.changeset(%Record{}, &1))
                 |> repo.insert()
                 |> case do
                   {:ok, artifact} -> artifact
                   {:error, changeset} -> repo.rollback({:insert_failed, changeset})
                 end

               {:error, reason} ->
                 repo.rollback({:vault_failed, reason})
             end
           end) do
        {:ok, artifact} -> {:ok, artifact}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The org-pinned artifacts for one run, newest first, whatever their rail."
  @spec list(module(), String.t(), String.t()) :: [artifact()]
  def list(repo, org_id, run_id) when is_binary(org_id) and is_binary(run_id) do
    repo.all(
      from(a in Record,
        where: a.org_id == ^org_id and a.run_id == ^run_id,
        order_by: [desc: a.generated_at]
      )
    )
  rescue
    _error -> []
  end

  @doc """
  The one plaintext read: reveal the stored file after re-checking its digest.

  Returns `{:ok, file}` or `{:error, :digest_mismatch}`/`{:error, reason}`.
  """
  @spec reveal(artifact(), module()) :: {:ok, String.t()} | {:error, term()}
  def reveal(%Record{} = artifact, repo) do
    masked = %Samen.Masked{token: artifact.file_token, label: :ach_file}

    case Vault.reveal(masked, repo, subject_id: artifact.id) do
      {:ok, file} ->
        if digest(file) == artifact.digest, do: {:ok, file}, else: {:error, :digest_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The SHA-256 digest of a payment file, lowercase hex."
  @spec digest(String.t()) :: String.t()
  def digest(file) when is_binary(file) do
    :crypto.hash(:sha256, file) |> Base.encode16(case: :lower)
  end

  # -- validation -------------------------------------------------------------

  defp org_id(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id), do: {:ok, org_id}
  defp org_id(_scope), do: {:error, :org_required}

  defp member_id(%Samen.Scope{actor: %{id: id, role: role}})
       when is_binary(id) and role in [:member, :admin, :owner],
       do: {:ok, id}

  defp member_id(_scope), do: {:error, :forbidden}

  defp paid_run(repo, org_id, %{id: run_id}) when is_binary(run_id) do
    case repo.get_by(ApPaymentRunRecord, id: run_id, org_id: org_id) do
      %{status: :paid} -> :ok
      %{status: _other} -> {:error, :run_not_paid}
      nil -> {:error, :run_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :run_not_found}
  end

  defp paid_run(_repo, _org_id, _run), do: {:error, :run_not_found}

  defp normalize_rail(rail) when rail in @rails, do: {:ok, rail}
  defp normalize_rail("ach_usd"), do: {:ok, :ach_usd}
  defp normalize_rail("eft_cad"), do: {:ok, :eft_cad}
  defp normalize_rail(rail), do: {:error, {:invalid_rail, rail}}

  # The stored bytes and the rail must agree. A CAD store can never default to
  # ACH, and a USD run can never be filed as a CPA-005 artifact.
  defp rail_currency(:ach_usd, run) do
    case Map.get(run, :currency) || "USD" do
      "USD" -> :ok
      currency when is_binary(currency) -> {:error, {:rail_currency_mismatch, :ach_usd, currency}}
      _ -> {:error, {:rail_currency_mismatch, :ach_usd, "USD"}}
    end
  end

  defp rail_currency(:eft_cad, run) do
    case Map.get(run, :currency) do
      "CAD" -> :ok
      currency when is_binary(currency) -> {:error, {:rail_currency_mismatch, :eft_cad, currency}}
      _ -> {:error, {:rail_currency_mismatch, :eft_cad, "CAD"}}
    end
  end

  defp validate_file(file) when is_binary(file) and byte_size(file) > 0, do: :ok
  defp validate_file(_file), do: {:error, :file_required}

  defp artifact_name(nil, :eft_cad, %{reference: reference}) when is_binary(reference),
    do: "eft-#{reference}.txt"

  defp artifact_name(nil, :eft_cad, _run), do: "eft.txt"

  defp artifact_name(nil, :ach_usd, %{reference: reference}) when is_binary(reference),
    do: "ach-#{reference}.ach"

  defp artifact_name(nil, :ach_usd, _run), do: "ach.ach"
  defp artifact_name(name, _rail, _run), do: name

  defp validate_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      trimmed when byte_size(trimmed) > @max_name_length -> {:error, :name_too_long}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_name(_name), do: {:error, :name_required}

  # The artifact row is rail-shaped. ACH keeps the original originator-D.fi. and
  # receiver-routing fingerprints; CAD records the allocated FCN and the
  # institution/transit/return-account fingerprints instead.
  defp rail_fields(:ach_usd, _opts, originator, receiver) do
    {:ok,
     %{
       originator_dfi_last4: last4(fetch(originator, :dfi)),
       receiver_routing_last4:
         last4(fetch(receiver, :receiver_dfi) || fetch(receiver, :routing_number)),
       originator_institution_last4: nil,
       originator_return_account_last4: nil,
       receiver_institution_last4: nil,
       receiver_transit_last4: nil,
       file_creation_number: nil
     }}
  end

  defp rail_fields(:eft_cad, opts, originator, receiver) do
    with {:ok, fcn} <- validate_fcn(Keyword.get(opts, :file_creation_number)) do
      {:ok,
       %{
         originator_dfi_last4: nil,
         receiver_routing_last4: nil,
         originator_institution_last4:
           last4(fetch(originator, :institution) || fetch(originator, :return_institution)),
         originator_return_account_last4: last4(fetch(originator, :return_account)),
         receiver_institution_last4:
           last4(fetch(receiver, :receiver_institution) || fetch(receiver, :institution)),
         receiver_transit_last4:
           last4(fetch(receiver, :receiver_transit) || fetch(receiver, :transit)),
         file_creation_number: fcn
       }}
    end
  end

  defp validate_fcn(value) when is_integer(value), do: validate_fcn(Integer.to_string(value))

  defp validate_fcn(value) when is_binary(value) do
    value = String.trim(value)

    if String.match?(value, ~r/\A(?!0000)[0-9]{4}\z/) do
      {:ok, value}
    else
      {:error, :file_creation_number_invalid}
    end
  end

  defp validate_fcn(_value), do: {:error, :file_creation_number_required}

  # -- values -----------------------------------------------------------------

  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_map, _key), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp last4(value) when is_binary(value) do
    value |> String.replace(~r/[^0-9A-Za-z]/, "") |> String.slice(-4, 4)
  end

  defp last4(_value), do: nil
end
