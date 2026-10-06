defmodule Samenerp.BankingMatchGuardTest do
  @moduledoc """
  The Banking MATCH guard red paths, run against the REAL mounted schema
  (`bkl_statement_line`, `bkm_match`, `ecj_journal_entry`) on this host — the
  integration proof `samen_core/test/banking_scope_test.exs`'s placeholders
  ("assert 1 == 1 — Placeholder for integration test with real DB") never were.

  Every red path pairs denial with a positive control (anti-tautology):

    * b3 amount-strict — mismatched cash leg REFUSED / exact match LANDED.
      (The original guard summed Σ debit−credit over the WHOLE balanced entry —
      always 0 — through raw SQL against `<abbrev>_`-prefixed columns, so every
      query errored into `0 == 0`: a guard that could never fail. It now checks
      the entry's cash-ACCOUNT leg via Ash reads.)
    * b4 double-match — a second match for the same line REFUSED / the first
      LANDED (brace: the `Match` row exists check; belt: the unique index).
    * b5 voided entry — REFUSED / a non-voided entry LANDED.
    * b6 cross-org FK — a match may not link another org's line (SameOrgFk) /
      same-org LANDED (b3's control).
    * b7 org-scoped READ — a foreign org's statement line is invisible /
      own-org row visible (OrgScope).
  """

  use Samenerp.DataCase, async: false

  alias Samenerp.Banking
  alias Samenerp.Erp.{Account, JournalEntry}

  setup do
    org = Ecto.UUID.generate()
    other_org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }

    {:ok, org: org, other_org: other_org, scope: scope}
  end

  defp seed_gl_account(org_id, code) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, code: code, name: "Account #{code}", kind: :asset, normal_side: :debit},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp seed_bank_account(org_id, gl_id) do
    Banking.BankAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: "Guard Testing", account_id: gl_id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # A balanced entry whose CASH leg equals `-abs(cents)` (money out) or `+cents`
  # (money in): cash is credited on the way out, debited on the way in.
  defp seed_entry(scope, org, cash_id, expense_id, cents, opts \\ []) do
    abs_cents = abs(cents)

    {cash_line, other_line} =
      if cents < 0 do
        {%{account_id: cash_id, debit_cents: 0, credit_cents: abs_cents},
         %{account_id: expense_id, debit_cents: abs_cents, credit_cents: 0}}
      else
        {%{account_id: cash_id, debit_cents: cents, credit_cents: 0},
         %{account_id: expense_id, debit_cents: 0, credit_cents: cents}}
      end

    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: ~D[2026-10-01],
          memo: Keyword.get(opts, :memo, "Guard fixture"),
          lines: [other_line, cash_line]
        },
        authorize?: false
      )
      |> Ash.create!(scope: scope, authorize?: true)

    if Keyword.get(opts, :void?, false) do
      # The SANCTIONED void path (E1/ADR-049): `:void` runs only on a `:posted`
      # row (one-way state machine), so post first — the same Ash route
      # finance_scope_test exercises. Raw SQL here would hit PostGuard.
      entry
      |> Ash.Changeset.for_update(:post, %{}, scope: scope)
      |> Ash.update!(scope: scope)
      |> Ash.Changeset.for_update(:void, %{}, scope: scope)
      |> Ash.update!(scope: scope)
    else
      entry
    end
  end

  # StatementLine ships NO create action (imports are the declared-not-built
  # route): arrange the row directly, act through the governed `:create_match`.
  defp seed_line(org, bank_account_id, amount_cents) do
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
          "GUARD FIXTURE",
          "guard-#{System.unique_integer([:positive])}",
          Ecto.UUID.dump!(org)
        ]
      )

    Ecto.UUID.load!(id)
  end

  defp attempt_match(scope, line_id, entry) do
    entry_id = if is_struct(entry), do: entry.id, else: entry

    Banking.Match
    |> Ash.Changeset.for_create(
      :create_match,
      %{
        statement_line_id: line_id,
        entry_id: entry_id,
        org_id: scope.actor.org_id
      },
      authorize?: false
    )
    |> Ash.create(scope: scope, authorize?: true)
  end

  defp err_text(result) do
    case result do
      {:error, err} -> inspect(err)
      other -> inspect(other)
    end
  end

  test "b3/b6 — amount-strict match: exact cash leg LANDS, mismatch and cross-org REFUSED",
       %{org: org, other_org: other_org, scope: scope} do
    cash = seed_gl_account(org, "1010")
    expense = seed_gl_account(org, "6200")
    bank = seed_bank_account(org, cash.id)

    # CONTROL: line −$50.00, entry credits cash $50.00 → leg −5000 → LANDS.
    line = seed_line(org, bank.id, -5_000)
    entry = seed_entry(scope, org, cash.id, expense.id, -5_000)

    assert {:ok, match} = attempt_match(scope, line, entry),
           "an exact cash-leg match was REFUSED: " <>
             err_text(attempt_match(scope, line, entry))

    assert match.statement_line_id == line

    # BOUNDARY: a line exactly 1¢ off sits INSIDE the guard's documented ±1¢
    # tolerance (multi-currency rounding — Match moduledoc) → allowed by design.
    # Pinning it here so a future tightening/loosening is a deliberate act.
    within_line = seed_line(org, bank.id, -4_999)
    assert {:ok, _} = attempt_match(scope, within_line, entry),
           "a match within the documented ±1¢ tolerance was refused: " <>
             err_text(attempt_match(scope, within_line, entry))

    # RED (amount): a $49.80 line against the same $50.00 leg — 20¢ beyond the
    # tolerance → refused.
    short_line = seed_line(org, bank.id, -4_980)
    assert {:error, e1} = attempt_match(scope, short_line, entry)
    assert err_text({:error, e1}) =~ "Amount mismatch",
           "the amount guard did not refuse a mismatched match: " <> err_text({:error, e1})

    # RED (amount, other direction): a money-IN line against a money-OUT leg.
    in_line = seed_line(org, bank.id, 5_000)
    assert {:error, e2} = attempt_match(scope, in_line, entry)
    assert err_text({:error, e2}) =~ "Amount mismatch"

    # RED (b6 SameOrgFk): another org's statement line may never be linked.
    foreign_line = seed_line(other_org, bank.id, -5_000)
    assert {:error, e3} = attempt_match(scope, foreign_line, entry)
    assert err_text({:error, e3}) =~ "org",
           "the cross-org match was not refused by the same-org FK guard: " <>
             err_text({:error, e3})
  end

  test "b4 — a statement line cannot be matched twice", %{
    org: org,
    scope: scope
  } do
    cash = seed_gl_account(org, "1010")
    expense = seed_gl_account(org, "6200")
    bank = seed_bank_account(org, cash.id)

    line = seed_line(org, bank.id, -2_500)
    entry = seed_entry(scope, org, cash.id, expense.id, -2_500)

    # CONTROL: the first match lands.
    assert {:ok, _} = attempt_match(scope, line, entry)

    # RED: a second match for the same line — refused by the guard's existing-
    # Match check (brace) before the unique index (belt) would fire.
    assert {:error, e} = attempt_match(scope, line, entry)
    assert err_text({:error, e}) =~ "already",
           "the double-match refusal did not surface an honest already-matched error: " <>
             err_text({:error, e})
  end

  test "b5 — a voided journal entry cannot be matched", %{org: org, scope: scope} do
    cash = seed_gl_account(org, "1010")
    expense = seed_gl_account(org, "6200")
    bank = seed_bank_account(org, cash.id)

    line = seed_line(org, bank.id, -7_500)

    voided = seed_entry(scope, org, cash.id, expense.id, -7_500, void?: true)
    assert {:error, e} = attempt_match(scope, line, voided)
    assert err_text({:error, e}) =~ "voided",
           "the voided-entry refusal did not surface: " <> err_text({:error, e})

    # CONTROL: the same line against a NON-voided entry lands.
    live = seed_entry(scope, org, cash.id, expense.id, -7_500, memo: "live leg")
    assert {:ok, _} = attempt_match(scope, line, live)
  end

  test "b7 — statement lines are org-scoped on read", %{
    org: org,
    other_org: other_org
  } do
    cash = seed_gl_account(org, "1010")
    bank = seed_bank_account(org, cash.id)

    mine = seed_line(org, bank.id, -1_000)
    seed_line(other_org, bank.id, -9_999)

    read_scope = fn o ->
      %Samen.Scope{
        actor: %{id: "u:#{o}", org_id: o, role: :member, kind: :tenant, plane: :tenant}
      }
    end

    visible =
      Banking.StatementLine
      |> Ash.read!(scope: read_scope.(org), authorize?: true)
      |> Enum.map(& &1.id)

    assert mine in visible, "the org's OWN statement line was invisible (positive control failed)"

    hidden =
      Banking.StatementLine
      |> Ash.read!(scope: read_scope.(other_org), authorize?: true)
      |> Enum.map(& &1.id)

    refute mine in hidden,
           "a foreign org's statement line leaked through OrgScope"

  end
end
