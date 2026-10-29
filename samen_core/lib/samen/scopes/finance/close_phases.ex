defmodule Samen.Scopes.Finance.ClosePhases do
  @moduledoc """
  The **ten phases of the monthly close** (WS-ACCT Phase 3; ADR-054 D7), taken
  verbatim from `docs/chip_manufacturing_accounting_setup.md` §"Monthly Close
  Checklist" — its *Close Calendar Overview* table.

  This module is DATA, not a task engine. ADR-054 D7 chose to anchor the close
  checklist to a `CloseRun` row rather than bend the Work scope's task model
  into a second job, so the phase list lives here as the single source of truth
  and `CloseRun.phases` copies it at `:start`.

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
      output: "Readiness confirmation"
    },
    %{
      key: "transaction_processing",
      label: "Transaction Processing",
      days: "Day 1-2",
      focus: "AP/AR, payroll, bank reconciliations",
      output: "Sub-ledgers closed"
    },
    %{
      key: "inventory_and_wip",
      label: "Inventory & WIP",
      days: "Day 2-3",
      focus: "Foundry/photonics WIP reconciliation, yield variance",
      output: "Inventory valuation"
    },
    %{
      key: "accruals_and_provisions",
      label: "Accruals & Provisions",
      days: "Day 3-4",
      focus: "Month-end accruals, prepayments, amortization",
      output: "Accrual entries posted"
    },
    %{
      key: "grant_accounting",
      label: "Grant Accounting",
      days: "Day 4-5",
      focus: "Grant revenue recognition, compliance tracking",
      output: "Grant reports"
    },
    %{
      key: "variance_analysis",
      label: "Variance Analysis",
      days: "Day 4-5",
      focus: "PPV, yield, labor, BOM variances",
      output: "Variance report"
    },
    %{
      key: "reconciliations",
      label: "Reconciliations",
      days: "Day 5-6",
      focus: "Balance sheet reconciliations, intercompany",
      output: "Reconciled TB"
    },
    %{
      key: "financial_statements",
      label: "Financial Statements",
      days: "Day 6-7",
      focus: "P&L, BS, CF, supporting schedules",
      output: "Draft financials"
    },
    %{
      key: "rolling_forecast_update",
      label: "Rolling Forecast Update",
      days: "Day 7-8",
      focus: "Actuals roll-in, driver updates, rollover",
      output: "Updated forecast"
    },
    %{
      key: "review_and_reporting",
      label: "Review & Reporting",
      days: "Day 8-10",
      focus: "CFO review, board package, grant reports",
      output: "Final close package"
    }
  ]

  @doc "The ten close phases, in the doc's calendar order."
  @spec all() :: [map()]
  def all, do: @phases

  @doc "The phase keys `CloseRun.:complete_phase` accepts, in order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@phases, & &1.key)

  @doc """
  The checklist a `CloseRun` starts with: every phase, `done_at` unset.

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
        "done_at" => nil
      }
    end)
  end

  @doc "Look a phase up by key. `nil` when the key is not one of the ten."
  @spec fetch(String.t()) :: map() | nil
  def fetch(key) when is_binary(key), do: Enum.find(@phases, &(&1.key == key))
  def fetch(_), do: nil
end
