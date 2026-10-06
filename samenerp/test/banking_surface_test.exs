defmodule Samenerp.BankingSurfaceTest do
  @moduledoc """
  The BANKING surfaces on THIS host — dead renders through the real router, no
  mount constructed here (the same discipline as `Samenerp.CrmContactDetailTest`).

  Why this belongs in the host suite: the banking tables (`bka/bkl/bki/bkm/bkr`,
  migration `20260918010000`) were live in prod with NO mounted scope and NO route
  — the E9 orphan. This guard proves the mount actually surfaces them:

    * `/banking` — 200 + the honest empty state (no fabricated rows);
    * `/banking/rules` — 200 + its empty state;
    * `/banking/accounts/:id` — a seeded account's facts + its statement-line
      ledger + the MATCH affordance on an unmatched line;
    * an unknown id — the honest "Bank account not found." (200, never a 500);
    * the framework sidebars render the Banking/Work nav groups ONLY because
      this router sets the `banking_path`/`work_path` labels (the X1 presence
      seams — a host that never mounts these routes never sets them).

  NON-PII throughout (the Banking PII map is EMPTY, INV-1), so there is no
  masking trio here; `mix samen.verify.pii_classify` is the leak backstop.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Banking
  alias Samenerp.Erp.Account
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  setup do
    # ExUnit-owned endpoint lifecycle (same owner as CrmContactDetailTest).
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp seed_gl_account(org_id) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, code: "1010", name: "Cash", kind: :asset, normal_side: :debit},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp seed_bank_account(org_id, gl_id) do
    Banking.BankAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "Ops Checking", account_id: gl_id, currency: "USD"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # StatementLine ships NO create action (imports are the declared-not-built
  # route), so the fixture arranges the row directly — arrange-raw / act-governed.
  defp seed_line(org_id, bank_account_id, description, amount_cents) do
    %{rows: [[id]]} =
      Samenerp.Repo.query!(
        """
        INSERT INTO bkl_statement_line
          (bkl_bank_account_id, bkl_posted_at, bkl_amount_cents, bkl_description,
           bkl_import_hash, bkl_id, bkl_org_id, bkl_inserted_at, bkl_updated_at)
        VALUES ($1, $2, $3, $4, $5, gen_random_uuid(), $6, NOW(), NOW())
        RETURNING bkl_id
        """,
        [
          Ecto.UUID.dump!(bank_account_id),
          DateTime.utc_now() |> DateTime.truncate(:second),
          amount_cents,
          description,
          "fixture-#{System.unique_integer([:positive])}",
          Ecto.UUID.dump!(org_id)
        ]
      )

    Ecto.UUID.load!(id)
  end

  test "the banking list + rules pages render with honest empty states" do
    tenant = create_org!("Banking Surface QA")

    list = get(build_conn(), "/banking?org=#{tenant.id}")
    assert list.status == 200,
           "the /banking accounts page did not render — the E9 mount route is missing or crashing"

    assert list.resp_body =~ "No bank accounts yet.",
           "the empty state did not render (a list page must never fabricate rows)"

    rules = get(build_conn(), "/banking/rules?org=#{tenant.id}")
    assert rules.status == 200
    assert rules.resp_body =~ "No rules yet."
  end

  test "the account detail renders facts, the statement ledger, and the match affordance" do
    tenant = create_org!("Banking Detail QA")
    gl = seed_gl_account(tenant.id)
    account = seed_bank_account(tenant.id, gl.id)
    seed_line(tenant.id, account.id, "AWS HOSTED SERVICES", -5_000)

    detail = get(build_conn(), "/banking/accounts/#{account.id}?org=#{tenant.id}")

    assert detail.status == 200,
           "the bank account detail page did not render (the E9 detail route is missing or crashing)"

    body = detail.resp_body
    assert body =~ "Ops Checking", "the account name did not render"
    refute body =~ "Bank account not found."
    assert body =~ "AWS HOSTED SERVICES", "the seeded statement line did not render"
    assert body =~ "Statement lines"
    # The governed match affordance is offered on an unmatched line. (The id is
    # `match-<line uuid>`, so the literal must end at the dash — a closing quote
    # would only match a hypothetical id of exactly "match-".)
    assert body =~ ~s(id="match-), "the match affordance is missing on an unmatched line"

    # The list page carries the create affordance + the seeded row links back.
    list = get(build_conn(), "/banking?org=#{tenant.id}")
    assert list.resp_body =~ ~s(id="new-account")
    assert list.resp_body =~ "Ops Checking"
  end

  test "an unknown bank account renders the honest not-found state, never a 500" do
    tenant = create_org!("Banking Missing QA")

    detail =
      get(build_conn(), "/banking/accounts/#{Ecto.UUID.generate()}?org=#{tenant.id}")

    assert detail.status == 200,
           "an unknown bank account 500ed — the detail page must render its honest not-found state"

    assert detail.resp_body =~ "Bank account not found."
  end

  test "the framework sidebars render the Banking and Work nav groups on this host" do
    tenant = create_org!("Banking Nav QA")

    body = get(build_conn(), "/crm/dashboard?org=#{tenant.id}").resp_body

    # Presence IS the X1 guard: these links exist only because this router sets
    # the banking_path/work_path labels alongside its route macros.
    assert body =~ "/banking?org=#{tenant.id}",
           "the Banking nav group did not render on a sidebar of a host that mounts /banking"

    assert body =~ "/banking/rules?org=#{tenant.id}",
           "the Banking > Rules nav item did not render"

    assert body =~ "/work?org=#{tenant.id}",
           "the Work nav group did not render on a sidebar of a host that mounts /work"

    assert body =~ "/work/projects?org=#{tenant.id}",
           "the Work > Projects nav item did not render"
  end
end
