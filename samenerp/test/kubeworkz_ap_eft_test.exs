defmodule Samenerp.KubeworkzApEftTest do
  @moduledoc """
  The Kubeworkz host proof for the CAD payment rail. A CAD book opens, a CAD
  vendor bill is approved and paid through the ordinary dual-control run, and
  the host then builds a CPA-005 file end to end:

    * the TD originator profile is host data (client number, return account,
      encoding) and the file creation number comes from its `:test` sequence;
    * the vendor destination comes from a verified, rail-pinned CAD profile;
    * the rendered bytes are the 1464-byte TD records and the vaulted artifact
      reveals exactly those bytes.

  No kernel behavior is re-implemented here: the host only calls
  `ApEftOriginatorProfile`, `VendorPaymentProfile`, `ApEftFile` and
  `ApAchArtifact`.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{
    ApAchArtifact,
    ApEftFile,
    ApEftOriginatorProfile,
    ApPaymentRun,
    VendorPaymentProfile
  }

  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "admin:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp approver_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "approver:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp account!(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp new_bill(scope, org_id, vendor_id, number, amount_cents, account) do
    Erp.ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        vendor_id: vendor_id,
        number: number,
        bill_date: ~D[2026-10-01],
        due_date: ~D[2026-10-31],
        memo: "Kubeworkz CAD EFT proof",
        lines: [%{account_id: account.id, amount_cents: amount_cents}]
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp approve!(bill, org_id, scope) do
    {:error, %Ash.Error.Forbidden{errors: errors}} =
      bill
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    approval =
      Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) ||
        flunk("expected ApprovalRequired, got: #{inspect(errors)}")

    assert {:ok, _, _} =
             Samen.Approvals.approve(approval.approval_id, "approver:#{org_id}",
               approval_resource: Samenerp.Approvals.Approval,
               repo: Samenerp.Repo
             )

    Ash.get!(Erp.ApInvoice, bill.id, scope: scope)
  end

  test "a Kubeworkz CAD run renders CPA-005 from the host's TD profile and stores the file" do
    org = create_org!("Kubeworkz CAD EFT")
    admin = admin_scope(org.id)
    approver = approver_scope(org.id)

    # The books are opened in CAD, so the bill, run and file all agree before a
    # CPA-005 renderer is asked to run.
    Erp.OrgFxSettings
    |> Ash.Changeset.for_create(:create, %{org_id: org.id, base_currency: "CAD"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    expense = account!(org.id, "6000")
    vendor = Ash.UUID.generate()

    bill =
      new_bill(admin, org.id, vendor, "AP-EFT-001", 125_000, expense)
      |> approve!(org.id, admin)

    assert bill.currency == "CAD"

    assert {:ok, pending} =
             ApPaymentRun.request(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: admin,
               bill_ids: [bill.id],
               payment_date: ~D[2026-11-10],
               reference: "KUBE-EFT-1"
             )

    assert pending.currency == "CAD"

    assert {:ok, paid} =
             ApPaymentRun.approve(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: approver,
               run_id: pending.id
             )

    assert paid.status == :paid

    # The TD originator is host data. The test sequence is selected by the
    # host's :eft_environment config, never by a caller flag.
    assert {:ok, originator} =
             ApEftOriginatorProfile.configure(
               repo: Samenerp.Repo,
               scope: admin,
               environment: :test,
               client_number: "1123456789",
               destination_data_centre: "00420",
               return_institution: "000410202",
               return_account: "12345678901"
             )

    assert {:ok, cad_profile} =
             VendorPaymentProfile.register(
               repo: Samenerp.Repo,
               scope: admin,
               vendor_id: vendor,
               rail: :eft_cad,
               bank_name: "TD Bank",
               account_holder: "Kubeworkz Vendor",
               account_number: "123456789",
               institution_number: "004",
               transit_number: "10202",
               account_type: "checking"
             )

    assert cad_profile.rail == :eft_cad

    assert {:ok, verified} =
             VendorPaymentProfile.verify(
               repo: Samenerp.Repo,
               scope: approver,
               vendor_id: vendor,
               rail: :eft_cad
             )

    assert {:ok, details} = VendorPaymentProfile.payment_details(verified, Samenerp.Repo)

    assert {:ok, "0001"} =
             ApEftOriginatorProfile.allocate_file_creation_number(
               Samenerp.Repo,
               originator,
               :test
             )

    assert {:ok, originator_details} =
             ApEftOriginatorProfile.render_details(originator, :test, Samenerp.Repo)

    run_for_vendor =
      Map.put(paid, :payments, ApPaymentRun.payments_for_vendor(paid, vendor))

    opts =
      [
        originator_name: "Kubeworkz",
        originator_id: originator_details.client_number,
        destination_data_centre: originator_details.destination_data_centre,
        originator_return_institution: originator_details.originator_return_institution,
        originator_return_account: originator_details.originator_return_account,
        file_creation_number: "0001",
        encoding: originator_details.encoding,
        record_separator: originator_details.record_separator,
        effective_date: paid.payment_date
      ] ++ Map.to_list(details)

    assert {:ok, file} = ApEftFile.render(run_for_vendor, opts)

    records = String.split(file, "\r\n", trim: true)

    assert length(records) == 3
    assert Enum.all?(records, &(String.length(&1) == 1464))
    assert Enum.all?(records, &(String.slice(&1, 20, 4) == "0001"))

    assert {:ok, artifact} =
             ApAchArtifact.store(
               repo: Samenerp.Repo,
               scope: admin,
               run: paid,
               rail: :eft_cad,
               file: file,
               name: "eft-KUBE-EFT-1.txt",
               file_creation_number: "0001",
               originator: %{
                 name: "Kubeworkz",
                 id: originator_details.client_number,
                 institution: originator_details.originator_return_institution,
                 return_account: originator_details.originator_return_account
               },
               receiver: details
             )

    assert artifact.rail == :eft_cad
    assert artifact.file_creation_number == "0001"
    assert artifact.name == "eft-KUBE-EFT-1.txt"
    assert artifact.receiver_institution_last4 == "004"
    assert artifact.receiver_transit_last4 == "0202"
    assert {:ok, ^file} = ApAchArtifact.reveal(artifact, Samenerp.Repo)

    # The sequence is durable: the next allocation is 0002 and a re-render of
    # the stored run with 0001 is byte-identical.
    assert {:ok, "0002"} =
             ApEftOriginatorProfile.allocate_file_creation_number(
               Samenerp.Repo,
               originator,
               :test
             )

    assert {:ok, ^file} = ApEftFile.render(run_for_vendor, opts)
  end
end
