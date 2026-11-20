defmodule Samen.FinanceApAchArtifactTest do
  @moduledoc """
  The durable payment-file artifact on both rails:

    * a CAD artifact records its rail, allocated FCN and return/branch
      fingerprints, and reveals the exact stored bytes;
    * the rail and the run currency must agree in both directions;
    * listing is org-pinned and returns both rails;
    * a token swap fails the digest check.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{ApAchArtifact, ApPaymentRunRecord}
  alias Samen.Vault

  @repo SamenCore.TestRepo

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()

    member = scope("member:#{org}", org, :member)
    admin = scope("admin:#{org}", org, :admin)

    %{org: org, member: member, admin: admin, vendor: Ash.UUID.generate()}
  end

  defp scope(id, org, role) do
    %Samen.Scope{
      actor: %{id: id, org_id: org, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp paid_run!(ctx, currency) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, run} =
      %ApPaymentRunRecord{}
      |> ApPaymentRunRecord.changeset(%{
        org_id: ctx.org,
        reference: "RUN-#{System.unique_integer([:positive])}",
        vendor_id: ctx.vendor,
        payment_date: ~D[2026-11-08],
        status: :pending_approval,
        currency: currency,
        total_cents: 4_000,
        bill_count: 1,
        payments: [
          %{
            "bill_id" => Ash.UUID.generate(),
            "vendor_id" => ctx.vendor,
            "number" => "INV-1",
            "amount_cents" => 4_000
          }
        ],
        requested_by: "requester:other",
        requested_at: now
      })
      |> @repo.insert()

    @repo.query!(
      """
      UPDATE prn_ap_payment_run
      SET prn_status = 'paid', prn_approved_by = 'approver:other',
          prn_approved_at = now(), prn_executed_at = now(),
          prn_remittance_csv = 'reference,amount_cents\nRUN,4000\n'
      WHERE prn_id = $1
      """,
      [Ecto.UUID.dump!(run.id)]
    )

    @repo.get!(ApPaymentRunRecord, run.id)
  end

  defp cad_store(run, ctx, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          repo: @repo,
          scope: ctx.member,
          run: run,
          rail: :eft_cad,
          file: "CPARECORD\r\n",
          file_creation_number: "0042",
          originator: %{
            name: "Sample Co",
            id: "1123456789",
            institution: "000410202",
            return_account: "12345678901"
          },
          receiver: %{
            receiver_name: "Vendor One",
            receiver_account: "123456789",
            receiver_institution: "004",
            receiver_transit: "10202"
          }
        ],
        overrides
      )

    ApAchArtifact.store(opts)
  end

  test "stores a CAD artifact with rail, FCN and return fingerprints and reveals the exact bytes",
       ctx do
    run = paid_run!(ctx, "CAD")

    assert {:ok, artifact} = cad_store(run, ctx)

    assert artifact.rail == :eft_cad
    assert artifact.name == "eft-#{run.reference}.txt"
    assert artifact.file_creation_number == "0042"
    assert artifact.originator_name == "Sample Co"
    assert artifact.originator_id == "1123456789"
    assert artifact.originator_institution_last4 == "0202"
    assert artifact.originator_return_account_last4 == "8901"
    assert artifact.receiver_name == "Vendor One"
    assert artifact.receiver_account_last4 == "6789"
    assert artifact.receiver_institution_last4 == "004"
    assert artifact.receiver_transit_last4 == "0202"
    assert artifact.originator_dfi_last4 == nil
    assert artifact.receiver_routing_last4 == nil
    assert String.starts_with?(artifact.file_token, "vt_")
    assert byte_size(artifact.digest) == 64

    assert {:ok, "CPARECORD\r\n"} = ApAchArtifact.reveal(artifact, @repo)

    %{rows: [[rail, fcn]]} =
      @repo.query!(
        "SELECT ach_rail, ach_file_creation_number FROM ach_ap_payment_ach_file WHERE ach_id = $1",
        [Ecto.UUID.dump!(artifact.id)]
      )

    assert rail == "eft_cad"
    assert fcn == "0042"
  end

  test "a CAD artifact refuses a USD run and a USD artifact refuses a CAD run", ctx do
    usd_run = paid_run!(ctx, "USD")
    cad_run = paid_run!(ctx, "CAD")

    assert {:error, {:rail_currency_mismatch, :eft_cad, "USD"}} =
             cad_store(usd_run, ctx)

    assert {:error, {:rail_currency_mismatch, :ach_usd, "CAD"}} =
             ApAchArtifact.store(
               repo: @repo,
               scope: ctx.member,
               run: cad_run,
               rail: :ach_usd,
               file: "NACHA\n"
             )
  end

  test "a CAD artifact requires an allocated FCN", ctx do
    run = paid_run!(ctx, "CAD")

    assert {:error, :file_creation_number_required} =
             cad_store(run, ctx, file_creation_number: nil)

    assert {:error, :file_creation_number_invalid} =
             cad_store(run, ctx, file_creation_number: "0000")
  end

  test "list/3 is org-pinned and returns a run's artifacts whatever their rail", ctx do
    run = paid_run!(ctx, "CAD")
    {:ok, cad} = cad_store(run, ctx)

    assert [listed] = ApAchArtifact.list(@repo, ctx.org, run.id)
    assert listed.id == cad.id

    other_org = Ash.UUID.generate()
    assert ApAchArtifact.list(@repo, other_org, run.id) == []
  end

  test "a tampered stored file fails reveal with digest_mismatch", ctx do
    run = paid_run!(ctx, "CAD")
    {:ok, artifact} = cad_store(run, ctx)

    {:ok, tampered_token} =
      Vault.store_field(artifact.id, :pii_bank, :ach_file, "TAMPERED\r\n", @repo)

    swapped = %{artifact | file_token: tampered_token}
    assert {:error, :digest_mismatch} = ApAchArtifact.reveal(swapped, @repo)
  end
end
