defmodule Samenerp.Kubeworkz.Books do
  @moduledoc """
  Opens the **Kubeworkz** set of accounting books on this host — WS-ACCT Phase 2
  (ADR-054 D2/D15/D16).

  This is a **seed, not a feature** (design §0.3): everything here is host DATA
  written through the mounted `Samenerp.Erp` resources, so the chart of accounts,
  the posting map, the cost objects and the budget are ordinary org-scoped rows
  an operator can still edit in the UI. Nothing in `samen_core` changes.

  ## What opens

    * **The chart of accounts** — the manual's `Chart of Accounts Reference`
      table (`1000`…`8000`), plus the **variance family** (`5100`…`5190`) its
      Variance Playbook posts to. Transcribed from the manual's *corrected*
      forms (design D16): where the manual carries two conflicting COAs, the
      reference table wins, because that is the table every JE in the playbook
      posts against. The manual's earlier summary numbers `1200`/`1210` as WIP
      and `1230` as finished goods; the reference table — and therefore this
      seed — uses `1200`/`1210` for **prepaid** foundry/photonics and
      `1300`/`1310`/`1320` for WIP.

    * **Two documented corrections** to the manual, both forced by `Account.code`
      being unique per org:

      | # | The manual | The books | Why |
      |---|---|---|---|
      | `1520` | reuses `1510 · Accumulated Depreciation – Lab Equipment` (JE-063) | `1510` stays *Accumulated Amortization – PDK License*; equipment gets `1520` | one code cannot name two accounts; the reference table's heading names `1510` as the PDK contra |

      `1520` is the only correction to an existing code. The lifecycle
      extension adds three additive host accounts the reference table does not
      name separately: `1530 Lab Equipment` (the PDK licence keeps `1500`),
      `1540 Construction in Progress`, and `7920 Gain/Loss on Asset Disposal`.

    * **The posting map** — one `PostingAccount` row per meaning the manual
      actually gives an account for (see `pending_meanings/0` for the ones it
      does not, and why they stay unmapped). The lifecycle meanings bind
      `asset_cost_intangible` → `1500`, `asset_cost_equipment` → `1530`,
      `construction_in_progress` → `1540`, and `disposal_gain_loss` → `7920`.

    * **The cost objects** — the manual's four programmes (RISC-V64 SoC, GPU,
      PTA, PDB), its four cost pools, and the grant fund placeholder (ADR-054 D1).

    * **The FY budget** — the manual's R&D budget dashboard (§5.2) as one
      `Budget` + `BudgetLine` per category, in cents.

    * **The asset register** — the PDK licence (an intangible over 36 months:
      the manual's JE-003/004) and the lab equipment (JE-063) as `Asset` rows.
      The schedule is DERIVED from each contract; the monthly
      `DepreciationRun` posts the slice, the posting map binds
      `accumulated_depreciation` to `1520`, and the lifecycle postings can
      dispose/reclassify from the accounts above.

    * **The journal approval policy** — enabled with a zero threshold, so the
      books' manual journal entries require a distinct approver. The seed
      creates it only when missing; an operator's later disable/threshold edit
      is REPORTED as drift, never silently overwritten.

    * **The AR collection cadence** — a non-default 7/14/21-day escalation
      cadence (the kernel default is 14/21/30), all stages enabled. It gives
      the demo org a realistic custom example on the AR settings screen. The
      seed creates it only when missing; an operator's edit is reported as
      drift, never silently overwritten.

    * **Functional currency CAD** (ADR-054 D15) on every account row.

  ## Idempotence and honesty

  Re-running creates nothing: every row is found by its natural key
  (`{org, code}`, `{org, key}`, `{org, name, period}`) and left alone. A row
  that EXISTS but disagrees with the manual is **reported** in the `:drifted`
  lists, never overwritten — the seed opens books, it does not silently re-point
  an operator's decisions. `verify/1` re-reads the org and answers whether the
  books are actually open; it is refutable (a bare org fails it), which is what
  keeps the phase's acceptance criterion from being a tautology.

  The manual's figures are **placeholders** (design §7). The structure ships;
  the numbers are the operator's to review before they are called Kubeworkz's
  policy.
  """

  require Ash.Query

  alias Samenerp.Erp

  @currency "CAD"

  # A deliberately non-default demo cadence: weekly notice, then final notice
  # and collections on the next two weeks. The kernel defaults are 14/21/30.
  @collection_cadence %{
    notice_enabled: true,
    final_notice_enabled: true,
    collections_enabled: true,
    notice_days: 7,
    final_notice_days: 14,
    collections_days: 21
  }

  # ---------------------------------------------------------------------------
  # The chart of accounts — {code, name, kind, normal_side}
  #
  # `docs/chip_manufacturing_accounting_setup.md` §"Chart of Accounts Reference"
  # (1000…8000) + the Variance Playbook's accounts (5100…5190) + the `1520`
  # correction documented in the moduledoc. The contra `1510` is an ASSET row
  # with `normal_side: :credit` — the manual's own reading, expressible with no
  # schema change (design §0.3).
  # ---------------------------------------------------------------------------
  @coa [
    # -- assets: cash, receivables, prepayments ------------------------------
    {"1000", "Cash – Operating", :asset, :debit},
    {"1100", "Accounts Receivable", :asset, :debit},
    {"1200", "Prepaid Foundry Costs – wafer.space", :asset, :debit},
    {"1210", "Prepaid Photonics Costs – GF/AMF", :asset, :debit},
    # -- assets: WIP at the subcontractors (a fabless company's inventory) ---
    {"1300", "WIP – Foundry (wafer.space)", :asset, :debit},
    {"1310", "WIP – Photonics (GF/AMF)", :asset, :debit},
    {"1320", "WIP – Assembly & Test", :asset, :debit},
    # -- assets: finished goods, one account per programme -------------------
    {"1400", "Inventory – Finished Goods (RISC-V64 SoC)", :asset, :debit},
    {"1410", "Inventory – Finished Goods (GPU)", :asset, :debit},
    {"1420", "Inventory – Finished Goods (PTA)", :asset, :debit},
    {"1430", "Inventory – Finished Goods (PDB)", :asset, :debit},
    # -- assets: the PDK license and its contra pairs ------------------------
    {"1500", "Intangible Assets – Photonics PDK License", :asset, :debit},
    {"1510", "Accumulated Amortization – PDK License", :asset, :credit},
    {"1520", "Accumulated Depreciation – Lab Equipment", :asset, :credit},
    {"1530", "Lab Equipment", :asset, :debit},
    {"1540", "Construction in Progress", :asset, :debit},
    # -- liabilities ---------------------------------------------------------
    {"2000", "Accounts Payable", :liability, :credit},
    {"2100", "Accrued Liabilities", :liability, :credit},
    {"2200", "Deferred Revenue", :liability, :credit},
    # -- equity --------------------------------------------------------------
    {"3000", "Common Stock", :equity, :credit},
    {"3100", "Retained Earnings", :equity, :credit},
    # -- income --------------------------------------------------------------
    {"4000", "Revenue – Board Sales", :income, :credit},
    {"4100", "Revenue – Grant Revenue", :income, :credit},
    # -- COGS ----------------------------------------------------------------
    {"5000", "COGS – Development Boards", :expense, :debit},
    {"5010", "COGS – Chip Sales", :expense, :debit},
    # -- the variance family (Variance Playbook §3–§7) -----------------------
    {"5100", "PPV – Foundry Slot Price", :expense, :debit},
    {"5110", "PPV – Photonics Slot Price", :expense, :debit},
    {"5120", "Yield Variance – RISC-V64 SoC", :expense, :debit},
    {"5130", "Yield Variance – GPU", :expense, :debit},
    {"5140", "Yield Variance – PTA", :expense, :debit},
    {"5150", "Labor Rate Variance", :expense, :debit},
    {"5160", "Labor Efficiency Variance", :expense, :debit},
    {"5170", "BOM Variance – PDB", :expense, :debit},
    {"5180", "Overhead Volume Variance", :expense, :debit},
    {"5190", "Overhead Spending Variance", :expense, :debit},
    # -- R&D operating expense ----------------------------------------------
    {"6000", "R&D – Mask & Reticle Costs", :expense, :debit},
    {"6010", "R&D – EDA Software & IP Licensing", :expense, :debit},
    {"6020", "R&D – Design Engineering Labor", :expense, :debit},
    {"6030", "R&D – Prototype & Test Engineering", :expense, :debit},
    {"6040", "R&D – PCB Development", :expense, :debit},
    # -- amortization of the PDK license ------------------------------------
    {"7000", "Amortization – PDK License", :expense, :debit},
    # -- realized FX on foreign-currency settlement -------------------------
    {"7900", "Foreign Exchange Gain/Loss", :income, :credit},
    # -- asset disposal gain/loss --------------------------------------------
    {"7920", "Gain/Loss on Asset Disposal", :income, :credit},
    # -- write-downs ---------------------------------------------------------
    {"8000", "Inventory Write-Down – Obsolete Chips", :expense, :debit}
  ]

  # ---------------------------------------------------------------------------
  # The posting map — {meaning, account code}
  #
  # Every row is the manual's own account for that flow (design D2: the enum is
  # a host decision, and the host here is the manual). Two meanings share `2200`
  # because the manual itself keeps ONE deferred-revenue account for both sales
  # deferrals and unearned grant awards (JE-072 credits `2200`).
  #
  # `:depreciation_expense` maps to `6030` because that is where the manual
  # books lab-equipment depreciation (JE-063: Dr 6030 / Cr accumulated
  # depreciation) — the manual carries no separate 70xx depreciation expense.
  # WS-ACCT Phase 8 (ADR-054 D9) added the `:accumulated_depreciation` meaning
  # so the asset run resolves the credit leg fail-honest too, like every other
  # posting, rather than hard-coding `1520`.
  #
  # WS-ACCT Phase 7 (ADR-054 D4) resolves the variance family the manual carries
  # ten of (5100–5190, per type AND per chip) into the four FAMILY meanings the
  # enum carries: the family head account is bound here, and the cost object
  # rides the entry's dimension, so "yield variance, GPU, March" is a GROUP BY
  # over the append-only lines rather than a fifth key. `:cogs` and `:rd_expense`
  # are the disposition targets the per-type table names (PPV/OH volume → 5000;
  # labour and OH spending → 6020). The manual's separate 5110/5130/5140/5160/
  # 5170/5190 rows stay open in the chart; the four families are what the
  # engine posts, and per-chip/per-type detail is the dimension.
  # ---------------------------------------------------------------------------
  @posting_map %{
    ap_clearing: "2000",
    ar_clearing: "1100",
    cash: "1000",
    income: "4000",
    wip_foundry: "1300",
    wip_photonics: "1310",
    wip_assembly: "1320",
    finished_goods_chip: "1400",
    finished_goods_board: "1430",
    deferred_revenue: "2200",
    grant_deferred: "2200",
    accrued_liabilities: "2100",
    employee_reimbursement_payable: "2100",
    amortization_expense: "7000",
    accumulated_amortization: "1510",
    depreciation_expense: "6030",
    accumulated_depreciation: "1520",
    asset_cost_intangible: "1500",
    asset_cost_equipment: "1530",
    construction_in_progress: "1540",
    disposal_gain_loss: "7920",
    write_down_expense: "8000",
    fx_gain_loss: "7900",
    mask_expense: "6000",
    eda_expense: "6010",
    # WS-ACCT Phase 7 — the four variance families and the two disposition
    # targets (see the comment above; D2's "at minimum" widened by two).
    variance_ppv: "5100",
    variance_yield: "5120",
    variance_labor: "5150",
    variance_overhead: "5180",
    cogs: "5000",
    rd_expense: "6020"
  }

  # Meanings this phase DELIBERATELY leaves unmapped, with the reason. The enum
  # is closed and fail-honest: an unmapped meaning refuses the posting, which is
  # the correct posture while the account is genuinely undecided. Binding one
  # now would post a silently wrong default later.
  @pending_meanings %{
    inventory_reserve:
      "Phase 9 ruled: Kubeworkz keeps NO reserve contra. The manual writes " <>
        "obsolescence straight off the inventory account (JE-034/062: Dr 8000 / " <>
        "Cr 1400·1410·1430), and the reserve POLICY is an estimate rule, not a GL " <>
        "balance — binding this meaning would let a caller park money in an " <>
        "account the chart never opens"
  }

  # ---------------------------------------------------------------------------
  # The obsolescence policy — the manual's own stated rule (JE-062's memo:
  # "chips older than 18 months with no expected sales are written down to
  # NRV"). It is a POLICY row, not a reserve balance: nothing posts until an
  # assessment drafts a write-down and a human clears it through the Gate.
  #
  # `applies_to: []` means every stocked item (the age basis). JE-034's
  # failed-validation write-down is an EVENT, not a standing age rule; an
  # operator authors an `:item` policy naming those items when it happens.
  # ---------------------------------------------------------------------------
  @reserve_policies [
    %{
      name: "Finished goods older than 18 months",
      basis: :age,
      age_months: 18,
      pct: 100,
      applies_to: []
    }
  ]

  # ---------------------------------------------------------------------------
  # The cost objects — the manual's four programmes, four cost pools, one fund
  # ---------------------------------------------------------------------------
  @cost_objects [
    {"riscv64-soc", "RISC-V64 SoC", :chip},
    {"gpu", "GPU", :chip},
    {"pta", "PTA Photonics", :chip},
    {"pdb", "PDB Development Board", :project},
    {"pool-foundry", "Foundry", :cost_pool},
    {"pool-photonics", "Photonics", :cost_pool},
    {"pool-assembly", "Assembly & Test", :cost_pool},
    {"pool-board-bom", "Board BOM", :cost_pool},
    {"fund-grants", "Grant Funds", :fund}
  ]

  # The manual's §5.2 R&D budget dashboard, annual, in cents. Placeholders, per
  # design §7 — the structure ships, the operator reviews the figures.
  @budget_name "R&D Operating Plan"
  @budget_lines [
    {"6020", 850_000_00, "Design engineering labor"},
    {"6010", 150_000_00, "EDA software & IP licensing"},
    {"6000", 15_000_00, "Mask & reticle costs"},
    {"6030", 96_000_00, "Prototype & test engineering"},
    {"6040", 15_000_00, "PCB development"},
    {"7000", 16_667_00, "PDK license amortization"}
  ]
  @budget_total 1_142_667_00

  # ---------------------------------------------------------------------------
  # The asset register — JE-003/004 (the PDK licence) and JE-063 (lab gear)
  #
  # The PDK licence capitalizes at 36 months (ADR-054 Ratification 7). Its
  # monthly slice is DERIVED, not stored: 600 000.00 / 36 = 16 666.666…, so the
  # schedule carries 16 666.66 for 35 months and 16 666.90 for the last — the
  # manual's 16 666.67 is the average, and the last month absorbs the remainder
  # so the term releases exactly 600 000.00.
  #
  # The lab equipment is the JE-063 asset; its cost is a placeholder (design §7)
  # like the manual's other figures. What the phase proves is the PAIR
  # (6030 / 1520) and the derived schedule, not the number.
  # ---------------------------------------------------------------------------
  @assets [
    %{
      code: "PDK-PHOTONICS",
      name: "Photonics PDK License",
      kind: :intangible,
      cost_cents: 60_000_000,
      acquired_on: ~D[2026-01-01],
      life_months: 36,
      salvage_cents: 0,
      cost_object: "pta",
      memo: "JE-003/004 — capitalized at 36 months, the manual's own term"
    },
    %{
      code: "LAB-EQUIPMENT",
      name: "Lab Equipment",
      kind: :equipment,
      cost_cents: 4_800_000,
      acquired_on: ~D[2026-01-01],
      life_months: 48,
      salvage_cents: 0,
      cost_object: nil,
      memo: "JE-063 — lab-equipment depreciation, booked to 6030 / 1520"
    }
  ]

  # -- reads the rest of the workstream cites ---------------------------------

  @doc "The chart of accounts this seed opens: `[{code, name, kind, normal_side}]`."
  def chart_of_accounts, do: @coa

  @doc "The posting map this seed binds: `%{meaning => account_code}`."
  def posting_map, do: @posting_map

  @doc """
  The meanings left unmapped on purpose, `%{meaning => why}` — the manual gives
  them no single account, so the fail-honest posture (an unmapped meaning
  refuses the posting) is the correct one until the owning phase decides.
  """
  def pending_meanings, do: @pending_meanings

  @doc "The cost objects this seed opens: `[{code, name, kind}]`."
  def cost_objects, do: @cost_objects

  @doc "The obsolescence policies this seed opens: `[%{name, basis, ...}]`."
  def reserve_policies, do: @reserve_policies

  @doc "The budget's name and the fiscal year it covers."
  def budget_name, do: @budget_name

  @doc "The budget's planned lines: `[{account_code, planned_cents, memo}]`."
  def budget_lines, do: @budget_lines

  @doc "The budget's planned total in cents."
  def budget_total_cents, do: @budget_total

  @doc "The asset register this seed opens: `[%{code, name, kind, cost_cents, ...}]`."
  def assets, do: @assets

  @doc "The functional currency every account is opened in (ADR-054 D15)."
  def currency, do: @currency

  @doc "The non-default collection cadence this seed opens (7/14/21 days, all stages enabled)."
  def collection_cadence, do: @collection_cadence

  @doc """
  The fiscal year the seed's budget covers — the CURRENT calendar year, read at
  call time so a re-seed in January opens the new year's skeleton rather than
  silently re-pointing last year's plan.
  """
  def fiscal_year, do: Date.utc_today().year

  # -- seed ------------------------------------------------------------------

  @doc """
  Open the books for `org_id`. Idempotent; creates only what is missing.

  Returns a summary map:

      %{
        org_id: String.t(),
        accounts: %{created: n, existing: n, drifted: [String.t()]},
        posting_accounts: %{created: n, existing: n, drifted: [String.t()]},
        cost_objects: %{created: n, existing: n, drifted: [String.t()]},
        assets: %{created: n, existing: n, drifted: [String.t()]},
        journal_approval: %{
          id: String.t(),
          created: boolean,
          enabled: boolean,
          threshold_cents: integer,
          drifted: [String.t()]
        },
        collection_cadence: %{id: String.t(), created: boolean, drifted: [String.t()]},
        budget: %{id: String.t(), year: integer, created: boolean},
        unmapped: [atom()]
      }
  """
  @spec seed!(String.t()) :: map()
  def seed!(org_id) do
    org_id = to_string(org_id)

    org_fx = seed_org_fx_settings(org_id)
    accounts = seed_accounts(org_id)
    posting = seed_posting_accounts(org_id)
    objects = seed_cost_objects(org_id)
    assets = seed_assets(org_id)
    reserves = seed_reserve_policies(org_id)
    approval = seed_journal_approval_policy(org_id)
    cadence = seed_collection_cadence(org_id)
    budget = seed_budget(org_id)

    %{
      org_id: org_id,
      org_fx_settings: org_fx,
      accounts: accounts,
      posting_accounts: posting,
      cost_objects: objects,
      assets: assets,
      reserve_policies: reserves,
      journal_approval: approval,
      collection_cadence: cadence,
      budget: budget,
      unmapped: @pending_meanings |> Map.keys() |> Enum.sort()
    }
  end

  defp seed_org_fx_settings(org_id) do
    case org_fx_settings(org_id) do
      nil ->
        Erp.OrgFxSettings
        |> Ash.Changeset.for_create(:create, %{org_id: org_id, base_currency: @currency},
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        %{created: true, base_currency: @currency, drifted: []}

      %{base_currency: @currency} ->
        %{created: false, base_currency: @currency, drifted: []}

      %{base_currency: other} ->
        %{
          created: false,
          base_currency: other,
          drifted: [
            "functional currency is #{inspect(other)}; the books are opened in #{@currency}"
          ]
        }
    end
  end

  defp seed_accounts(org_id) do
    {created, existing, drifted} =
      Enum.reduce(@coa, {0, 0, []}, fn {code, name, kind, side}, {created, existing, drifted} ->
        case account_by_code(org_id, code) do
          nil ->
            Erp.Account
            |> Ash.Changeset.for_create(
              :create,
              %{
                org_id: org_id,
                code: code,
                name: name,
                kind: kind,
                normal_side: side,
                currency: @currency
              },
              authorize?: false
            )
            |> Ash.create!(authorize?: false)

            {created + 1, existing, drifted}

          %{name: existing_name, kind: existing_kind, normal_side: existing_side} = account ->
            mismatch =
              [
                existing_name != name &&
                  "#{code} name #{inspect(existing_name)} ≠ #{inspect(name)}",
                existing_kind != kind &&
                  "#{code} kind #{inspect(existing_kind)} ≠ #{inspect(kind)}",
                existing_side != side &&
                  "#{code} normal_side #{inspect(existing_side)} ≠ #{inspect(side)}",
                account.currency != @currency &&
                  "#{code} currency #{inspect(account.currency)} ≠ #{inspect(@currency)}"
              ]
              |> Enum.filter(&is_binary/1)

            {created, existing + 1, drifted ++ mismatch}
        end
      end)

    %{created: created, existing: existing, drifted: drifted}
  end

  defp seed_posting_accounts(org_id) do
    {created, existing, drifted} =
      Enum.reduce(@posting_map, {0, 0, []}, fn {key, code}, {created, existing, drifted} ->
        account = account_by_code(org_id, code) || raise "missing CoA row #{code} for #{key}"

        case posting_account(org_id, key) do
          nil ->
            Erp.PostingAccount
            |> Ash.Changeset.for_create(
              :create,
              %{org_id: org_id, key: key, account_id: account.id},
              authorize?: false
            )
            |> Ash.create!(authorize?: false)

            {created + 1, existing, drifted}

          %{account_id: bound} ->
            drift =
              if bound == account.id,
                do: [],
                else: ["#{key} → #{bound} (the manual names #{code})"]

            {created, existing + 1, drifted ++ drift}
        end
      end)

    %{created: created, existing: existing, drifted: drifted}
  end

  defp seed_cost_objects(org_id) do
    {created, existing, drifted} =
      Enum.reduce(@cost_objects, {0, 0, []}, fn {code, name, kind},
                                                {created, existing, drifted} ->
        case cost_object_by_code(org_id, code) do
          nil ->
            Erp.CostObject
            |> Ash.Changeset.for_create(
              :create,
              %{org_id: org_id, code: code, name: name, kind: kind},
              authorize?: false
            )
            |> Ash.create!(authorize?: false)

            {created + 1, existing, drifted}

          %{name: existing_name, kind: existing_kind} ->
            mismatch =
              [
                existing_name != name &&
                  "#{code} name #{inspect(existing_name)} ≠ #{inspect(name)}",
                existing_kind != kind &&
                  "#{code} kind #{inspect(existing_kind)} ≠ #{inspect(kind)}"
              ]
              |> Enum.filter(&is_binary/1)

            {created, existing + 1, drifted ++ mismatch}
        end
      end)

    %{created: created, existing: existing, drifted: drifted}
  end

  defp seed_assets(org_id) do
    {created, existing, drifted} =
      Enum.reduce(@assets, {0, 0, []}, fn spec, {created, existing, drifted} ->
        case asset_by_code(org_id, spec.code) do
          nil ->
            cost_object =
              case spec.cost_object do
                nil -> nil
                code -> cost_object_by_code(org_id, code) || raise "missing cost object #{code}"
              end

            Erp.Asset
            |> Ash.Changeset.for_create(
              :create,
              %{
                org_id: org_id,
                code: spec.code,
                name: spec.name,
                memo: spec.memo,
                kind: spec.kind,
                cost_cents: spec.cost_cents,
                acquired_on: spec.acquired_on,
                life_months: spec.life_months,
                salvage_cents: spec.salvage_cents,
                cost_object_id: cost_object && cost_object.id
              },
              authorize?: false
            )
            |> Ash.create!(authorize?: false)

            {created + 1, existing, drifted}

          asset ->
            drift =
              [
                asset.name != spec.name &&
                  "#{spec.code} name #{inspect(asset.name)} ≠ #{inspect(spec.name)}",
                asset.kind != spec.kind &&
                  "#{spec.code} kind #{inspect(asset.kind)} ≠ #{inspect(spec.kind)}",
                asset.cost_cents != spec.cost_cents &&
                  "#{spec.code} cost #{asset.cost_cents} ≠ #{spec.cost_cents}",
                asset.acquired_on != spec.acquired_on &&
                  "#{spec.code} acquired_on #{asset.acquired_on} ≠ #{spec.acquired_on}",
                asset.life_months != spec.life_months &&
                  "#{spec.code} life #{asset.life_months} ≠ #{spec.life_months}",
                asset.salvage_cents != spec.salvage_cents &&
                  "#{spec.code} salvage #{asset.salvage_cents} ≠ #{spec.salvage_cents}"
              ]
              |> Enum.filter(&is_binary/1)

            {created, existing + 1, drifted ++ drift}
        end
      end)

    %{created: created, existing: existing, drifted: drifted}
  end

  defp seed_reserve_policies(org_id) do
    {created, existing, drifted} =
      Enum.reduce(@reserve_policies, {0, 0, []}, fn spec, {created, existing, drifted} ->
        case reserve_policy_by_name(org_id, spec.name) do
          nil ->
            Erp.InventoryReserve
            |> Ash.Changeset.for_create(
              :create,
              %{
                org_id: org_id,
                name: spec.name,
                basis: spec.basis,
                age_months: spec.age_months,
                pct: spec.pct,
                applies_to: spec.applies_to
              },
              authorize?: false
            )
            |> Ash.create!(authorize?: false)

            {created + 1, existing, drifted}

          policy ->
            drift =
              [
                policy.basis != spec.basis &&
                  "#{spec.name} basis #{inspect(policy.basis)} ≠ #{inspect(spec.basis)}",
                policy.age_months != spec.age_months &&
                  "#{spec.name} age_months #{inspect(policy.age_months)} ≠ " <>
                    "#{inspect(spec.age_months)}",
                policy.pct != spec.pct &&
                  "#{spec.name} pct #{policy.pct} ≠ #{spec.pct}",
                policy.applies_to != spec.applies_to &&
                  "#{spec.name} applies_to #{inspect(policy.applies_to)} ≠ " <>
                    "#{inspect(spec.applies_to)}"
              ]
              |> Enum.filter(&is_binary/1)

            {created, existing + 1, drifted ++ drift}
        end
      end)

    %{created: created, existing: existing, drifted: drifted}
  end

  defp seed_journal_approval_policy(org_id) do
    case journal_approval_policy(org_id) do
      nil ->
        policy =
          Erp.JournalApprovalPolicy
          |> Ash.Changeset.for_create(
            :create,
            %{org_id: org_id, enabled: true, threshold_cents: 0},
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        %{
          id: policy.id,
          created: true,
          enabled: policy.enabled,
          threshold_cents: policy.threshold_cents,
          drifted: []
        }

      policy ->
        drift =
          [
            policy.enabled != true &&
              "journal approval policy enabled #{policy.enabled} ≠ true",
            policy.threshold_cents != 0 &&
              "journal approval policy threshold #{policy.threshold_cents} ≠ 0"
          ]
          |> Enum.filter(&is_binary/1)

        %{
          id: policy.id,
          created: false,
          enabled: policy.enabled,
          threshold_cents: policy.threshold_cents,
          drifted: drift
        }
    end
  end

  defp seed_collection_cadence(org_id) do
    case collection_cadence_by_org(org_id) do
      nil ->
        cadence =
          Erp.CollectionCadence
          |> Ash.Changeset.for_create(
            :create,
            Map.put(@collection_cadence, :org_id, org_id),
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        %{id: cadence.id, created: true, drifted: []}

      existing ->
        drift =
          Enum.flat_map(@collection_cadence, fn {key, expected} ->
            actual = Map.fetch!(existing, key)

            if actual == expected do
              []
            else
              [
                "collection cadence #{key} #{inspect(actual)} ≠ #{inspect(expected)}"
              ]
            end
          end)

        %{id: existing.id, created: false, drifted: drift}
    end
  end

  defp seed_budget(org_id) do
    year = fiscal_year()

    case budget_by_name(org_id, year) do
      %{id: id} ->
        %{id: id, year: year, created: false}

      nil ->
        lines =
          Enum.map(@budget_lines, fn {code, cents, memo} ->
            account = account_by_code(org_id, code) || raise "missing CoA row #{code}"

            %{account_id: account.id, planned_cents: cents, memo: memo}
          end)

        budget =
          Erp.Budget
          |> Ash.Changeset.for_create(
            :create,
            %{org_id: org_id, name: @budget_name, period: year, lines: lines},
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        %{id: budget.id, year: year, created: true}
    end
  end

  # -- verify ----------------------------------------------------------------

  @doc """
  Is `org_id`'s book actually open? Re-reads the org and answers honestly.

  Returns `{:ok, %{accounts: n, posting_accounts: n, cost_objects: n, journal_approval: true, budget_id: id}}`
  or `{:error, [missing]}` naming every gap — a bare org fails with the whole
  list, which is what makes this a refutable check rather than a rubber stamp.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def verify(org_id) do
    org_id = to_string(org_id)

    missing =
      missing_org_fx_settings(org_id) ++
        missing_accounts(org_id) ++
        missing_posting_accounts(org_id) ++
        missing_cost_objects(org_id) ++
        missing_assets(org_id) ++
        missing_reserve_policies(org_id) ++
        missing_journal_approval_policy(org_id) ++ missing_budget(org_id)

    case missing do
      [] ->
        {:ok,
         %{
           base_currency: @currency,
           accounts: length(@coa),
           posting_accounts: map_size(@posting_map),
           cost_objects: length(@cost_objects),
           assets: length(@assets),
           reserve_policies: length(@reserve_policies),
           journal_approval: true,
           budget_id: budget_by_name(org_id, fiscal_year()).id
         }}

      gaps ->
        {:error, gaps}
    end
  end

  defp missing_org_fx_settings(org_id) do
    case org_fx_settings(org_id) do
      %{base_currency: @currency} ->
        []

      nil ->
        ["org FX settings (functional currency #{@currency}) are missing"]

      %{base_currency: other} ->
        ["functional currency is #{inspect(other)}, expected #{@currency}"]
    end
  end

  defp missing_accounts(org_id) do
    Enum.flat_map(@coa, fn {code, name, kind, side} ->
      case account_by_code(org_id, code) do
        %{name: ^name, kind: ^kind, normal_side: ^side} -> []
        nil -> ["account #{code} · #{name} is missing"]
        _other -> ["account #{code} does not match the manual (#{name})"]
      end
    end)
  end

  defp missing_posting_accounts(org_id) do
    Enum.flat_map(@posting_map, fn {key, code} ->
      expected = account_by_code(org_id, code)

      case {posting_account(org_id, key), expected} do
        {nil, _} -> ["posting meaning #{key} is unmapped"]
        {_, nil} -> ["posting meaning #{key} names a missing account #{code}"]
        {%{account_id: bound}, %{id: id}} when bound == id -> []
        _ -> ["posting meaning #{key} does not point at #{code}"]
      end
    end)
  end

  defp missing_cost_objects(org_id) do
    Enum.flat_map(@cost_objects, fn {code, name, kind} ->
      case cost_object_by_code(org_id, code) do
        %{name: ^name, kind: ^kind} -> []
        nil -> ["cost object #{code} · #{name} is missing"]
        _other -> ["cost object #{code} does not match #{name}"]
      end
    end)
  end

  defp missing_assets(org_id) do
    Enum.flat_map(@assets, fn spec ->
      case asset_by_code(org_id, spec.code) do
        %{name: name, kind: kind, cost_cents: cost, life_months: life, salvage_cents: salvage}
        when name == spec.name and kind == spec.kind and cost == spec.cost_cents and
               life == spec.life_months and salvage == spec.salvage_cents ->
          []

        nil ->
          ["asset #{spec.code} · #{spec.name} is missing"]

        _other ->
          ["asset #{spec.code} does not match the manual (#{spec.name})"]
      end
    end)
  end

  defp missing_reserve_policies(org_id) do
    Enum.flat_map(@reserve_policies, fn spec ->
      case reserve_policy_by_name(org_id, spec.name) do
        %{basis: basis, age_months: age, pct: pct, applies_to: applies_to}
        when basis == spec.basis and age == spec.age_months and pct == spec.pct and
               applies_to == spec.applies_to ->
          []

        nil ->
          ["reserve policy #{spec.name} is missing"]

        _other ->
          ["reserve policy #{spec.name} does not match the manual's 18-month rule"]
      end
    end)
  end

  defp missing_journal_approval_policy(org_id) do
    case journal_approval_policy(org_id) do
      %{enabled: true, threshold_cents: 0} ->
        []

      nil ->
        ["journal approval policy is missing"]

      policy ->
        [
          "journal approval policy must be enabled at threshold 0 " <>
            "(got enabled: #{policy.enabled}, threshold_cents: #{policy.threshold_cents})"
        ]
    end
  end

  defp missing_budget(org_id) do
    year = fiscal_year()

    case budget_by_name(org_id, year) do
      nil ->
        ["the #{year} budget · #{@budget_name} is missing"]

      %{lines: lines} ->
        planned = Enum.map(lines, &{account_code_of(org_id, &1.account_id), &1.planned_cents})

        Enum.flat_map(@budget_lines, fn {code, cents, _memo} ->
          if {code, cents} in planned,
            do: [],
            else: ["budget line #{code} is missing or not #{cents} cents"]
        end)
    end
  end

  # -- lookups ---------------------------------------------------------------

  defp org_fx_settings(org_id) do
    Erp.OrgFxSettings
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp account_by_code(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp posting_account(org_id, key) do
    Erp.PostingAccount
    |> Ash.Query.filter(org_id == ^org_id and key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp cost_object_by_code(org_id, code) do
    Erp.CostObject
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp asset_by_code(org_id, code) do
    Erp.Asset
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp reserve_policy_by_name(org_id, name) do
    Erp.InventoryReserve
    |> Ash.Query.filter(org_id == ^org_id and name == ^name)
    |> Ash.read_one!(authorize?: false)
  end

  defp journal_approval_policy(org_id) do
    Erp.JournalApprovalPolicy
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp collection_cadence_by_org(org_id) do
    Erp.CollectionCadence
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp budget_by_name(org_id, year) do
    Erp.Budget
    |> Ash.Query.filter(org_id == ^org_id and name == ^@budget_name and period == ^year)
    |> Ash.Query.load(:lines)
    |> Ash.read_one!(authorize?: false)
  end

  # The code behind an account id, for the budget-line comparison. A line
  # pointing at an account this seed did not open yields nil, which simply
  # fails the comparison below (honest: the plan does not match the manual).
  defp account_code_of(org_id, account_id) do
    case Erp.Account
         |> Ash.Query.filter(org_id == ^org_id and id == ^account_id)
         |> Ash.read_one!(authorize?: false) do
      %{code: code} -> code
      nil -> nil
    end
  end
end
