defmodule Samen.Web.HrRosterCsvMaskingTest do
  @moduledoc """
  WS-ERP E7 — THE HR ROSTER CSV MASK-BY-OMISSION RED-PATH (design §5; the
  WS-E E3.2 / RP-CSV-1 discipline on the HR roster surface).

  Consumer of `Samen.MaskingCase` — the green/red/sabotage discipline of the
  shipped `CsvMaskingTest`, on the E7 roster (`Samen.Web.Hr.Roster`):

    * **GREEN** — tenant own-org roster export carries the vaulted
      `full_name` in the CLEAR (the JSON plaintext), never a `vt_` token.
    * **RED** — operator export cell is exactly `••••`: never the plaintext,
      never a vault token, and EQUAL to the UI value (the resolver output
      stringified) — the same-pixel rule.
    * **SABOTAGE twins** — the plane flip (the SAME rows on the tenant plane
      go clear) and the refutable leak scan (a modeled raw-token cell IS
      caught).
    * **Mask-by-omission** — the roster's bounded allowlist: `dob` /
      `work_emails` / `work_phones` are structurally ABSENT from the surface;
      requesting one is REFUSED (not dropped), so no plane and no caller can
      widen the roster into a leak channel.
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Masked
  alias Samen.Web.Csv
  alias Samen.Web.Hr.Roster
  alias Samen.Web.Plane
  alias Samen.WebTest.Hr.Employee
  alias Samen.WebTest.Repo

  @secret_first "VaultedRoster"
  @secret_last "Roster-Secret"
  @secret_email "roster-secret@example.test"
  @secret_dob "1980-04-12"

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "hr-roster-session"), org_id)

  defp seed_secret_employee!(org_id) do
    scope = tenant_scope(org_id)

    Employee
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      employee_number: "EMP-SECRET",
      hired_at: ~D[2026-02-01],
      employment_type: :full_time,
      full_name: %Samen.Type.FullName{first: @secret_first, last: @secret_last},
      work_emails: [%{label: "work", address: @secret_email}],
      work_phones: [%{label: "mobile", number: "+1-555-0199"}],
      dob: ~D[1980-04-12]
    })
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp at_rest!(org_id) do
    Employee
    |> Ash.Query.filter(org_id == ^org_id and employee_number == "EMP-SECRET")
    |> Ash.Query.ensure_selected([:full_name, :dob])
    |> Ash.read_one!(authorize?: false)
  end

  defp cell(csv, column) do
    [header | rows] = Csv.parse(csv)
    idx = Enum.find_index(header, &(&1 == to_string(column)))
    assert idx, "#{column} column missing from export header"
    [row] = rows
    Enum.at(row, idx)
  end

  describe "roster export masking per plane (WS-ERP E7; RP-CSV-1)" do
    test "GREEN: tenant own-org roster carries the vaulted full_name in the CLEAR" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      {:ok, csv} = Roster.export(tenant_scope(org_id), repo: Repo)

      assert csv =~ @secret_first
      assert csv =~ @secret_last
      refute csv =~ "vt_"
      # The bounded employment facts ride along unmasked.
      assert csv =~ "EMP-SECRET"
    end

    test "RED: operator roster cell is •••• — NEVER plaintext, NEVER a token" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      {:ok, csv} = Roster.export(operator_scope(org_id), repo: Repo)

      assert_masked_dom!(csv, [@secret_first, @secret_last])
      assert cell(csv, :full_name) == mask()
      # Non-PII cells are untouched: masking is per-field, not per-file.
      assert csv =~ "EMP-SECRET"
    end

    test "the roster cell EQUALS the UI value on the operator plane (same-pixel)" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      ui_value =
        at_rest!(org_id)
        |> resolve_on_plane(Employee, :operator, repo: Repo)
        |> Map.get(:full_name)

      assert_plane_masked!(ui_value)

      {:ok, csv} = Roster.export(operator_scope(org_id), repo: Repo)
      assert cell(csv, :full_name) == to_string(ui_value)
    end

    test "ANTI-TAUTOLOGY: the SAME rows on the tenant plane go CLEAR (plane flip)" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      {:ok, operator_csv} = Roster.export(operator_scope(org_id), repo: Repo)
      assert_masked_dom!(operator_csv, [@secret_first])

      {:ok, tenant_csv} = Roster.export(tenant_scope(org_id), repo: Repo)
      assert tenant_csv =~ @secret_first
      refute tenant_csv =~ mask()
    end

    test "ANTI-TAUTOLOGY: a modeled raw-token cell IS caught by the leak scan" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      assert %Masked{token: "vt_" <> _ = token} = at_rest!(org_id).full_name

      leaked_csv = Csv.serialize([["full_name"], [token]])
      assert_leak_detected!(leaked_csv, "vt_")
    end
  end

  describe "mask-by-omission: the roster's bounded allowlist" do
    test "the header carries ONLY the allowlisted columns — the sensitive trio is absent" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      {:ok, csv} = Roster.export(tenant_scope(org_id), repo: Repo)
      [header | _] = Csv.parse(csv)

      for col <- Roster.columns(), do: assert(to_string(col) in header)

      # The no-directory-need fields are structurally ABSENT — the surface
      # cannot leak them on any plane because it never emits them.
      refute "dob" in header
      refute "work_emails" in header
      refute "work_phones" in header

      # Even the secret dob/email values are nowhere in the export at all.
      refute csv =~ @secret_dob
      refute csv =~ @secret_email
    end

    test "a caller may NARROW the allowlist but never WIDEN it" do
      org_id = Ash.UUID.generate()
      seed_secret_employee!(org_id)

      # Narrow: only the number column.
      {:ok, csv} = Roster.export(tenant_scope(org_id), repo: Repo, columns: [:employee_number])
      [header | _] = Csv.parse(csv)
      assert header == ["employee_number"]

      # Widen: an unlisted column is REFUSED (fail-closed), not dropped.
      assert {:error, {:unknown_columns, [:dob]}} =
               Roster.export(tenant_scope(org_id), repo: Repo, columns: [:employee_number, :dob])
    end
  end
end
