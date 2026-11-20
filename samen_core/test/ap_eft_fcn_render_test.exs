defmodule SamenCore.ApEftFcnRenderTest do
  @moduledoc """
  The split between the two TD environments is proven on the rendered file, not
  only on the counter: a production allocation's first FCN appears in A, every
  C and Z at positions 21–24, and allocating from the test profile afterwards
  neither changes the production counter nor the production file's bytes.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{
    ApEftFile,
    ApEftOriginatorProfile,
    ApEftOriginatorProfileRecord
  }

  @repo SamenCore.TestRepo

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()

    admin = %Samen.Scope{
      actor: %{id: "admin:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }

    %{org: org, admin: admin}
  end

  defp configure!(ctx, environment) do
    {:ok, profile} =
      ApEftOriginatorProfile.configure(
        repo: @repo,
        scope: ctx.admin,
        environment: environment,
        client_number: "1123456789",
        destination_data_centre: "00420",
        return_institution: "000410202",
        return_account: "12345678901"
      )

    profile
  end

  defp run do
    %{
      reference: "RUN-FCN-1",
      payment_date: ~D[2026-11-08],
      currency: "CAD",
      total_cents: 2_800,
      payments:
        for index <- 1..7 do
          %{number: "INV-#{index}", amount_cents: index * 100}
        end
    }
  end

  defp opts(fcn) do
    [
      originator_name: "Sample Co",
      originator_id: "1123456789",
      destination_data_centre: "00420",
      originator_return_institution: "000410202",
      originator_return_account: "12345678901",
      file_creation_number: fcn,
      encoding: :ascii,
      record_separator: "\r\n",
      receiver_name: "Vendor One",
      receiver_account: "123456789",
      receiver_institution: "004",
      receiver_transit: "10202",
      account_type: :checking,
      effective_date: ~D[2026-11-10],
      created_at: ~U[2026-11-08 15:04:05Z]
    ]
  end

  test "a production allocation's first FCN 0001 is written into A, C and Z 21-24, and a test allocation cannot change it",
       ctx do
    production = configure!(ctx, :production)
    test_profile = configure!(ctx, :test)

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(
               @repo,
               production,
               :production
             )

    {:ok, file} = ApEftFile.render(run(), opts("0001"))
    records = String.split(file, "\r\n", trim: true)

    assert length(records) == 4
    assert Enum.all?(records, &(String.slice(&1, 20, 4) == "0001"))

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(@repo, test_profile, :test)

    assert @repo.get!(ApEftOriginatorProfileRecord, production.id).next_file_creation_number == 2

    assert @repo.get!(ApEftOriginatorProfileRecord, test_profile.id).next_file_creation_number ==
             2

    {:ok, rerendered} = ApEftFile.render(run(), opts("0001"))
    assert rerendered == file
  end
end
