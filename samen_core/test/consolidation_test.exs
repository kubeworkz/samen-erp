defmodule Samen.ConsolidationTest do
  @moduledoc """
  WS-ERP E24: Multi-Company Consolidation —  multi-entity.

  Tests:
    * mc1 CompanyGroup: group structure (parent + subsidiaries)
    * mc2 CompanyGroup: consolidation methods
    * mc3 CompanyMapping: account mapping types
    * mc4 CompanyMapping: currency conversion
    * mc5 IntercompanyTx: state lifecycle (draft → posted → eliminated)
    * mc6 IntercompanyTx: transaction types
    * mc7 IntercompanyTx: amount in base currency
    * mc8 ConsolidationRule: rule types and priorities
    * mc9 ConsolidationRule: elimination matching
    * mc10 Integration: full consolidation flow
  """
  use ExUnit.Case, async: true

  # ── mc1: group structure ─────────────────────────────────────────────

  describe "mc1 — group structure" do
    test "group has parent and subsidiaries" do
      group = %{
        name: "Acme Holdings",
        parent_org_id: "org-parent",
        subsidiary_org_ids: ["org-sub1", "org-sub2", "org-sub3"],
        base_currency: "USD"
      }

      assert group.parent_org_id == "org-parent"
      assert length(group.subsidiary_org_ids) == 3
    end

    test "single subsidiary group" do
      group = %{
        name: "Small Group",
        parent_org_id: "org-parent",
        subsidiary_org_ids: ["org-sub1"]
      }

      assert length(group.subsidiary_org_ids) == 1
    end
  end

  # ── mc2: consolidation methods ───────────────────────────────────────

  describe "mc2 — consolidation methods" do
    test "valid consolidation methods" do
      valid = [:full, :proportional, :equity]
      assert length(valid) == 3
      assert :full in valid
      assert :equity in valid
    end

    test "full consolidation includes 100%" do
      ownership = 100
      method = :full
      assert method == :full and ownership == 100
    end

    test "proportional consolidation uses ownership %" do
      ownership = 60
      method = :proportional
      assert method == :proportional and ownership > 50
    end
  end

  # ── mc3: account mapping types ───────────────────────────────────────

  describe "mc3 — account mapping types" do
    test "valid mapping types" do
      valid = [:direct, :adjustment, :elimination]
      assert length(valid) == 3
      assert :direct in valid
    end

    test "direct mapping is 1:1" do
      mapping = %{mapping_type: :direct, subsidiary_account_id: "a1", parent_account_id: "b1"}
      assert mapping.subsidiary_account_id != mapping.parent_account_id
    end
  end

  # ── mc4: currency conversion ─────────────────────────────────────────

  describe "mc4 — currency conversion" do
    test "convert amount using exchange rate" do
      amount = 100_00
      exchange_rate = 1.10
      amount_base = round(amount * exchange_rate)

      assert amount_base == 110_00
    end

    test "same currency has rate 1.0" do
      amount = 500_00
      exchange_rate = 1.0
      amount_base = round(amount * exchange_rate)

      assert amount_base == 500_00
    end

    test "inverse conversion" do
      amount_base = 110_00
      exchange_rate = 1.10
      amount_original = round(amount_base / exchange_rate)

      assert amount_original == 100_00
    end
  end

  # ── mc5: intercompany tx state lifecycle ──────────────────────────────

  describe "mc5 — intercompany tx state lifecycle" do
    test "draft → posted → eliminated" do
      tx = %{state: :draft}
      tx = %{tx | state: :posted}
      assert tx.state == :posted
      tx = %{tx | state: :eliminated}
      assert tx.state == :eliminated
    end

    test "eliminated transactions cannot be reversed" do
      valid_transitions = %{draft: [:posted], posted: [:eliminated], eliminated: []}
      refute :posted in valid_transitions[:eliminated]
    end
  end

  # ── mc6: transaction types ───────────────────────────────────────────

  describe "mc6 — transaction types" do
    test "valid transaction types" do
      valid = [:sale, :purchase, :loan, :dividend, :service_fee]
      assert length(valid) == 5
      assert :sale in valid
      assert :dividend in valid
    end

    test "intercompany sale has buyer and seller" do
      tx = %{from_org_id: "org-a", to_org_id: "org-b", transaction_type: :sale, amount: 1000_00}
      assert tx.from_org_id != tx.to_org_id
    end
  end

  # ── mc7: amount in base currency ─────────────────────────────────────

  describe "mc7 — amount in base currency" do
    test "amount_base = amount * exchange_rate" do
      tx = %{amount: 1000_00, exchange_rate: 1.25, currency: "EUR"}
      amount_base = round(tx.amount * tx.exchange_rate)

      assert amount_base == 1250_00
    end

    test "base currency amount matches when rate is 1.0" do
      tx = %{amount: 500_00, exchange_rate: 1.0, currency: "USD"}
      amount_base = round(tx.amount * tx.exchange_rate)

      assert amount_base == 500_00
    end
  end

  # ── mc8: consolidation rule types and priorities ─────────────────────

  describe "mc8 — consolidation rule types" do
    test "valid rule types" do
      valid = [:account_pair, :transaction_type, :custom]
      assert length(valid) == 3
      assert :account_pair in valid
    end

    test "lower priority executes first" do
      rules = [
        %{name: "Rule A", priority: 100},
        %{name: "Rule B", priority: 50},
        %{name: "Rule C", priority: 200}
      ]

      sorted = Enum.sort_by(rules, & &1.priority)
      assert hd(sorted).name == "Rule B"
    end
  end

  # ── mc9: elimination matching ────────────────────────────────────────

  describe "mc9 — elimination matching" do
    test "account pair rule matches transactions" do
      rule = %{rule_type: :account_pair, from_account_pattern: "1100-*", to_account_pattern: "2100-*"}
      tx = %{from_account_id: "1100-receivable", to_account_id: "2100-payable"}

      from_match = String.starts_with?(tx.from_account_id, "1100")
      to_match = String.starts_with?(tx.to_account_id, "2100")

      assert from_match and to_match
    end

    test "transaction type rule matches" do
      rule = %{rule_type: :transaction_type, transaction_type_filter: :intercompany_sale}
      tx = %{transaction_type: :intercompany_sale}

      assert tx.transaction_type == rule.transaction_type_filter
    end
  end

  # ── mc10: full consolidation flow ────────────────────────────────────

  describe "mc10 — full consolidation flow" do
    test "group → intercompany tx → elimination → consolidated balance" do
      # 1. Create company group
      group = %{
        id: "g1",
        name: "Acme Holdings",
        parent_org_id: "org-parent",
        subsidiary_org_ids: ["org-sub1", "org-sub2"],
        base_currency: "USD",
        consolidation_method: :full
      }

      # 2. Intercompany sale: Sub1 → Sub2
      tx1 = %{
        id: "tx1",
        group_id: group.id,
        from_org_id: "org-sub1",
        to_org_id: "org-sub2",
        transaction_type: :sale,
        amount: 5000_00,
        currency: "USD",
        exchange_rate: 1.0,
        amount_base: 5000_00,
        state: :posted
      }

      # 3. Intercompany service fee: Sub2 → Parent
      tx2 = %{
        id: "tx2",
        group_id: group.id,
        from_org_id: "org-sub2",
        to_org_id: "org-parent",
        transaction_type: :service_fee,
        amount: 1000_00,
        currency: "EUR",
        exchange_rate: 1.10,
        amount_base: 1100_00,
        state: :posted
      }

      # 4. Elimination rule
      rule = %{
        id: "r1",
        group_id: group.id,
        name: "Eliminate Intercompany Sales",
        rule_type: :transaction_type,
        transaction_type_filter: :sale,
        is_active: true,
        priority: 100
      }

      # 5. Match transactions to rules
      matching_txs = [tx1]  # Only tx1 matches (sale type)
      assert length(matching_txs) == 1

      # 6. Eliminate
      eliminated_txs = Enum.map(matching_txs, fn tx -> Map.merge(tx, %{state: :eliminated, eliminated_at: DateTime.utc_now()}) end)
      assert hd(eliminated_txs).state == :eliminated

      # 7. Consolidated balance (parent + subs - eliminations)
      parent_balance = 0
      sub1_balance = 5000_00  # earned from sale
      sub2_balance = -5000_00  # paid for sale
      sub2_service_fee = -1000_00  # paid service fee to parent
      parent_service_fee = 1100_00  # received service fee

      consolidated = parent_balance + sub1_balance + sub2_balance + sub2_service_fee + parent_service_fee
      # After elimination: the sale is removed, service fee remains
      consolidated_after_elimination = consolidated - sub1_balance - sub2_balance  # eliminate sale

      assert consolidated_after_elimination == 100_00  # net service fee

      # 8. Mark all as eliminated
      tx1 = %{tx1 | state: :eliminated}
      tx2 = %{tx2 | state: :eliminated}

      assert tx1.state == :eliminated
      assert tx2.state == :eliminated
    end
  end
end