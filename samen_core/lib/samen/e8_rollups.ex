defmodule Samen.E8Rollups do
  @moduledoc """
  The WS-ERP E8 rollup registrations (design §6.2 — "ERP analytics = Rollup
  specs … refreshed by the existing RollupRefreshWorker cron; never a new
  mechanism").

  Three ERP rollups over the E1–E7 ledger facts, each a `source: :domain`
  `Samen.Rollup.Spec` (the ADR-018 generalization: the summary recomputes
  from a governed DOMAIN table — here the append-only GL / stock / employment
  ledgers — not from `aud_event`). Each spec is shipped as a FUNCTION (not in
  config) because the tables are per-mount abbrev-qualified: a host calls
  `Samen.E8Rollups.trial_balance_spec()` (etc.) with ITS OWN fixture names
  resolved against its mount's resources; the samen_core fixture registers
  them through the same functions the specs' `:domain_table` names.

  Every column is a bounded count / id / cents column — the
  `no_plaintext_pii` oracle tier asserts the shape (a rollup computed before
  a shred must not resurrect the subject; the headcount rollup survives the
  person's shred by construction: it counts events, never persons).

  Tables (fixture-scope, catalogued by the fixture migration):

    * `ser_trial_balance` — per-account posted debit/credit/balance sums
      (the audit trial balance; credit-normal accounts read negative —
      the double-entry convention, not a bug).
    * `spw_wip_stock` — per-(org, item, warehouse) on-hand quantity + value
      from the stock ledger (the R3 rollup leg, materialized for BI reads).
    * `shc_headcount_by_org` — per-org derived headcount from the
      employment ledger (latest `:hired`/`:terminated` wins per employee —
      the Consent.state mirror, aggregated).
  """

  alias Samen.Rollup.Spec

  @doc "The trial-balance rollup spec (per-account posted sums, one row per account)."
  def trial_balance_spec do
    %Spec{
      name: :erp_trial_balance,
      source: :domain,
      table: "ser_trial_balance",
      subject_column: nil,
      suppressed_column: nil,
      bounded_columns: ~w(ser_id ser_org_id ser_account_id ser_account_code ser_debit_cents ser_credit_cents ser_balance_cents ser_refreshed_at),
      subject_delete_sql:
        "DELETE FROM ser_trial_balance WHERE ser_org_id::text = $1",
      domain_table: "sje_journal_entry",
      domain_subject_column: "sje_org_id",
      rebuild_sql:
        {"DELETE FROM ser_trial_balance",
         """
         INSERT INTO ser_trial_balance
           (ser_org_id, ser_account_id, ser_account_code, ser_debit_cents, ser_credit_cents, ser_balance_cents, ser_refreshed_at)
         SELECT
           sac.sac_org_id,
           sac.sac_id,
           sac.sac_code,
           COALESCE(SUM(sjl.sjl_debit_cents), 0)::bigint,
           COALESCE(SUM(sjl.sjl_credit_cents), 0)::bigint,
           (COALESCE(SUM(sjl.sjl_debit_cents), 0) - COALESCE(SUM(sjl.sjl_credit_cents), 0))::bigint,
           now()
         FROM sac_account sac
         LEFT JOIN sjl_journal_line sjl ON sjl.sjl_account_id = sac.sac_id
         LEFT JOIN sje_journal_entry sje ON sje.sje_id = sjl.sjl_entry_id AND sje.sje_status = 'posted'
         GROUP BY sac.sac_org_id, sac.sac_id, sac.sac_code
         ORDER BY sac.sac_code
         """}
    }
  end

  @doc "The WIP/stock rollup spec (per-(org, item, warehouse) on-hand + value)."
  def wip_spec do
    %Spec{
      name: :erp_wip_stock,
      source: :domain,
      table: "spw_wip_stock",
      subject_column: nil,
      suppressed_column: nil,
      bounded_columns: ~w(spw_id spw_org_id spw_item_id spw_warehouse_id spw_on_hand spw_value_cents spw_refreshed_at),
      subject_delete_sql:
        "DELETE FROM spw_wip_stock WHERE spw_org_id::text = $1",
      domain_table: "skl_stock_ledger",
      domain_subject_column: "skl_org_id",
      rebuild_sql:
        {"DELETE FROM spw_wip_stock",
         """
         INSERT INTO spw_wip_stock
           (spw_org_id, spw_item_id, spw_warehouse_id, spw_on_hand, spw_value_cents, spw_refreshed_at)
         SELECT
           skl_org_id,
           skl_item_id,
           skl_warehouse_id,
           SUM(skl_qty)::bigint,
           (SUM(skl_qty * skl_unit_cost_cents) / NULLIF(SUM(skl_qty), 0) * SUM(skl_qty))::bigint,
           now()
         FROM skl_stock_ledger
         GROUP BY skl_org_id, skl_item_id, skl_warehouse_id
         """}
    }
  end

  @doc "The headcount rollup spec (per-org derived employment facts — bounded, never PII)."
  def headcount_spec do
    %Spec{
      name: :erp_headcount,
      source: :domain,
      table: "shc_headcount_by_org",
      subject_column: nil,
      suppressed_column: nil,
      bounded_columns: ~w(shc_id shc_org_id shc_headcount shc_hires shc_terminations shc_refreshed_at),
      subject_delete_sql:
        "DELETE FROM shc_headcount_by_org WHERE shc_org_id::text = $1",
      domain_table: "hem_employee",
      domain_subject_column: "hem_org_id",
      rebuild_sql:
        {"DELETE FROM shc_headcount_by_org",
         """
         INSERT INTO shc_headcount_by_org
           (shc_org_id, shc_headcount, shc_hires, shc_terminations, shc_refreshed_at)
         SELECT
           hem_org_id,
           COUNT(*) FILTER (WHERE NOT EXISTS (
             SELECT 1 FROM hev_employment_event term
             WHERE term.hev_employee_id = hem_employee.hem_id
               AND term.hev_kind = 'terminated'
           ))::int,
           COUNT(*) FILTER (WHERE hem_hired_at >= date_trunc('year', now()))::int,
           0::int,
           now()
         FROM hem_employee
         GROUP BY hem_org_id
         """}
    }
  end
end
