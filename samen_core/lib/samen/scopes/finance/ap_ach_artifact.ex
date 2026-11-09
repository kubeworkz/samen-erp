defmodule Samen.Scopes.Finance.ApAchArtifact do
  @moduledoc """
  The durable NACHA artifact for a paid AP payment run.

  The payments page renders `Samen.Scopes.Finance.ApAchFile` from the run and
  the vendor's verified payment profile, then hands the bytes to this service.
  The service:

    * refuses a run that is not `:paid` and is not in the caller's org;
    * requires a member-or-above actor (the page's operator plane never reaches
      here, because its write guard already refuses);
    * digests the file (SHA-256) and stores the bytes through `Samen.Vault` —
      a NACHA file contains the receiver account/routing numbers, so storing it
      in a plain column would undo the vendor-profile PII control;
    * snapshots only display-safe metadata (originator name/id, a last-four
      fingerprint of the originator routing and the receiver account/routing).

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

  @type artifact :: Record.t()

  @doc """
  Store one rendered ACH file for `run`.

  Options: `:repo`, `:scope`, `:run` (required); `:file`, `:name`,
  `:originator`, `:receiver` (optional except `:file`).

  Returns `{:ok, artifact}` or `{:error, reason}` where reason is
  `:forbidden`, `:run_not_found`, `:run_not_paid`, `:file_required`,
  `{:vault_failed, reason}`, or `{:insert_failed, changeset}`.
  """
  @spec store(keyword()) :: {:ok, artifact()} | {:error, term()}
  def store(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    run = Keyword.fetch!(opts, :run)
    file = Keyword.get(opts, :file)
    originator = Keyword.get(opts, :originator, %{})
    receiver = Keyword.get(opts, :receiver, %{})
    name = artifact_name(Keyword.get(opts, :name), run)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- member_id(scope),
         :ok <- paid_run(repo, org_id, run),
         :ok <- validate_file(file),
         {:ok, name} <- validate_name(name) do
      id = Ecto.UUID.generate()
      now = Record.now()

      attrs = %{
        id: id,
        org_id: org_id,
        run_id: run.id,
        name: name,
        digest: digest(file),
        size_bytes: byte_size(file),
        originator_name: text(fetch(originator, :name)),
        originator_id: text(fetch(originator, :id)),
        originator_dfi_last4: last4(fetch(originator, :dfi)),
        receiver_name: text(fetch(receiver, :receiver_name) || fetch(receiver, :account_holder)),
        receiver_account_last4:
          last4(fetch(receiver, :receiver_account) || fetch(receiver, :account_number)),
        receiver_routing_last4:
          last4(fetch(receiver, :receiver_dfi) || fetch(receiver, :routing_number)),
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

  @doc "The org-pinned artifacts for one run, newest first."
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

  @doc "The SHA-256 digest of an ACH file, lowercase hex."
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

  defp validate_file(file) when is_binary(file) and byte_size(file) > 0, do: :ok
  defp validate_file(_file), do: {:error, :file_required}

  defp artifact_name(nil, %{reference: reference}) when is_binary(reference),
    do: "ach-#{reference}.ach"

  defp artifact_name(nil, _run), do: "ach.ach"
  defp artifact_name(name, _run), do: name

  defp validate_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      trimmed when byte_size(trimmed) > @max_name_length -> {:error, :name_too_long}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_name(_name), do: {:error, :name_required}

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
