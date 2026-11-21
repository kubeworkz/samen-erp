defmodule Samenerp.OperatorBookTest do
  @moduledoc """
  ADR-010 §3.3 (Bridge-B) on the samenerp host: the operator's book of business must mirror
  every TENANT org, not only rows an operator created by hand.

  `Samen.Web.Operator.Reads.accounts_page/3` (what `/operator/accounts` renders) reads `Org`
  rows with `org_id == <operator org>` and takes each row's `slug` as the `tenant_org_id` the
  "Open account →" form posts. A self-serve signup creates its org with `org_id: nil,
  slug: nil` (`Samen.Identity.Register.create_org/2`), so WITHOUT the `:org_provisioning`
  hook that org is invisible to the console and has no act-as target — the gap this file
  pins in both directions:

    * RED — a freshly created tenant org is NOT in the book and NOT on the console page;
    * GREEN — the SAME org, after the provisioning seam the signup controller calls
      (`Samen.Web.OrgProvisioning.run/2`), appears with the operator-org scope and the
      tenant `slug`, and the console page lists it with that back-reference;
    * the mirror is idempotent, never duplicates an operator-created account, and the boot
      backfill repairs tenants that predate the hook.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Web.{ListState, Mount, OrgProvisioning, Plane}
  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads
  alias Samenerp.Operator, as: Op

  setup do
    {:ok, %{org: operator_org}} = Samenerp.Seeds.ensure_admin!()
    %{operator_org_id: operator_org.id}
  end

  # A tenant org shaped exactly like a signup's: name only (org_id/slug stay nil).
  defp tenant_org!(label) do
    Op.Org
    |> Ash.Changeset.for_create(
      :create,
      %{name: "#{label} #{System.unique_integer([:positive])}"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp book_rows(operator_org_id, tenant_org_id) do
    Op.Org
    |> Ash.Query.filter(
      org_id == ^operator_org_id and (id == ^tenant_org_id or slug == ^tenant_org_id)
    )
    |> Ash.read!(authorize?: false)
  end

  defp identity_mount, do: Mount.new(:identity, Samenerp.Operator, Samenerp.Repo)

  # The operator workspace mount (ADR-010): tenant plane over the operator org, with the
  # operator org threaded on the labels exactly as the host router does.
  defp operator_mount(operator_org_id) do
    Mount.new(:operator, Samenerp.Operator, Samenerp.Repo,
      plane: Plane.tenant(),
      labels: %{operator_org_id: operator_org_id}
    )
  end

  defp console_items(operator_org_id) do
    mount = operator_mount(operator_org_id)
    %{items: items} = Reads.accounts_page(mount, Operator.scope(mount), %ListState{})
    items
  end

  test "the provisioning seam mirrors a signup org into the operator book and console",
       %{operator_org_id: operator_org_id} do
    org = tenant_org!("Acme")

    # RED — the signup shape is invisible to the operator-org-scoped read.
    assert book_rows(operator_org_id, org.id) == []
    refute Enum.any?(console_items(operator_org_id), &(&1.tenant_org_id == org.id))

    # The exact seam `Samen.Web.Auth.AccountController.register/2` (and the operator
    # console's "New account") calls after the org row commits.
    assert :ok = OrgProvisioning.run(identity_mount(), org.id)

    # GREEN — one operator-book row: operator-org scoped, tenant id as the back-reference.
    assert [row] = book_rows(operator_org_id, org.id)
    assert row.org_id == operator_org_id
    assert row.id != org.id
    assert row.slug == org.id
    assert row.name == org.name
    assert row.plan == (org.plan || "free")

    assert Enum.any?(console_items(operator_org_id), fn account ->
             account.tenant_org_id == org.id and account.name == org.name
           end)
  end

  test "the mirror is idempotent and never duplicates an operator-created account",
       %{operator_org_id: operator_org_id} do
    org = tenant_org!("Repeat")

    assert :ok = OrgProvisioning.run(identity_mount(), org.id)
    assert :ok = OrgProvisioning.run(identity_mount(), org.id)
    assert [_one] = book_rows(operator_org_id, org.id)

    # An operator-created account row IS the tenant org (its own id); mirroring it must
    # add nothing, and the operator org itself is skipped.
    account =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: operator_org_id, name: "Operator-created", plan: "free"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert :ok = Samenerp.Seeds.ensure_operator_account!(account.id)
    assert [row] = book_rows(operator_org_id, account.id)
    assert row.id == account.id
    assert row.slug == nil

    refute Op.Org
           |> Ash.read!(authorize?: false)
           |> Enum.any?(&(&1.slug == account.id))

    assert :ok = Samenerp.Seeds.ensure_operator_account!(operator_org_id)
  end

  test "the boot backfill repairs tenants that predate the hook",
       %{operator_org_id: operator_org_id} do
    legacy = tenant_org!("Legacy")
    assert book_rows(operator_org_id, legacy.id) == []

    assert :ok = Samenerp.Seeds.backfill_operator_accounts!()
    assert [row] = book_rows(operator_org_id, legacy.id)
    assert row.slug == legacy.id

    # Idempotent on the second boot.
    assert :ok = Samenerp.Seeds.backfill_operator_accounts!()
    assert [_one] = book_rows(operator_org_id, legacy.id)
  end
end
