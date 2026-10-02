defmodule Samen.Web.CrumbsTest do
  @moduledoc """
  Unit tests for `Samen.Web.Crumbs` — the shared linked-breadcrumb builder the
  tenant topbar trails use.

    * `home/2` always points at the CRM Dashboard (the `:crm_path` label, no
      hardcoded host path) with `?org=` threaded exactly like the sidebar.
    * `org/2` pairs the resolved org display name with that home href — the
      "back to my workspace" crumb every tenant trail shares.
    * `section/3` maps each known section key to its REAL section root (the
      whitelisted mount path labels, router `default_path/1` literals as the
      fallback) and refuses unknown keys (closed map).
  """
  use Samen.WebTest.DataCase, async: true

  alias Samen.Web.Crumbs
  alias Samen.Web.Mount

  describe "home/2" do
    test "points at the CRM dashboard with the org threaded" do
      mount = build_mount(:crm)
      assert Crumbs.home(mount, "ORG-1") == "/crm/dashboard?org=ORG-1"
    end

    test "omits ?org= when no org is resolved (session pin still resolves server-side)" do
      mount = build_mount(:crm)
      assert Crumbs.home(mount, nil) == "/crm/dashboard"
      assert Crumbs.home(mount, "") == "/crm/dashboard"
    end

    test "honors a host :crm_path override (no hardcoded host path)" do
      mount = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, labels: %{crm_path: "/customers"})
      assert Crumbs.home(mount, "ORG-1") == "/customers/dashboard?org=ORG-1"
    end
  end

  describe "org/2" do
    test "pairs the org display name with the workspace home" do
      mount = build_mount(:crm)
      # No directory row for ORG-1 → the mount-:title fallback name, still linked home.
      assert Crumbs.org(mount, "ORG-1") == {"Workspace", "/crm/dashboard?org=ORG-1"}
    end
  end

  describe "section/3" do
    test "maps known section keys to their roots with the org threaded" do
      mount = build_mount(:crm)

      assert Crumbs.section(mount, "ORG-1", :work) == {"Work", "/work?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :support) == {"Support", "/support?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :billing) == {"Billing", "/billing?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :marketing) == {"Marketing", "/marketing/campaigns?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :settings) == {"Settings", "/settings?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :chat) == {"Chat", "/chat?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :inbox) == {"Inbox", "/notifications?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :files) == {"Files", "/files?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :companies) == {"Companies", "/crm/companies?org=ORG-1"}
      assert Crumbs.section(mount, "ORG-1", :contacts) == {"Contacts", "/crm/contacts?org=ORG-1"}
    end

    test "omits ?org= when no org is resolved" do
      mount = build_mount(:crm)
      assert Crumbs.section(mount, nil, :work) == {"Work", "/work"}
    end

    test "an unknown section key raises (closed map)" do
      mount = build_mount(:crm)
      # apply/3 so the compiler's closed-map type check doesn't flag the literal :nope.
      assert_raise FunctionClauseError, fn -> apply(Crumbs, :section, [mount, "ORG-1", :nope]) end
    end
  end
end
