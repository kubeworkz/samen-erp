defmodule Samenerp.GustoPayrollAdapterTest do
  @moduledoc """
  The ONE design-partner payroll adapter (Gusto) on the REAL host schema.

  What this pins:

    * redaction is an allowlist — employee names/emails/SSNs/compensation rows
      never reach the durable envelope;
    * the register uses ONLY Gusto's provider-computed debit totals, never a
      host-side payroll calculation;
    * the host still lands a DRAFT through the existing `JournalProvider`
      mapping/preflight path, and a retry is idempotent;
    * a missing mapping and an unbalanced payload fail closed with a bounded
      reason and write no entry; non-`payroll.paid` events are acknowledged
      no-ops;
    * one real signed delivery through the mounted `POST /ingest/:provider`
      route persists a redacted envelope and imports through the worker.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samen.Ingest.Contract
  alias Samenerp.Payroll.GustoAdapter

  @endpoint SamenerpWeb.Endpoint
  @secret "gusto-design-partner-test-secret"
  @payroll_uuid "gusto-payroll-2026-09-30"
  @company_debit 12_174_771
  @pii_name "Jane Leaky"
  @pii_email "leaky.jane@example.invalid"
  @pii_ssn "000-00-0000"
  @pii_bank "123456789"

  setup do
    start_supervised!(@endpoint)
    Samen.Web.RateLimit.reset()

    org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "a:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }

    expense = account!(scope, org, "6100", :expense, :debit)
    net_pay = account!(scope, org, "2110", :liability, :credit)
    tax = account!(scope, org, "2200", :liability, :credit)
    reimbursement = account!(scope, org, "2300", :liability, :credit)
    child_support = account!(scope, org, "2400", :liability, :credit)

    mapping!(scope, org, "gusto:company_debit", expense)
    mapping!(scope, org, "gusto:net_pay", net_pay)
    mapping!(scope, org, "gusto:tax_debit", tax)
    mapping!(scope, org, "gusto:reimbursement_debit", reimbursement)
    mapping!(scope, org, "gusto:child_support_debit", child_support)

    Application.put_env(:samen_core, Samen.Ingest,
      repo: Samenerp.Repo,
      providers: %{
        "gusto" =>
          {GustoAdapter, %{secret: @secret, org_id: org, schema_versions: [1], max_attempts: 3}}
      }
    )

    on_exit(fn -> Application.delete_env(:samen_core, Samen.Ingest) end)

    {:ok,
     org: org,
     expense_id: expense.id,
     net_pay_id: net_pay.id,
     tax_id: tax.id,
     reimbursement_id: reimbursement.id,
     child_support_id: child_support.id}
  end

  test "redacts employee PII before persistence" do
    raw = payroll()

    # Anti-tautology: the fixture really does contain the PII we claim to drop.
    assert inspect(raw) =~ @pii_name
    assert inspect(raw) =~ @pii_email

    redacted = GustoAdapter.redact_payload(%{"payroll" => raw})

    assert redacted["payroll"]["payroll_uuid"] == @payroll_uuid
    assert redacted["payroll"]["check_date"] == "2026-09-30"
    assert redacted["payroll"]["pay_period"] == raw["pay_period"]
    assert redacted["payroll"]["totals"]["company_debit"] == "121747.71"
    assert redacted["payroll"]["totals"]["tax_debit"] == "42463.91"

    refute Map.has_key?(redacted["payroll"], "employee_compensations")
    refute inspect(redacted) =~ @pii_name
    refute inspect(redacted) =~ @pii_email
    refute inspect(redacted) =~ @pii_ssn
    refute inspect(redacted) =~ @pii_bank

    assert GustoAdapter.redact_payload(%{}) == %{}
    assert GustoAdapter.redact_payload(%{"payroll" => "not-a-map"}) == %{}
  end

  test "imports one balanced draft from the provider totals, idempotently", %{
    org: org,
    expense_id: expense_id,
    net_pay_id: net_pay_id,
    tax_id: tax_id
  } do
    envelope = envelope()

    assert :ok = GustoAdapter.handle(envelope, config: %{org_id: org})
    assert :ok = GustoAdapter.handle(envelope, config: %{org_id: org})

    assert [entry] = entries(org)
    assert entry.status == :draft
    assert entry.entry_date == ~D[2026-09-30]
    assert entry.source_key == "payroll_register:gusto:#{@payroll_uuid}"
    assert entry.prepared_by == "provider:gusto"

    assert length(entry.lines) == 3

    assert Enum.sort(Enum.map(entry.lines, & &1.account_id)) ==
             Enum.sort([expense_id, net_pay_id, tax_id])

    assert [debit_line] = Enum.filter(entry.lines, &(&1.debit_cents > 0))
    assert debit_line.account_id == expense_id

    assert sum(entry.lines, :debit_cents) == @company_debit
    assert sum(entry.lines, :credit_cents) == @company_debit

    import_row =
      Samenerp.Erp.PayrollImport
      |> Ash.Query.filter(org_id == ^org)
      |> Ash.read_one!(authorize?: false)

    assert import_row.provider == "gusto"
    assert import_row.external_id == @payroll_uuid
    assert import_row.total_cents == @company_debit
    assert import_row.status == :imported
    assert import_row.imported_by == "provider:gusto"
  end

  test "maps reimbursement and child-support credits when Gusto reports them", %{
    org: org,
    expense_id: expense_id,
    net_pay_id: net_pay_id,
    tax_id: tax_id,
    reimbursement_id: reimbursement_id,
    child_support_id: child_support_id
  } do
    full =
      payroll(%{
        "payroll_uuid" => "gusto-payroll-full-2026-09-30",
        "totals" => %{
          "company_debit" => "100.00",
          "net_pay_debit" => "80.00",
          "tax_debit" => "10.00",
          "reimbursement_debit" => "5.00",
          "child_support_debit" => "5.00"
        }
      })

    assert :ok = GustoAdapter.handle(envelope(full), config: %{org_id: org})

    assert [entry] = entries(org)
    assert length(entry.lines) == 5

    assert Enum.sort(Enum.map(entry.lines, & &1.account_id)) ==
             Enum.sort([
               expense_id,
               net_pay_id,
               tax_id,
               reimbursement_id,
               child_support_id
             ])

    assert sum(entry.lines, :debit_cents) == 10_000
    assert sum(entry.lines, :credit_cents) == 10_000
  end

  test "refuses a partner org with no mapping, writing nothing", %{org: org} do
    other_org = Ecto.UUID.generate()

    assert {:discard, :payroll_preflight_failed} =
             GustoAdapter.handle(envelope(), config: %{org_id: other_org})

    assert entries(other_org) == []
    assert entries(org) == []
  end

  test "refuses an unbalanced payload instead of inventing a balancing line", %{org: org} do
    unbalanced = %{
      payroll()
      | "totals" => %{
          "company_debit" => "100.00",
          "net_pay_debit" => "90.00",
          "tax_debit" => "5.00",
          "reimbursement_debit" => "0.00",
          "child_support_debit" => "0.00"
        }
    }

    assert {:discard, :totals_unbalanced} =
             GustoAdapter.handle(envelope(unbalanced), config: %{org_id: org})

    assert entries(org) == []
  end

  test "acknowledges unsupported events as a no-op and rejects malformed payloads", %{
    org: org
  } do
    assert :ok =
             GustoAdapter.handle(%{envelope() | event_type: "payroll.updated"},
               config: %{org_id: org}
             )

    assert {:discard, :malformed_payload} =
             GustoAdapter.handle(%{envelope() | payload: %{}}, config: %{org_id: org})

    assert {:discard, :org_not_configured} = GustoAdapter.handle(envelope(), config: %{})
    assert entries(org) == []
  end

  test "a signed delivery through the mounted route imports one draft via the worker", %{
    org: org
  } do
    body =
      Jason.encode!(%{
        "schema_version" => 1,
        "event_id" => "evt_gusto_route_#{System.unique_integer([:positive])}",
        "event_type" => "payroll.paid",
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "payload" => %{"payroll" => payroll()}
      })

    idempotency_key = "idem_gusto_route_#{System.unique_integer([:positive])}"
    timestamp = System.os_time(:second)
    signature = Contract.sign(body, timestamp, idempotency_key, @secret)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("samen-ingest-signature", signature)
      |> Plug.Conn.put_req_header("idempotency-key", idempotency_key)
      |> post("/ingest/gusto", body)

    assert conn.status == 202, conn.resp_body

    event =
      Repo.get_by(Samen.Ingest.Event,
        provider: "gusto",
        idempotency_key: idempotency_key
      )

    assert event

    # Redaction ran BEFORE persistence: the stored payload is totals/refs only.
    refute inspect(event.payload) =~ @pii_name
    refute inspect(event.payload) =~ @pii_email
    refute Map.has_key?(event.payload["payroll"], "employee_compensations")

    assert :ok =
             Samen.Ingest.Worker.perform(%Oban.Job{
               args: %{"event_id" => event.id, "repo" => "Samenerp.Repo"}
             })

    assert [entry] = entries(org)
    assert entry.source_key == "payroll_register:gusto:#{@payroll_uuid}"
    assert sum(entry.lines, :debit_cents) == @company_debit

    assert Repo.get(Samen.Ingest.Event, event.id).status == "processed"
  end

  # ---------------------------------------------------------------------------
  # Fixtures

  defp payroll(overrides \\ %{}) do
    %{
      "payroll_uuid" => @payroll_uuid,
      "check_date" => "2026-09-30",
      "pay_period" => %{"start_date" => "2026-09-16", "end_date" => "2026-09-30"},
      "totals" => %{
        "company_debit" => "121747.71",
        "net_pay_debit" => "79283.80",
        "tax_debit" => "42463.91",
        "reimbursement_debit" => "0.00",
        "child_support_debit" => "0.00"
      },
      "employee_compensations" => [
        %{
          "employee_name" => @pii_name,
          "email" => @pii_email,
          "ssn" => @pii_ssn,
          "bank_account" => @pii_bank,
          "fixed_compensations" => [%{"name" => "Salary", "amount" => "5000.00"}]
        }
      ]
    }
    |> Map.merge(overrides)
  end

  defp envelope(payroll \\ payroll()) do
    %Samen.Ingest.Contract.Envelope{
      schema_version: 1,
      event_id: "evt_gusto_#{System.unique_integer([:positive])}",
      event_type: "payroll.paid",
      occurred_at: DateTime.utc_now(),
      payload: GustoAdapter.redact_payload(%{"payroll" => payroll}),
      idempotency_key: "idem_gusto_#{System.unique_integer([:positive])}"
    }
  end

  defp account!(scope, org, code, kind, normal_side) do
    Samenerp.Erp.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        code: code,
        name: "Gusto #{code}",
        kind: kind,
        normal_side: normal_side
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp mapping!(scope, org, external_code, account) do
    Samenerp.Erp.PayrollAccountMapping
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        provider: "gusto",
        external_code: external_code,
        account_id: account.id
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp entries(org) do
    Samenerp.Erp.JournalEntry
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.load([:lines])
    |> Ash.read!(authorize?: false)
  end

  defp sum(lines, field) do
    lines
    |> Enum.map(&(Map.get(&1, field) || 0))
    |> Enum.sum()
  end
end
