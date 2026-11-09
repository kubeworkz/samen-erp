defmodule Samenerp.BankingSuggestionsTest do
  @moduledoc """
  The account screen's import affordance and ranked suggestions, rendered through
  the real host router after a governed import and a posted journal entry.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Samen.Scopes.Banking.Import
  alias Samenerp.Banking
  alias Samenerp.Erp.{Account, JournalEntry}
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp tenant_scope(org) do
    %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp seed_gl_account(org_id, code, name) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, code: code, name: name, kind: :asset, normal_side: :debit},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp seed_bank_account(org_id, gl_id) do
    Banking.BankAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "Suggestion Checking", account_id: gl_id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp seed_posted_entry(org, scope, cash_id, expense_id) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: ~D[2026-10-01],
          memo: "Coffee Shop",
          lines: [
            %{account_id: expense_id, debit_cents: 5_000, credit_cents: 0},
            %{account_id: cash_id, debit_cents: 0, credit_cents: 5_000}
          ]
        },
        authorize?: false
      )
      |> Ash.create!(scope: scope, authorize?: true)

    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!(scope: scope)
  end

  test "the account screen exposes import and ranked suggestions that prefill the match form" do
    org = create_org!("Banking Suggestions QA")
    scope = tenant_scope(org.id)
    cash = seed_gl_account(org.id, "1010", "Cash")
    expense = seed_gl_account(org.id, "6200", "Office expense")
    bank = seed_bank_account(org.id, cash.id)

    seed_posted_entry(org.id, scope, cash.id, expense.id)

    csv = "Date,Amount,Description\n2026-10-01,-50.00,Coffee Shop\n"

    assert {:ok, _} =
             Import.import(csv,
               line_resource: Banking.StatementLine,
               import_resource: Banking.StatementImport,
               repo: Samenerp.Repo,
               scope: scope,
               org_id: org.id,
               bank_account_id: bank.id,
               filename: "suggestions.csv"
             )

    body = get(build_conn(), "/banking/accounts/#{bank.id}?org=#{org.id}").resp_body

    assert body =~ ~s(id="statement-import-form"),
           "the account screen does not expose the statement import form"

    assert body =~ ~s(id="suggestions-),
           "the account screen did not render a ranked suggestion for the imported line"

    assert body =~ "Coffee Shop"
    assert body =~ "Exact amount match on same date"
    assert body =~ "Use suggestion"
    assert body =~ "100%"
  end

  test "pasted CSV import and suggestion prefill work over the LiveView connection" do
    org = create_org!("Banking Live Suggestions QA")
    scope = tenant_scope(org.id)
    cash = seed_gl_account(org.id, "1010", "Cash")
    expense = seed_gl_account(org.id, "6200", "Office expense")
    bank = seed_bank_account(org.id, cash.id)

    entry = seed_posted_entry(org.id, scope, cash.id, expense.id)
    csv = "Date,Amount,Description\n2026-10-01,-50.00,Coffee Shop\n"

    {:ok, view, html} = live(build_conn(), "/banking/accounts/#{bank.id}?org=#{org.id}")

    assert html =~ ~s(id="statement-import-form")
    assert html =~ "No statement lines yet."

    html =
      view
      |> element("#statement-import-form")
      |> render_submit(%{"import_text" => csv})

    assert html =~ "Imported 1 statement line."
    assert html =~ "Suggested matches"
    assert html =~ "Exact amount match on same date"

    line = Banking.StatementLine |> Ash.read!(scope: scope) |> List.first()
    assert line

    html =
      view
      |> element("#suggestions-#{line.id} button", "Use suggestion")
      |> render_click()

    assert html =~ "Match this statement line to a journal entry"
    assert html =~ entry.id
    assert html =~ "selected"
  end
end
