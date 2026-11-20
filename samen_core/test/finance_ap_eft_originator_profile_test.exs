defmodule Samen.FinanceApEftOriginatorProfileTest do
  @moduledoc """
  The TD EFT originator profile's control model:

    * the TD fields are validated and the return account is vaulted;
    * test and production are separate rows with independent FCN sequences;
    * allocation is row-locked, wraps 9999 → 0001 and never returns 0000;
    * the environment is explicit, immutable, delete-refused and mismatch-refused;
    * profiles are org-pinned.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Samen.Scopes.Finance.ApEftOriginatorProfile
  alias Samen.Scopes.Finance.ApEftOriginatorProfileRecord

  @repo SamenCore.TestRepo

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()

    admin = scope("admin:#{org}", org, :admin)
    member = scope("member:#{org}", org, :member)

    %{org: org, admin: admin, member: member}
  end

  defp scope(id, org, role) do
    %Samen.Scope{
      actor: %{id: id, org_id: org, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp configure!(ctx, environment, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          repo: @repo,
          scope: ctx.admin,
          environment: environment,
          client_number: "1123456789",
          destination_data_centre: "00420",
          return_institution: "000410202",
          return_account: "12345678901"
        },
        overrides
      )

    {:ok, profile} = ApEftOriginatorProfile.configure(Map.to_list(attrs))
    profile
  end

  defp reload(profile), do: @repo.get!(ApEftOriginatorProfileRecord, profile.id)

  defp set_next!(profile, next) do
    @repo.update_all(
      from(p in ApEftOriginatorProfileRecord, where: p.id == ^profile.id),
      set: [next_file_creation_number: next]
    )
  end

  test "TD profile stores 00420, 0004+transit and a vaulted 11-digit return account", ctx do
    profile = configure!(ctx, :test)

    assert profile.bank == "td_business_central"
    assert profile.environment == :test
    assert profile.client_number == "1123456789"
    assert profile.destination_data_centre == "00420"
    assert profile.return_institution == "000410202"
    assert profile.next_file_creation_number == 1
    assert profile.encoding == "ascii"
    assert profile.record_separator == "crlf"

    %{rows: [[token, plaintext_match]]} =
      @repo.query!(
        "SELECT pii_eop_return_account, pii_eop_return_account = $2 " <>
          "FROM eop_ap_eft_originator_profile WHERE eop_id = $1",
        [Ecto.UUID.dump!(profile.id), "12345678901"]
      )

    assert String.starts_with?(token, "vt_")
    assert plaintext_match == false

    assert {:ok, details} = ApEftOriginatorProfile.render_details(profile, :test, @repo)
    assert details.client_number == "1123456789"
    assert details.destination_data_centre == "00420"
    assert details.originator_return_institution == "000410202"
    assert details.originator_return_account == "12345678901"
    assert details.encoding == :ascii
    assert details.record_separator == "\r\n"
  end

  test "production profile starts at FCN 0001", ctx do
    production = configure!(ctx, :production)
    assert production.next_file_creation_number == 1

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, production, :production)
  end

  test "test allocation never changes the production FCN", ctx do
    production = configure!(ctx, :production)
    test_profile = configure!(ctx, :test)

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, test_profile, :test)

    assert reload(production).next_file_creation_number == 1
    assert reload(test_profile).next_file_creation_number == 2

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, production, :production)

    assert reload(production).next_file_creation_number == 2
    assert reload(test_profile).next_file_creation_number == 2
  end

  test "FCN allocates 0001, increments, wraps 9999->0001, never 0000", ctx do
    profile = configure!(ctx, :test)

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, profile, :test)

    assert {:ok, "0002"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, profile, :test)

    set_next!(profile, 9999)

    assert {:ok, "9999"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, profile, :test)

    assert reload(profile).next_file_creation_number == 1

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, profile, :test)
  end

  test "two allocators locked on one profile never return the same FCN", ctx do
    profile = configure!(ctx, :test)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          ApEftOriginatorProfile.allocate_file_creation_number(@repo, profile, :test)
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))
      |> Enum.sort()

    assert results == [{:ok, "0001"}, {:ok, "0002"}]
    assert reload(profile).next_file_creation_number == 3
  end

  test "allocating with a mismatched environment refuses", ctx do
    profile = configure!(ctx, :test)

    assert {:error, :environment_mismatch} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, profile, :production)

    assert reload(profile).next_file_creation_number == 1
  end

  test "test and production profiles coexist for one org/bank", ctx do
    test_profile = configure!(ctx, :test)
    production = configure!(ctx, :production)

    refute test_profile.id == production.id

    assert {:ok, ^test_profile} = ApEftOriginatorProfile.get(@repo, ctx.org, :test)
    assert {:ok, ^production} = ApEftOriginatorProfile.get(@repo, ctx.org, :production)
  end

  test "environment is immutable and delete is refused", ctx do
    profile = configure!(ctx, :test)

    changeset =
      ApEftOriginatorProfileRecord.update_changeset(profile, %{environment: :production})

    refute changeset.valid?
    assert {_message, _opts} = Keyword.fetch!(changeset.errors, :environment)

    assert_raise Postgrex.Error, ~r/originator profiles are never deleted/, fn ->
      @repo.delete!(profile)
    end
  end

  test "an unknown or missing originator environment refuses" do
    previous = Application.fetch_env(:samen_core, :eft_environment)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:samen_core, :eft_environment, value)
        :error -> Application.delete_env(:samen_core, :eft_environment)
      end
    end)

    Application.delete_env(:samen_core, :eft_environment)
    assert {:error, :environment_not_configured} = ApEftOriginatorProfile.environment()

    Application.put_env(:samen_core, :eft_environment, :staging)
    assert {:error, :invalid_environment} = ApEftOriginatorProfile.environment()

    Application.put_env(:samen_core, :eft_environment, :production)
    assert {:ok, :production} = ApEftOriginatorProfile.environment()
  end

  test "a cross-org originator profile is not found", ctx do
    configure!(ctx, :test)

    other_org = Ash.UUID.generate()
    assert {:ok, nil} = ApEftOriginatorProfile.get(@repo, other_org, :test)
  end

  test "a cross-environment originator profile is not found", ctx do
    configure!(ctx, :test)

    assert {:ok, nil} = ApEftOriginatorProfile.get(@repo, ctx.org, :production)
  end

  test "a missing originator profile refuses", ctx do
    assert {:error, :originator_not_found} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, ctx.org, :test)
  end

  test "only an admin can configure a profile", ctx do
    assert {:error, :forbidden} =
             ApEftOriginatorProfile.configure(
               repo: @repo,
               scope: ctx.member,
               environment: :test,
               client_number: "1123456789",
               return_institution: "000410202",
               return_account: "12345678901"
             )
  end
end
