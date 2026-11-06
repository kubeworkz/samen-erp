defmodule Samen.Scopes.Finance.ClosePhases do
  @moduledoc """
  The **ten phases of the monthly close** (WS-ACCT Phase 3; ADR-054 D7), taken
  verbatim from `docs/chip_manufacturing_accounting_setup.md` §"Monthly Close
  Checklist" — its *Close Calendar Overview* table — together with the
  **twelve role assignments** the same manual names (WS-ACCT Phase 12).

  This module is DATA, not a task engine. ADR-054 D7 chose to anchor the close
  checklist to a `CloseRun` row rather than bend the Work scope's task model
  into a second job, so the phase list lives here as the single source of truth
  and `CloseRun.phases` copies it at `:start`. Phase 12's Work anchoring
  (`Samen.Scopes.Finance.CloseChecklist`) reads the SAME list: one Work task per
  phase, carrying that phase's role assignment in `custom`.

  ## The roles are routing, not a GL axis

  `roles/0` is the manual's *Close Checklist Summary by Role* roster:
  Controller, AP Clerk, AR Clerk, Payroll Admin, Foundry Ops, Photonics Eng,
  Supply Chain, Grant Admin, FP&A, Treasury, CFO — plus **CTO**, the twelfth
  assignment the checklist's own tables name explicitly (tasks 8.2.2 and
  10.1.2, "CTO review of R&D expenditures and grant compliance" / "Prepare
  operational KPI dashboard") even though the summary-by-role section omits it.

  ADR-054 Ratification 1 rules that these owners stay in the Work/Automation
  layer and are **never** a journal dimension: putting the close org chart on
  the ledger would make reporting a second org chart. `role`/`roles` are
  therefore labels on the checklist task, not posting inputs.

  Supporting roles are the roster members whose work the phase's own section
  tables name (for example Phase 1's cut-off tables name AP, AR, Payroll, Grant
  Admin, Foundry Ops, Photonics Eng, Supply Chain and Treasury). Owners outside
  the roster (IT, Procurement, Sales Ops, HR, Engineering, Operations, the
  CEO's review, the Executive Assistant) keep their work inside the phase but
  are not invented as extra role identities: the manual's own summary is the
  roster, and a twelfth identity was not manufactured to make a count work.

  ## Why the days column is kept

  The doc's close calendar is business days *from month-end* (Day −3 … Day 10)
  and its own target is a preliminary close on Day 8 and a final one on Day 10.
  Keeping `days` alongside `key` means a surface can show "phase 7, Day 5–6 is
  still open" against the calendar without re-reading the manual, and the
  test suite can assert the ten phases still match the source's table — the
  same anti-drift discipline the coverage ledger applies to the COA.

  ## Keys are stable

  `key` is what `CloseRun.:complete_phase` accepts and what a caller stores.
  Adding a phase is a deliberate change here (a new key), never a caller
  convenience — the same posture as the dimension vocabulary
  (`Samen.Scopes.Finance.DimensionGuard`).
  """

  @phases [
    %{
      key: "pre_close",
      label: "Pre-Close",
      days: "Day -3 to Day 0",
      focus: "Cut-off preparation, accrual gathering",
      output: "Readiness confirmation",
      role: "Controller",
      roles: [
        "Controller",
        "AP Clerk",
        "AR Clerk",
        "Payroll Admin",
        "Grant Admin",
        "Foundry Ops",
        "Photonics Eng",
        "Supply Chain",
        "Treasury"
      ]
    },
    %{
      key: "transaction_processing",
      label: "Transaction Processing",
      days: "Day 1-2",
      focus: "AP/AR, payroll, bank reconciliations",
      output: "Sub-ledgers closed",
      role: "Controller",
      roles: [
        "Controller",
        "AP Clerk",
        "AR Clerk",
        "Payroll Admin",
        "Treasury",
        "Grant Admin"
      ]
    },
    %{
      key: "inventory_and_wip",
      label: "Inventory & WIP",
      days: "Day 2-3",
      focus: "Foundry/photonics WIP reconciliation, yield variance",
      output: "Inventory valuation",
      role: "Controller",
      roles: ["Controller", "Foundry Ops", "Photonics Eng", "Supply Chain"]
    },
    %{
      key: "accruals_and_provisions",
      label: "Accruals & Provisions",
      days: "Day 3-4",
      focus: "Month-end accruals, prepayments, amortization",
      output: "Accrual entries posted",
      role: "Controller",
      roles: ["Controller"]
    },
    %{
      key: "grant_accounting",
      label: "Grant Accounting",
      days: "Day 4-5",
      focus: "Grant revenue recognition, compliance tracking",
      output: "Grant reports",
      role: "Grant Admin",
      roles: ["Grant Admin", "Controller"]
    },
    %{
      key: "variance_analysis",
      label: "Variance Analysis",
      days: "Day 4-5",
      focus: "PPV, yield, labor, BOM variances",
      output: "Variance report",
      role: "Controller",
      roles: [
        "Controller",
        "Foundry Ops",
        "Photonics Eng",
        "Supply Chain",
        "FP&A",
        "Payroll Admin",
        "CTO"
      ]
    },
    %{
      key: "reconciliations",
      label: "Reconciliations",
      days: "Day 5-6",
      focus: "Balance sheet reconciliations, intercompany",
      output: "Reconciled TB",
      role: "Controller",
      roles: ["Controller", "Treasury", "AR Clerk", "AP Clerk", "Supply Chain"]
    },
    %{
      key: "financial_statements",
      label: "Financial Statements",
      days: "Day 6-7",
      focus: "P&L, BS, CF, supporting schedules",
      output: "Draft financials",
      role: "Controller",
      roles: ["Controller", "FP&A", "Grant Admin", "CFO", "CTO"]
    },
    %{
      key: "rolling_forecast_update",
      label: "Rolling Forecast Update",
      days: "Day 7-8",
      focus: "Actuals roll-in, driver updates, rollover",
      output: "Updated forecast",
      role: "FP&A",
      roles: ["FP&A", "Foundry Ops", "Photonics Eng", "Treasury", "CTO", "Supply Chain"]
    },
    %{
      key: "review_and_reporting",
      label: "Review & Reporting",
      days: "Day 8-10",
      focus: "CFO review, board package, grant reports",
      output: "Final close package",
      role: "CFO",
      roles: ["CFO", "CTO", "FP&A", "Grant Admin", "Controller"]
    }
  ]

  # The manual's "Close Checklist Summary by Role" roster (eleven) plus the CTO
  # assignment its phase tables name explicitly — see the moduledoc.
  @roles [
    "Controller",
    "AP Clerk",
    "AR Clerk",
    "Payroll Admin",
    "Foundry Ops",
    "Photonics Eng",
    "Supply Chain",
    "Grant Admin",
    "FP&A",
    "Treasury",
    "CFO",
    "CTO"
  ]

  @doc "The ten close phases, in the doc's calendar order."
  @spec all() :: [map()]
  def all, do: @phases

  @doc "The twelve role assignments the manual's checklist names."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The phase keys `CloseRun.:complete_phase` accepts, in order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@phases, & &1.key)

  @doc "The phase's LEAD role (the accountable owner), or `nil` for an unknown key."
  @spec role_of(String.t() | nil) :: String.t() | nil
  def role_of(key), do: (fetch(key) || %{})[:role]

  @doc "Every roster role the phase's own section tables name, in roster order."
  @spec roles_for(String.t() | nil) :: [String.t()]
  def roles_for(key), do: (fetch(key) || %{})[:roles] || []

  @doc """
  The checklist a `CloseRun` starts with: every phase, `done_at` unset, carrying
  its role assignment so a signed run records the owners it was closed under.

  Stored as JSON-safe maps (string keys, no atoms) because it lands in a jsonb
  column — an atom-keyed map would round-trip back as strings and the read
  side would then have to know which form it was looking at.
  """
  @spec seeded() :: [map()]
  def seeded do
    Enum.map(@phases, fn phase ->
      %{
        "key" => phase.key,
        "label" => phase.label,
        "days" => phase.days,
        "focus" => phase.focus,
        "output" => phase.output,
        "role" => phase.role,
        "roles" => phase.roles,
        "done_at" => nil
      }
    end)
  end

  @doc "Look a phase up by key. `nil` when the key is not one of the ten."
  @spec fetch(String.t()) :: map() | nil
  def fetch(key) when is_binary(key), do: Enum.find(@phases, &(&1.key == key))
  def fetch(_), do: nil
end
