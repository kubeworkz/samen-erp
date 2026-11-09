defmodule Samen.FinanceVendorPaymentProfileTest do
  @moduledoc """
  The vendor payment profile's control model:

    * ABA/ACH prevalidation before storage;
    * bank details at rest are vault tokens, never plaintext;
    * verification requires a different principal than the last changer;
    * changing a bank detail resets verification and clears the evidence;
    * ACH payment details are refused until the profile is verified;
    * profiles are org-pinned.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.VendorPaymentProfile

  @repo SamenCore.TestRepo

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()

    member = scope("member:#{org}", org, :member)
    admin = scope("admin:#{org}", org, :admin)
    owner = scope("owner:#{org}", org, :owner)

    %{org: org, member: member, admin: admin, owner: owner, vendor: Ash.UUID.generate()}
  end

  defp scope(id, org, role) do
    %Samen.Scope{
      actor: %{id: id, org_id: org, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp register!(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          repo: @repo,
          scope: ctx.member,
          vendor_id: ctx.vendor,
          bank_name: "First Sample Bank",
          account_holder: "Acme Supply Co",
          account_number: "123456789",
          routing_number: "011000015",
          account_type: "checking"
        },
        overrides
      )

    {:ok, profile} = VendorPaymentProfile.register(Map.to_list(attrs))
    profile
  end

  test "prevalidates the ABA checksum and the ACH field limits" do
    base = [
      bank_name: "First Sample Bank",
      account_holder: "Acme Supply Co",
      account_number: "123456789",
      routing_number: "011000015",
      account_type: "checking"
    ]

    assert {:ok, %{account_last4: "6789", account_type: :checking}} =
             VendorPaymentProfile.prevalidate(base)

    assert {:error, :routing_number_invalid} =
             VendorPaymentProfile.prevalidate(Keyword.put(base, :routing_number, "021000022"))

    assert {:error, :account_number_too_long} =
             VendorPaymentProfile.prevalidate(
               Keyword.put(base, :account_number, String.duplicate("1", 18))
             )

    assert {:error, :account_number_invalid} =
             VendorPaymentProfile.prevalidate(Keyword.put(base, :account_number, "1234-56789"))

    assert {:error, :account_holder_required} =
             VendorPaymentProfile.prevalidate(Keyword.put(base, :account_holder, " "))

    assert {:error, :account_type_invalid} =
             VendorPaymentProfile.prevalidate(Keyword.put(base, :account_type, "wire"))
  end

  test "stores bank details only as vault tokens", ctx do
    profile = register!(ctx)

    assert profile.status == :unverified
    assert profile.account_last4 == "6789"
    assert profile.changed_by == ctx.member.actor.id

    %{rows: [[account_token, routing_token, status]]} =
      @repo.query!(
        "SELECT pii_fvp_account_number, pii_fvp_routing_number, fvp_status " <>
          "FROM fvp_vendor_payment_profile WHERE fvp_id = $1",
        [Ecto.UUID.dump!(profile.id)]
      )

    assert String.starts_with?(account_token, "vt_")
    assert String.starts_with?(routing_token, "vt_")
    refute account_token =~ "123456789"
    assert status == "unverified"

    # A second profile for the same vendor is refused; a change is the path.
    assert {:error, :already_registered} =
             VendorPaymentProfile.register(
               repo: @repo,
               scope: ctx.member,
               vendor_id: ctx.vendor,
               bank_name: "First Sample Bank",
               account_holder: "Acme Supply Co",
               account_number: "987654321",
               routing_number: "011000015"
             )
  end

  test "verification requires a distinct admin and is the only route to plaintext", ctx do
    profile = register!(ctx)

    assert {:error, :forbidden} =
             VendorPaymentProfile.verify(
               repo: @repo,
               scope: ctx.member,
               vendor_id: ctx.vendor
             )

    assert {:error, :self_verification} =
             VendorPaymentProfile.verify(
               repo: @repo,
               scope: scope(ctx.member.actor.id, ctx.org, :admin),
               vendor_id: ctx.vendor
             )

    assert {:ok, verified} =
             VendorPaymentProfile.verify(
               repo: @repo,
               scope: ctx.admin,
               vendor_id: ctx.vendor
             )

    assert verified.status == :verified
    assert verified.verified_by == ctx.admin.actor.id

    assert {:ok, details} = VendorPaymentProfile.payment_details(verified, @repo)
    assert details.receiver_name == "Acme Supply Co"
    assert details.receiver_account == "123456789"
    assert details.receiver_dfi == "011000015"
    assert details.account_type == :checking

    assert {:error, :already_verified} =
             VendorPaymentProfile.verify(
               repo: @repo,
               scope: ctx.owner,
               vendor_id: ctx.vendor
             )

    assert {:ok, %{status: :verified, vendor_id: vendor_id}} =
             VendorPaymentProfile.get(@repo, ctx.org, profile.vendor_id)

    assert vendor_id == ctx.vendor
  end

  test "a bank-detail change resets verification and cannot self-verify", ctx do
    profile = register!(ctx)

    assert {:ok, _verified} =
             VendorPaymentProfile.verify(repo: @repo, scope: ctx.admin, vendor_id: ctx.vendor)

    assert {:ok, changed} =
             VendorPaymentProfile.change_bank_details(
               repo: @repo,
               scope: ctx.owner,
               vendor_id: ctx.vendor,
               bank_name: "Second Sample Bank",
               account_holder: "Acme Supply Co",
               account_number: "987654321",
               routing_number: "021000021",
               account_type: "savings"
             )

    assert changed.status == :unverified
    assert changed.account_last4 == "4321"
    assert changed.changed_by == ctx.owner.actor.id
    assert is_nil(changed.verified_by)
    assert is_nil(changed.verified_at)

    assert {:error, :unverified} = VendorPaymentProfile.payment_details(changed, @repo)

    assert {:error, :self_verification} =
             VendorPaymentProfile.verify(repo: @repo, scope: ctx.owner, vendor_id: ctx.vendor)

    assert {:ok, reverified} =
             VendorPaymentProfile.verify(repo: @repo, scope: ctx.admin, vendor_id: ctx.vendor)

    assert {:ok, details} = VendorPaymentProfile.payment_details(reverified, @repo)
    assert details.receiver_account == "987654321"
    assert details.receiver_dfi == "021000021"
    assert details.account_type == :savings

    # The old account is still the stored token on the ORIGINAL row? No — the
    # row keeps its identity, and the verified destination is now the new one.
    assert profile.id == changed.id
  end

  test "a profile is org-pinned", ctx do
    register!(ctx)

    other_org = Ash.UUID.generate()
    foreign_admin = scope("admin:foreign", other_org, :admin)

    assert {:ok, nil} = VendorPaymentProfile.get(@repo, other_org, ctx.vendor)

    assert {:error, :not_found} =
             VendorPaymentProfile.verify(
               repo: @repo,
               scope: foreign_admin,
               vendor_id: ctx.vendor
             )
  end
end
