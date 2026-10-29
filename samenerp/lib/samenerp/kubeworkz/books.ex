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

      Nothing else is invented: `1520` is the only row not present in the
      manual, and it exists so JE-063's credit leg is expressible at all.

    * **The posting map** — one `PostingAccount` row per meaning the manual
      actually gives an account for (see `pending_meanings/0` for the ones it
      does not, and why they stay unmapped).

    * **The cost objects** — the manual's four programmes (RISC-V64 SoC, GPU,
      PTA, PDB), its four cost pools, and the grant fund placeholder (ADR-054 D1).

    * **The FY budget** — the manual's R&D budget dashboard (§5.2) as one
      `Budget` + `BudgetLine` per category, in cents.

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
  # The credit leg's account is `1520`; the posting map has no key for it
  # because the asset run (Phase 8) posts the pair, not a document flow.
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
    amortization_expense: "7000",
    accumulated_amortization: "1510",
    depreciation_expense: "6030",
    write_down_expense: "8000",
    mask_expense: "6000",
    eda_expense: "6010"
  }

  # Meanings this phase DELIBERATELY leaves unmapped, with the reason. The enum
  # is closed and fail-honest: an unmapped meaning refuses the posting, which is
  # the correct posture while the account is genuinely undecided. Binding one
  # now would post a silently wrong default later.
  @pending_meanings %{
    inventory_reserve:
      "the manual writes obsolescence straight off the inventory account " <>
        "(JE-062: Dr 8000 / Cr 1400·1410) and carries no reserve contra; " <>
        "whether Kubeworkz keeps a reserve is Phase 9's call",
    variance_ppv:
      "the manual carries TEN variance accounts (5100–5190, per type and per chip); " <>
        "Phase 7's engine dispatches over them — one key cannot stand for 5100 and 5110",
    variance_yield: "as variance_ppv — 5120/5130/5140 are three accounts, not one",
    variance_labor: "as variance_ppv — 5150 (rate) and 5160 (efficiency) are two accounts",
    variance_overhead: "as variance_ppv — 5180 (volume) and 5190 (spending) are two accounts"
  }

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

  @doc "The budget's name and the fiscal year it covers."
  def budget_name, do: @budget_name

  @doc "The budget's planned lines: `[{account_code, planned_cents, memo}]`."
  def budget_lines, do: @budget_lines

  @doc "The budget's planned total in cents."
  def budget_total_cents, do: @budget_total

  @doc "The functional currency every account is opened in (ADR-054 D15)."
  def currency, do: @currency

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
        budget: %{id: String.t(), year: integer, created: boolean},
        unmapped: [atom()]
      }
  """
  @spec seed!(String.t()) :: map()
  def seed!(org_id) do
    org_id = to_string(org_id)

    accounts = seed_accounts(org_id)
    posting = seed_posting_accounts(org_id)
    objects = seed_cost_objects(org_id)
    budget = seed_budget(org_id)

    %{
      org_id: org_id,
      accounts: accounts,
      posting_accounts: posting,
      cost_objects: objects,
      budget: budget,
      unmapped: @pending_meanings |> Map.keys() |> Enum.sort()
    }
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
                existing_name != name && "#{code} name #{inspect(existing_name)} ≠ #{inspect(name)}",
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
      Enum.reduce(@cost_objects, {0, 0, []}, fn {code, name, kind}, {created, existing, drifted} ->
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
                existing_name != name && "#{code} name #{inspect(existing_name)} ≠ #{inspect(name)}",
                existing_kind != kind &&
                  "#{code} kind #{inspect(existing_kind)} ≠ #{inspect(kind)}"
              ]
              |> Enum.filter(&is_binary/1)

            {created, existing + 1, drifted ++ mismatch}
        end
      end)

    %{created: created, existing: existing, drifted: drifted}
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

  Returns `{:ok, %{accounts: n, posting_accounts: n, cost_objects: n, budget_id: id}}`
  or `{:error, [missing]}` naming every gap — a bare org fails with the whole
  list, which is what makes this a refutable check rather than a rubber stamp.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def verify(org_id) do
    org_id = to_string(org_id)

    missing =
      missing_accounts(org_id) ++
        missing_posting_accounts(org_id) ++
        missing_cost_objects(org_id) ++ missing_budget(org_id)

    case missing do
      [] ->
        {:ok,
         %{
           accounts: length(@coa),
           posting_accounts: map_size(@posting_map),
           cost_objects: length(@cost_objects),
           budget_id: budget_by_name(org_id, fiscal_year()).id
         }}

      gaps ->
        {:error, gaps}
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
