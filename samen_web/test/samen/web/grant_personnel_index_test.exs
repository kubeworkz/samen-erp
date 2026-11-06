defmodule Samen.Web.GrantPersonnelIndexTest do
  @moduledoc """
  WS-ACCT Phase 11 — the bounded grants index.

  The index is the entry point to the grant personnel report. It must list
  awards through the `Samen.Web.ListLive` bounded reads contract and link each
  row to `/grants/:id`; the list itself carries no personnel name.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.GrantPersonnel.Index
  alias Samen.Web.GrantPersonnel.IndexLive
  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Plane
  alias Samen.Web.Reads

  alias Samen.WebTest.Erp.{CostObject, Grant}
  alias Samen.WebTest.Repo

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp mount(_org_id) do
    Mount.new(:erp, Samen.WebTest.Erp, Repo,
      plane: Plane.tenant(),
      labels: %{grants_path: "/grants"}
    )
  end

  defp seed_grants!(count) do
    org_id = Ash.UUID.generate()
    admin = admin_scope(org_id)

    fund =
      CostObject
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, code: "FUND-INDEX", name: "Index fund", kind: :fund},
        scope: admin
      )
      |> Ash.create!()

    grants =
      for n <- 1..count do
        Grant
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            funder: "Funder #{n}",
            program: "Program #{n}",
            award_ref: "GR-INDEX-#{String.pad_leading(Integer.to_string(n), 2, "0")}",
            award_cents: 100_000 + n,
            period_start: ~D[2026-01-01],
            period_end: ~D[2026-12-31],
            fund_cost_object_id: fund.id
          },
          scope: admin
        )
        |> Ash.create!()
      end

    %{org_id: org_id, grants: grants}
  end

  describe "bounded read" do
    test "returns at most one clamped page and reports more rows" do
      %{org_id: org_id} = seed_grants!(12)
      mount = mount(org_id)
      scope = Mount.scope(mount, org_id)

      assert :ok = Reads.bounded!(&Index.grants_page/3, mount, scope, page_size: 10)

      page = Index.grants_page(mount, scope, %ListState{page_size: 10})
      assert length(page.items) == 10
      assert page.page_size == 10
      assert page.has_more
      assert page.next_cursor != nil
    end

    test "another org sees no grants" do
      %{grants: [grant | _]} = seed_grants!(2)
      other_org = Ash.UUID.generate()
      other_mount = mount(other_org)

      page =
        Index.grants_page(other_mount, Mount.scope(other_mount, other_org), %ListState{
          page_size: 10
        })

      assert page.items == []
      refute Enum.any?(page.items, &(&1.id == grant.id))
    end
  end

  describe "index page" do
    test "lists each award and links it to the personnel report" do
      %{org_id: org_id, grants: [first, second]} = seed_grants!(2)

      html = mount_smoke(IndexLive, mount(org_id), %{"org" => org_id})

      assert html =~ ~s(id="grants-index")
      assert html =~ ~s(id="grants-list")
      assert html =~ first.award_ref
      assert html =~ second.award_ref
      assert html =~ "/grants/#{first.id}?org=#{org_id}"
      assert html =~ "/grants/#{second.id}?org=#{org_id}"
      assert html =~ ~s(href="/grants?org=#{org_id}" class="on")
      assert html =~ "Open"
      refute html =~ "vt_"
    end

    test "filters the index through the same bounded read" do
      %{org_id: org_id, grants: grants} = seed_grants!(3)
      target = Enum.at(grants, 2)
      mount = mount(org_id)
      scope = Mount.scope(mount, org_id)

      page =
        Index.grants_page(mount, scope, %ListState{
          page_size: 10,
          filter: target.award_ref
        })

      assert [row] = page.items
      assert row.id == target.id
    end
  end
end
