defmodule Samenerp.KubeworkzBooksWalkthroughTest do
  @moduledoc """
  WS-ACCT Phase 16 — **the whole JE playbook, executed on the Kubeworkz host**
  (build plan Phase 16, item 2).

  `docs/chip_manufacturing_accounting_setup.md` §"Journal Entry Playbook" has
  nine sections and 42 concrete entries from JE-001 through JE-081. This test
  posts every one of them through the mounted `Samenerp.Erp.JournalEntry`, in
  the manual's order, inside one real fiscal period (December 2026), and
  asserts the net-debit balance of every non-zero account after each section.
  It then soft-closes the period and posts the manual's two year-end closing
  entries, proving:

    * the playbook's arithmetic reaches the balances the source entries assert;
    * every posted entry is balanced org-wide, and the final trial balance is
      balanced;
    * JE-080 and JE-081 zero every P&L account and leave the net loss in
      retained earnings;
    * the closing entries are journal-only adjustments, so they are still
      admitted after the period's document window is soft-closed.

  ## The two documented corrections

  The replay follows the books seed's corrected forms, not the manual's
  contradictory rows:

    * **JE-055** uses only the manual's "Corrected Entry" (the original row
      double-credited inventory and put COGS on the debit side).
    * **JE-063** credits `1520 · Accumulated Depreciation – Lab Equipment`, the
      documented correction forced by `Account.code` being unique per org. The
      manual's `1510` is the PDK licence's accumulated amortization.

  The source manual's figures are placeholders (ADR-054 decision 18). Two
  consequences are asserted rather than hidden: JE-004/053 use the manual's
  rounded monthly amounts (1 389 and 833), and JE-062 writes down 1 000.00 of
  SoC inventory after JE-041/JE-055 left only 800.00, so the replay lands the
  source arithmetic's negative 200.00 SoC balance. The host does not invent a
  correction and does not silently cap the write-down.

  ## Scope

  This is the playbook's ledger proof, not a duplicate of the specialised
  machinery suites: accrual pairs, the gated reserve write-down, derived asset
  schedules, grant recognition schedules and the close-run dashboard each have
  their own host tests. Here the manual's entries are posted as written, which
  is exactly what makes the source document's balances checkable end to end.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  @year 2026
  @month 12
  @je_count 42

  @d1 ~D[2026-12-05]
  @d2 ~D[2026-12-06]
  @d3 ~D[2026-12-10]
  @d4 ~D[2026-12-15]
  @d5 ~D[2026-12-18]
  @d6 ~D[2026-12-20]
  @d7 ~D[2026-12-31]

  @expense_codes ~w(6000 6010 6020 6030 6040 7000 8000 5000 5010)
  @revenue_codes ~w(4000 4100)

  setup do
    org = create_org!("Kubeworkz JE Playbook Walkthrough")
    Books.seed!(org.id)
    org_id = to_string(org.id)

    {:ok, org: org, org_id: org_id, admin: admin_scope(org_id)}
  end

  test "JE-001 through JE-081 replay across December, with every section's balances", %{
    org_id: org_id,
    admin: admin
  } do
    period = open_period!(admin, org_id)
    assert period.status == :open

    # ── §1 · R&D ─────────────────────────────────────────────────────────────
    post_je!(org_id, @d1, "JE-001 design engineering labor", [
      {"6020", 8_500_000, 0},
      {"1000", 0, 8_500_000}
    ])

    post_je!(org_id, @d1, "JE-002 EDA software and AI design tools", [
      {"6010", 1_250_000, 0},
      {"2000", 0, 1_250_000}
    ])

    post_je!(org_id, @d1, "JE-003 photonics PDK licence", [
      {"1500", 5_000_000, 0},
      {"1000", 0, 5_000_000}
    ])

    # The manual's rounded monthly slice; the exact 50 000.00 / 36 schedule is
    # the asset-register suite's concern (Phase 8).
    post_je!(org_id, @d7, "JE-004 PDK licence amortization", [
      {"7000", 138_900, 0},
      {"1510", 0, 138_900}
    ])

    post_je!(org_id, @d1, "JE-005 mask and reticle costs", [
      {"6000", 1_500_000, 0},
      {"2000", 0, 1_500_000}
    ])

    post_je!(org_id, @d1, "JE-006 prototype and test engineering", [
      {"6030", 800_000, 0},
      {"1000", 0, 800_000}
    ])

    assert_balances!(org_id, after_section_1())

    # ── §2 · Slot/order prepayments ─────────────────────────────────────────
    post_je!(org_id, @d2, "JE-010 RISC-V64 SoC early-bird slot", [
      {"1200", 200_000, 0},
      {"1000", 0, 200_000}
    ])

    post_je!(org_id, @d2, "JE-011 GPU two-slot purchase", [
      {"1200", 400_000, 0},
      {"1000", 0, 400_000}
    ])

    post_je!(org_id, @d2, "JE-012 PTA photonics MPW slot", [
      {"1210", 3_500_000, 0},
      {"2000", 0, 3_500_000}
    ])

    post_je!(org_id, @d2, "JE-013 chip-on-board packaging add-on", [
      {"1200", 300_000, 0},
      {"1000", 0, 300_000}
    ])

    assert_balances!(org_id, after_section_2())

    # ── §3 · Fabrication ─────────────────────────────────────────────────────
    post_je!(org_id, @d3, "JE-020 RISC-V64 SoC fabrication begins", [
      {"1300", 200_000, 0},
      {"1200", 0, 200_000}
    ])

    post_je!(org_id, @d3, "JE-021 GPU fabrication begins", [
      {"1300", 400_000, 0},
      {"1200", 0, 400_000}
    ])

    post_je!(org_id, @d3, "JE-022 PTA photonics fabrication begins", [
      {"1310", 3_500_000, 0},
      {"1210", 0, 3_500_000}
    ])

    post_je!(org_id, @d3, "JE-023 chip-on-board add-on incurred", [
      {"1300", 300_000, 0},
      {"1200", 0, 300_000}
    ])

    post_je!(org_id, @d3, "JE-024 month-end fabrication accrual", [
      {"1300", 500_000, 0},
      {"2100", 0, 500_000}
    ])

    # The manual's invoice-receipt reversal. The mechanised accrual pair is
    # separately proven by the close walkthrough; this replay follows JE-025.
    post_je!(org_id, @d4, "JE-025 reverse accrual on invoice receipt", [
      {"2100", 500_000, 0},
      {"2000", 0, 500_000}
    ])

    assert_balances!(org_id, after_section_3())

    # ── §4 · Delivery and inventory ──────────────────────────────────────────
    post_je!(org_id, @d4, "JE-030 RISC-V64 SoC dies received", [
      {"1400", 200_000, 0},
      {"1300", 0, 200_000}
    ])

    post_je!(org_id, @d4, "JE-031 GPU dies received", [
      {"1410", 400_000, 0},
      {"1300", 0, 400_000}
    ])

    post_je!(org_id, @d4, "JE-032 PTA photonic chips received", [
      {"1420", 3_500_000, 0},
      {"1310", 0, 3_500_000}
    ])

    post_je!(org_id, @d4, "JE-033 chip-on-board packaging allocated", [
      {"1400", 150_000, 0},
      {"1410", 150_000, 0},
      {"1300", 0, 300_000}
    ])

    post_je!(org_id, @d4, "JE-034 obsolete SoC write-down", [
      {"8000", 50_000, 0},
      {"1400", 0, 50_000}
    ])

    assert_balances!(org_id, after_section_4())

    # ── §5 · PDB assembly ────────────────────────────────────────────────────
    post_je!(org_id, @d5, "JE-040 PCB NRE costs", [
      {"6040", 1_500_000, 0},
      {"2000", 0, 1_500_000}
    ])

    post_je!(org_id, @d5, "JE-041 chip transfer to PDB WIP", [
      {"1320", 4_100_000, 0},
      {"1400", 0, 200_000},
      {"1410", 0, 400_000},
      {"1420", 0, 3_500_000}
    ])

    post_je!(org_id, @d5, "JE-042 PCB and component purchases", [
      {"1320", 2_800_000, 0},
      {"2000", 0, 2_800_000}
    ])

    post_je!(org_id, @d5, "JE-043 assembly labor and overhead", [
      {"1320", 1_200_000, 0},
      {"2000", 0, 1_200_000}
    ])

    post_je!(org_id, @d5, "JE-044 boards complete to finished goods", [
      {"1430", 8_100_000, 0},
      {"1320", 0, 8_100_000}
    ])

    assert_balances!(org_id, after_section_5())

    # ── §6 · Revenue and COGS ────────────────────────────────────────────────
    post_je!(org_id, @d6, "JE-050 university board sale", [
      {"1100", 500_000, 0},
      {"4000", 0, 500_000}
    ])

    post_je!(org_id, @d6, "JE-051 board sale COGS", [
      {"5000", 162_000, 0},
      {"1430", 0, 162_000}
    ])

    post_je!(org_id, @d6, "JE-052 grant-funded board sale deferred", [
      {"1100", 1_000_000, 0},
      {"2200", 0, 1_000_000}
    ])

    post_je!(org_id, @d6, "JE-053 monthly grant support recognition", [
      {"2200", 83_300, 0},
      {"4100", 0, 83_300}
    ])

    post_je!(org_id, @d6, "JE-054 grant-funded board sale COGS", [
      {"5000", 324_000, 0},
      {"1430", 0, 324_000}
    ])

    # JE-055's CORRECTED form only (the manual's original entry is wrong).
    post_je!(org_id, @d6, "JE-055 corrected chip sale", [
      {"1100", 500_000, 0},
      {"4000", 0, 500_000},
      {"5010", 20_000, 0},
      {"1400", 0, 20_000}
    ])

    assert_balances!(org_id, after_section_6())

    # ── §7 · Period-end adjustments ──────────────────────────────────────────
    post_je!(org_id, @d7, "JE-060 accrued foundry costs", [
      {"1300", 350_000, 0},
      {"2100", 0, 350_000}
    ])

    post_je!(org_id, @d7, "JE-061 accrued photonics costs", [
      {"1310", 800_000, 0},
      {"2100", 0, 800_000}
    ])

    # The manual's JE-062 amounts; 1400 had 800.00 left after JE-041/055, so
    # the source's 1 000.00 write-down lands the documented -200.00 balance.
    post_je!(org_id, @d7, "JE-062 obsolete SoC and GPU write-down", [
      {"8000", 250_000, 0},
      {"1400", 0, 100_000},
      {"1410", 0, 150_000}
    ])

    # The 1520 correction: lab equipment has its own accumulated-depreciation
    # contra; 1510 belongs to the PDK licence.
    post_je!(org_id, @d7, "JE-063 lab equipment depreciation", [
      {"6030", 200_000, 0},
      {"1520", 0, 200_000}
    ])

    post_je!(org_id, @d7, "JE-064 accrued vacation and payroll taxes", [
      {"6020", 1_200_000, 0},
      {"2100", 0, 1_200_000}
    ])

    assert_balances!(org_id, after_section_7())

    # ── §8 · Grant accounting ────────────────────────────────────────────────
    fund = cost_object!(org_id, "fund-grants")
    assert fund.kind == :fund
    fund_dims = %{"fund" => fund.id}

    post_je!(
      org_id,
      @d7,
      "JE-070 restricted grant receipt",
      [
        {"1000", 25_000_000, 0},
        {"2200", 0, 25_000_000}
      ],
      dimension_refs: fund_dims
    )

    post_je!(
      org_id,
      @d7,
      "JE-071 grant-funded design labor",
      [
        {"6020", 2_500_000, 0},
        {"1000", 0, 2_500_000}
      ],
      dimension_refs: fund_dims
    )

    post_je!(
      org_id,
      @d7,
      "JE-072 grant revenue recognition",
      [
        {"2200", 2_500_000, 0},
        {"4100", 0, 2_500_000}
      ],
      dimension_refs: fund_dims
    )

    assert_balances!(org_id, after_section_8())

    # ── §9 · Year-end close ──────────────────────────────────────────────────
    # Close the DOCUMENT window, not the ledger's adjustment window. The two
    # closing entries below are journal-only (no source document), so they must
    # still land in this period.
    period = soft_close!(period, admin)
    assert period.status == :soft_closed

    before_close = balances!(org_id)

    expense_total =
      @expense_codes
      |> Enum.map(&Map.fetch!(before_close, &1))
      |> Enum.sum()

    assert expense_total == 18_394_900

    revenue_total =
      @revenue_codes
      |> Enum.map(&Map.fetch!(before_close, &1))
      |> Enum.map(&abs/1)
      |> Enum.sum()

    assert revenue_total == 3_583_300

    post_je!(org_id, @d7, "JE-080 close expense and COGS accounts", [
      {"3100", expense_total, 0}
      | Enum.map(@expense_codes, &{&1, 0, Map.fetch!(before_close, &1)})
    ])

    post_je!(org_id, @d7, "JE-081 close revenue accounts", [
      {"4000", 1_000_000, 0},
      {"4100", 2_583_300, 0},
      {"3100", 0, revenue_total}
    ])

    assert_balances!(org_id, after_close())

    balances = balances!(org_id)

    # The total includes the credit-side contra balances and the source's
    # negative 200.00 SoC inventory, so it is larger than net assets alone.
    assert balances |> Map.values() |> Enum.filter(&(&1 > 0)) |> Enum.sum() == 38_375_600

    assert balances |> Map.values() |> Enum.filter(&(&1 < 0)) |> Enum.map(&abs/1) |> Enum.sum() ==
             38_375_600

    assert posted_entry_count(org_id) == @je_count
    assert closed_period!(org_id).status == :soft_closed
  end

  # ── the period ─────────────────────────────────────────────────────────────

  defp open_period!(admin, org_id) do
    Erp.FiscalPeriod
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, year: @year, month: @month},
      scope: admin
    )
    |> Ash.create!()
  end

  defp soft_close!(period, admin) do
    period
    |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin)
    |> Ash.update!()
  end

  defp closed_period!(org_id) do
    Erp.FiscalPeriod
    |> Ash.Query.filter(org_id == ^org_id and year == ^@year and month == ^@month)
    |> Ash.read_one!(authorize?: false)
  end

  # ── ledger helpers ─────────────────────────────────────────────────────────

  defp post_je!(org_id, date, memo, lines, opts \\ []) do
    dimension_refs = Keyword.get(opts, :dimension_refs)

    lines =
      Enum.map(lines, fn {code, debit_cents, credit_cents} ->
        line = %{
          account_id: account_id!(org_id, code),
          debit_cents: debit_cents,
          credit_cents: credit_cents
        }

        if is_nil(dimension_refs) do
          line
        else
          Map.put(line, :dimension_refs, dimension_refs)
        end
      end)

    assert Enum.sum(Enum.map(lines, & &1.debit_cents)) ==
             Enum.sum(Enum.map(lines, & &1.credit_cents))

    entry =
      Erp.JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          entry_date: date,
          memo: memo,
          lines: lines
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert entry.status == :draft

    posted =
      entry
      |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

    assert posted.status == :posted
    posted
  end

  defp balances!(org_id) do
    accounts =
      Erp.Account
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)

    entries =
      Erp.JournalEntry
      |> Ash.Query.filter(org_id == ^org_id and status == :posted)
      |> Ash.read!(authorize?: false)

    entry_ids = Enum.map(entries, & &1.id)

    lines =
      Erp.JournalLine
      |> Ash.Query.filter(entry_id in ^entry_ids)
      |> Ash.read!(authorize?: false)

    account_codes = Map.new(accounts, &{&1.id, &1.code})

    balances =
      Enum.reduce(lines, Map.new(accounts, &{&1.code, 0}), fn line, acc ->
        code = Map.fetch!(account_codes, line.account_id)
        Map.update!(acc, code, &(&1 + line.debit_cents - line.credit_cents))
      end)

    total = balances |> Map.values() |> Enum.sum()
    assert total == 0, "posted journal lines do not balance: #{total}"

    balances
  end

  defp assert_balances!(org_id, expected) do
    actual =
      org_id
      |> balances!()
      |> Enum.reject(fn {_code, balance} -> balance == 0 end)
      |> Map.new()

    assert actual == expected
  end

  defp posted_entry_count(org_id) do
    Erp.JournalEntry
    |> Ash.Query.filter(org_id == ^org_id and status == :posted)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  # ── the manual's running balances, in signed cents ─────────────────────────
  #
  # Positive is a net DEBIT, negative a net CREDIT. Zero accounts are omitted.

  defp after_section_1 do
    %{
      "1000" => -14_300_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "2000" => -2_750_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 8_500_000,
      "6030" => 800_000,
      "7000" => 138_900
    }
  end

  defp after_section_2 do
    %{
      "1000" => -15_200_000,
      "1200" => 900_000,
      "1210" => 3_500_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "2000" => -6_250_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 8_500_000,
      "6030" => 800_000,
      "7000" => 138_900
    }
  end

  defp after_section_3 do
    %{
      "1000" => -15_200_000,
      "1300" => 1_400_000,
      "1310" => 3_500_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "2000" => -6_750_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 8_500_000,
      "6030" => 800_000,
      "7000" => 138_900
    }
  end

  defp after_section_4 do
    %{
      "1000" => -15_200_000,
      "1300" => 500_000,
      "1400" => 300_000,
      "1410" => 550_000,
      "1420" => 3_500_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "2000" => -6_750_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 8_500_000,
      "6030" => 800_000,
      "7000" => 138_900,
      "8000" => 50_000
    }
  end

  defp after_section_5 do
    %{
      "1000" => -15_200_000,
      "1300" => 500_000,
      "1400" => 100_000,
      "1410" => 150_000,
      "1430" => 8_100_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "2000" => -12_250_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 8_500_000,
      "6030" => 800_000,
      "6040" => 1_500_000,
      "7000" => 138_900,
      "8000" => 50_000
    }
  end

  defp after_section_6 do
    %{
      "1000" => -15_200_000,
      "1100" => 2_000_000,
      "1300" => 500_000,
      "1400" => 80_000,
      "1410" => 150_000,
      "1430" => 7_614_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "2000" => -12_250_000,
      "2200" => -916_700,
      "4000" => -1_000_000,
      "4100" => -83_300,
      "5000" => 486_000,
      "5010" => 20_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 8_500_000,
      "6030" => 800_000,
      "6040" => 1_500_000,
      "7000" => 138_900,
      "8000" => 50_000
    }
  end

  defp after_section_7 do
    %{
      "1000" => -15_200_000,
      "1100" => 2_000_000,
      "1300" => 850_000,
      "1310" => 800_000,
      "1400" => -20_000,
      "1430" => 7_614_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "1520" => -200_000,
      "2000" => -12_250_000,
      "2100" => -2_350_000,
      "2200" => -916_700,
      "4000" => -1_000_000,
      "4100" => -83_300,
      "5000" => 486_000,
      "5010" => 20_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 9_700_000,
      "6030" => 1_000_000,
      "6040" => 1_500_000,
      "7000" => 138_900,
      "8000" => 300_000
    }
  end

  defp after_section_8 do
    %{
      "1000" => 7_300_000,
      "1100" => 2_000_000,
      "1300" => 850_000,
      "1310" => 800_000,
      "1400" => -20_000,
      "1430" => 7_614_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "1520" => -200_000,
      "2000" => -12_250_000,
      "2100" => -2_350_000,
      "2200" => -23_416_700,
      "4000" => -1_000_000,
      "4100" => -2_583_300,
      "5000" => 486_000,
      "5010" => 20_000,
      "6000" => 1_500_000,
      "6010" => 1_250_000,
      "6020" => 12_200_000,
      "6030" => 1_000_000,
      "6040" => 1_500_000,
      "7000" => 138_900,
      "8000" => 300_000
    }
  end

  defp after_close do
    %{
      "1000" => 7_300_000,
      "1100" => 2_000_000,
      "1300" => 850_000,
      "1310" => 800_000,
      "1400" => -20_000,
      "1430" => 7_614_000,
      "1500" => 5_000_000,
      "1510" => -138_900,
      "1520" => -200_000,
      "2000" => -12_250_000,
      "2100" => -2_350_000,
      "2200" => -23_416_700,
      "3100" => 14_811_600
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "a:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp account_id!(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:id)
  end

  defp cost_object!(org_id, code) do
    Erp.CostObject
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end
end
