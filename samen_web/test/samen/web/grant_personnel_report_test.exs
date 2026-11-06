defmodule Samen.Web.GrantPersonnelReportTest do
  @moduledoc """
  WS-ACCT Phase 11 — the grant personnel report masking watch-list proof
  (ADR-054 D8/§4; design §4).

  The report resolves the opaque HR employee id through `PiiResolution` on the
  acting plane. This test drives the SAME projection through all three egress
  paths and asserts the masking watch-list trio:

    * GREEN — tenant own-org DOM/CSV/JSON carry the name in the CLEAR;
    * RED — operator DOM/CSV/JSON carry `••••`, never the plaintext, never a
      `vt_*` token;
    * SABOTAGE — the committed 418 patch flips the projection to the tenant
      plane and these red assertions fail (the refutability twin).

  It also proves the bounded-facts fallback: a host with no HR namespace gets
  employee ids, effort, and dates only — never an invented name.
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Plug.Conn
  import Plug.Test

  alias Samen.Web.Csv
  alias Samen.Web.CurrentOrg
  alias Samen.Web.GrantPersonnel, as: Report
  alias Samen.Web.GrantPersonnel.ApiController
  alias Samen.Web.GrantPersonnel.CsvController
  alias Samen.Web.GrantPersonnel.Live
  alias Samen.Web.Mount
  alias Samen.Web.Plane

  alias Samen.WebTest.Erp.{CostObject, Grant, GrantPersonnel}
  alias Samen.WebTest.Hr.Employee
  alias Samen.WebTest.Repo

  @secret_first "GrantReportFirst"
  @secret_last "GrantReport-Secret"

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp mount(org_id, plane \\ :tenant) do
    plane =
      case plane do
        :operator -> Plane.operator("op-1", org_id, "grant-report-session")
        _ -> Plane.tenant()
      end

    Mount.new(:erp, Samen.WebTest.Erp, Repo,
      plane: plane,
      labels: %{grants_path: "/grants", personnel_namespace: Samen.WebTest.Hr}
    )
  end

  defp bounded_mount(_org_id) do
    Mount.new(:erp, Samen.WebTest.Erp, Repo,
      plane: Plane.tenant(),
      labels: %{grants_path: "/grants"}
    )
  end

  defp seed_report! do
    org_id = Ash.UUID.generate()
    admin = admin_scope(org_id)

    fund =
      CostObject
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, code: "FUND-GRANT", name: "Grant fund", kind: :fund},
        scope: admin
      )
      |> Ash.create!()

    employee =
      Employee
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          employee_number: "EMP-GRANT",
          hired_at: ~D[2024-01-01],
          employment_type: :full_time,
          full_name: %Samen.Type.FullName{first: @secret_first, last: @secret_last}
        },
        scope: admin
      )
      |> Ash.create!()

    grant =
      Grant
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          funder: "NSERC",
          program: "Alliance",
          award_ref: "GR-REPORT-#{System.unique_integer([:positive])}",
          award_cents: 120_000,
          period_start: ~D[2026-01-01],
          period_end: ~D[2026-12-31],
          fund_cost_object_id: fund.id
        },
        scope: admin
      )
      |> Ash.create!()

    GrantPersonnel
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        grant_id: grant.id,
        employee_id: employee.id,
        effort_pct: 40,
        effective_on: ~D[2026-01-01]
      },
      scope: admin
    )
    |> Ash.create!()

    %{org_id: org_id, grant: grant, employee: employee}
  end

  defp report_conn(org_id, mount, path) do
    opts =
      Plug.Session.init(
        store: :cookie,
        key: "_grant_report_test",
        signing_salt: "grant_report_salt",
        encryption_salt: "grant_report_enc_salt"
      )

    conn(:get, path)
    |> Map.put(:secret_key_base, String.duplicate("g", 64))
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> put_session(CurrentOrg.session_key(), org_id)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  defp csv_cell(csv, column) do
    [header | rows] = Csv.parse(csv)
    idx = Enum.find_index(header, &(&1 == column))
    assert idx, "#{column} column missing from export header"
    [row] = rows
    Enum.at(row, idx)
  end

  describe "the shared report projection" do
    test "GREEN: tenant owns the name; RED: operator gets the mask — never plaintext or a token" do
      %{org_id: org_id, grant: grant} = seed_report!()

      {:ok, tenant} = Report.load(mount(org_id), org_id, grant.id)
      assert [tenant_row] = tenant.rows
      assert tenant_row.name =~ @secret_first
      assert tenant_row.name =~ @secret_last
      refute tenant_row.name =~ "vt_"

      {:ok, operator} = Report.load(mount(org_id, :operator), org_id, grant.id)
      assert [operator_row] = operator.rows
      assert operator_row.name == mask()
      refute operator_row.name =~ @secret_first
      refute operator_row.name =~ "vt_"

      # The plane flip is the anti-tautology: the ONLY difference is the mount.
      assert tenant_row.name != operator_row.name
    end

    test "the grant read is org-scoped (another org sees not_found, never this report)" do
      %{grant: grant} = seed_report!()
      other_org = Ash.UUID.generate()

      assert {:error, :not_found} =
               Report.load(mount(other_org), other_org, grant.id)
    end
  end

  describe "DOM egress" do
    test "tenant page renders the clear name and the CSV/JSON links" do
      %{org_id: org_id, grant: grant} = seed_report!()

      html = mount_smoke(Live, mount(org_id), %{"org" => org_id, "id" => grant.id})

      assert html =~ ~s(id="grant-personnel-report")
      assert html =~ "/grants?org=#{org_id}"
      assert html =~ ~s(href="/grants?org=#{org_id}" class="on")
      assert html =~ @secret_first
      assert html =~ @secret_last
      refute html =~ "vt_"
      assert html =~ "/grants/#{grant.id}/personnel.csv?org=#{org_id}"
      assert html =~ "/grants/#{grant.id}/personnel.json?org=#{org_id}"
    end

    test "operator page is ••••, with no plaintext and no token" do
      %{org_id: org_id, grant: grant, employee: employee} = seed_report!()

      html =
        mount_smoke(Live, mount(org_id, :operator), %{"org" => org_id, "id" => grant.id})

      assert_masked_dom!(html, [@secret_first, @secret_last])
      assert html =~ ~s(id="grant-personnel-#{employee.id}")
      assert html =~ "Grant personnel report"
    end
  end

  describe "CSV egress" do
    test "tenant CSV carries the clear name; operator CSV masks the SAME cell" do
      %{org_id: org_id, grant: grant} = seed_report!()

      tenant_conn =
        report_conn(org_id, mount(org_id), "/grants/#{grant.id}/personnel.csv")
        |> CsvController.export(%{"id" => grant.id, "org" => org_id})

      assert tenant_conn.status == 200
      assert tenant_conn.resp_body =~ @secret_first
      refute tenant_conn.resp_body =~ "vt_"

      operator_conn =
        report_conn(org_id, mount(org_id, :operator), "/grants/#{grant.id}/personnel.csv")
        |> CsvController.export(%{"id" => grant.id, "org" => org_id})

      assert operator_conn.status == 200
      assert_masked_dom!(operator_conn.resp_body, [@secret_first, @secret_last])
      assert csv_cell(operator_conn.resp_body, "name") == mask()
    end
  end

  describe "API egress" do
    test "tenant JSON carries the clear name; operator JSON masks the SAME row" do
      %{org_id: org_id, grant: grant} = seed_report!()

      tenant_conn =
        report_conn(org_id, mount(org_id), "/grants/#{grant.id}/personnel.json")
        |> ApiController.show(%{"id" => grant.id, "org" => org_id})

      assert tenant_conn.status == 200
      tenant_body = Jason.decode!(tenant_conn.resp_body)
      [tenant_row] = tenant_body["data"]["attributes"]["rows"]
      assert tenant_row["name"] =~ @secret_first
      refute tenant_conn.resp_body =~ "vt_"

      operator_conn =
        report_conn(org_id, mount(org_id, :operator), "/grants/#{grant.id}/personnel.json")
        |> ApiController.show(%{"id" => grant.id, "org" => org_id})

      assert operator_conn.status == 200
      operator_body = Jason.decode!(operator_conn.resp_body)
      [operator_row] = operator_body["data"]["attributes"]["rows"]
      assert operator_row["name"] == mask()
      refute operator_conn.resp_body =~ @secret_first
      refute operator_conn.resp_body =~ "vt_"
    end
  end

  describe "bounded-facts fallback (no HR namespace)" do
    test "the page reports employee id/effort/date and honestly marks names unwired" do
      %{org_id: org_id, grant: grant, employee: employee} = seed_report!()

      {:ok, report} = Report.load(bounded_mount(org_id), org_id, grant.id)
      refute report.personnel_wired?
      assert [row] = report.rows
      assert row.name == nil
      assert row.employee_id == employee.id

      html =
        mount_smoke(Live, bounded_mount(org_id), %{"org" => org_id, "id" => grant.id})

      assert html =~ ~s(id="grant-personnel-unwired")
      assert html =~ employee.id
      assert html =~ "40%"
      refute html =~ @secret_first
    end

    test "CSV and JSON carry the bounded facts with no name value" do
      %{org_id: org_id, grant: grant} = seed_report!()

      csv_conn =
        report_conn(org_id, bounded_mount(org_id), "/grants/#{grant.id}/personnel.csv")
        |> CsvController.export(%{"id" => grant.id, "org" => org_id})

      assert csv_cell(csv_conn.resp_body, "name") == ""

      json_conn =
        report_conn(org_id, bounded_mount(org_id), "/grants/#{grant.id}/personnel.json")
        |> ApiController.show(%{"id" => grant.id, "org" => org_id})

      body = Jason.decode!(json_conn.resp_body)
      assert body["data"]["attributes"]["personnel_wired"] == false
      assert [row] = body["data"]["attributes"]["rows"]
      assert row["name"] == nil
    end
  end
end
