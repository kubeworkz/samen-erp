defmodule Samenerp.Repo.Migrations.MountErpScope do
  @moduledoc """
  The `Samenerp.Erp` mount: the WS-ERP Finance + Inventory scopes (E1–E7
  resources) mounted over ONE host namespace, with the Procurement/Sales
  bridges wired to the host's Finance modules and the host's REAL Billing
  invoice (the E5 emission target — `Samenerp.Billing.Invoice`, abbrev
  `eri`, already tabled by the generated host's Billing mount migration).

  The DDL + belt is the concatenation of the E1–E6 fixture migrations (each
  phase's `up` in order, `down` in reverse), prefixes remapped to the host's
  own reserved abbrevs, with catalog rows for ALL host resources via
  `catalog_sync/1` in this same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.Account,
    Samenerp.Erp.JournalEntry,
    Samenerp.Erp.JournalLine,
    Samenerp.Erp.ApInvoice,
    Samenerp.Erp.PaymentReceipt,
    Samenerp.Erp.PostingAccount,
    Samenerp.Erp.Budget,
    Samenerp.Erp.BudgetLine,
    Samenerp.Erp.Item,
    Samenerp.Erp.Warehouse,
    Samenerp.Erp.StockLedger,
    Samenerp.Erp.StockLevel,
    Samenerp.Erp.PurchaseOrder,
    Samenerp.Erp.PoLine,
    Samenerp.Erp.GoodsReceipt,
    Samenerp.Erp.ReceiptLine,
    Samenerp.Erp.SalesOrder,
    Samenerp.Erp.SoLine,
    Samenerp.Erp.Bom,
    Samenerp.Erp.BomLine,
    Samenerp.Erp.WorkOrder,
    Samenerp.Erp.ProductionLog,
  ]

  def up do
    # ════ Finance scope (WS-ERP E1: CoA, journal, AP/AR documents, posting accounts, budgets) ════
    create table(:eca_account, primary_key: false) do
      add(:eca_code, :text, null: false)
      add(:eca_name, :text, null: false)
      add(:eca_kind, :text, null: false)
      add(:eca_normal_side, :text, null: false)
      add(:eca_currency, :text, null: false, default: "USD")
      add(:eca_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eca_org_id, :uuid, null: false)
      add(:eca_inserted_at, :utc_datetime, null: false)
      add(:eca_updated_at, :utc_datetime, null: false)
      add(:eca_archived_at, :utc_datetime_usec)

      add(
        :eca_parent_id,
        references(:eca_account, column: :eca_id, name: "eca_account_eca_parent_id_fkey", type: :uuid)
      )
    end

    create(index(:eca_account, [:eca_org_id]))
    create(index(:eca_account, [:eca_parent_id]))
    create(index(:eca_account, [:eca_org_id, :eca_code], unique: true))

    create table(:ecj_journal_entry, primary_key: false) do
      add(:ecj_entry_date, :date, null: false)
      add(:ecj_memo, :text)
      add(:ecj_status, :text, null: false, default: "draft")
      add(:ecj_source_key, :text)
      add(:ecj_source_id, :uuid)
      add(:ecj_posted_at, :utc_datetime)
      add(:ecj_voided_entry_id, :uuid)
      add(:ecj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecj_org_id, :uuid, null: false)
      add(:ecj_inserted_at, :utc_datetime, null: false)
      add(:ecj_updated_at, :utc_datetime, null: false)
      add(:ecj_archived_at, :utc_datetime_usec)
    end

    create(index(:ecj_journal_entry, [:ecj_org_id]))
    create(index(:ecj_journal_entry, [:ecj_source_key, :ecj_source_id]))

    create(
      constraint(:ecj_journal_entry, :ecj_status_valid,
        check: "ecj_status IN ('draft', 'posted', 'void')"
      )
    )

    create table(:ecl_journal_line, primary_key: false) do
      add(:ecl_debit_cents, :bigint, null: false, default: 0)
      add(:ecl_credit_cents, :bigint, null: false, default: 0)
      add(:ecl_memo, :text)
      add(:ecl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecl_org_id, :uuid, null: false)
      add(:ecl_inserted_at, :utc_datetime, null: false)
      add(:ecl_updated_at, :utc_datetime, null: false)

      add(
        :ecl_entry_id,
        references(:ecj_journal_entry,
          column: :ecj_id,
          name: "ecl_journal_line_ecl_entry_id_fkey",
          type: :uuid
        )
      )

      add(
        :ecl_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "ecl_journal_line_ecl_account_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ecl_journal_line, [:ecl_org_id]))
    create(index(:ecl_journal_line, [:ecl_entry_id]))
    create(index(:ecl_journal_line, [:ecl_account_id]))

    create(
      constraint(:ecl_journal_line, :ecl_amounts_positive,
        check: "ecl_debit_cents >= 0 AND ecl_credit_cents >= 0"
      )
    )

    # -----------------------------------------------------------------------
    # Belt 1: posted-entry immutability (UPDATE/DELETE refused; non-draft
    # INSERT refused without the PostGuard transaction-local marker).
    # -----------------------------------------------------------------------
    execute """
    CREATE OR REPLACE FUNCTION ecj_journal_entry_enforce_posted_immutability()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    DECLARE
      armed boolean;
    BEGIN
      -- COALESCE: an unset GUC returns NULL (missing_ok), and NULL = 'on' is
      -- NULL — without the coalesce, NOT armed is NULL and the IF never fires
      -- (the belt would refuse NOTHING; the red-paths prove it must).
      armed := COALESCE(current_setting('samen.finance_posting', true), 'off') = 'on';

      IF TG_OP = 'INSERT' THEN
        IF NEW.ecj_status IS NOT NULL AND NEW.ecj_status <> 'draft' AND NOT armed THEN
          RAISE EXCEPTION 'ecj_journal_entry: a non-draft INSERT requires the PostGuard '
            'transaction-local marker (samen.finance_posting) — refused. status: %',
            NEW.ecj_status;
        END IF;
      END IF;

      IF TG_OP = 'DELETE' THEN
        IF OLD.ecj_status <> 'draft' AND NOT armed THEN
          RAISE EXCEPTION 'ecj_journal_entry is append-only once posted: DELETE of a '
            'non-draft entry is not permitted (void instead). Entry id: %, status: %',
            COALESCE(OLD.ecj_id::text, '?'), COALESCE(OLD.ecj_status, '?');
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' THEN
        -- Keyed on BOTH sides: the draft->posted TRANSITION carries the new
        -- state in NEW, so a raw-SQL two-step (insert a draft + UPDATE it to
        -- posted) cannot forge a posted entry without the marker — the
        -- PostGuard-armed actions are the ONLY route to a non-draft state.
        IF (OLD.ecj_status <> 'draft' OR NEW.ecj_status <> 'draft') AND NOT armed THEN
          RAISE EXCEPTION 'ecj_journal_entry is append-only once posted: UPDATE of a '
            'non-draft entry, or a transition onto one, is not permitted without the '
            'PostGuard transaction-local marker (samen.finance_posting). Entry id: %, '
            'old status: %, new status: %',
            COALESCE(OLD.ecj_id::text, '?'), COALESCE(OLD.ecj_status, '?'),
            COALESCE(NEW.ecj_status, '?');
        END IF;
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $$
    """, "DROP FUNCTION IF EXISTS ecj_journal_entry_enforce_posted_immutability()"

    execute """
    CREATE TRIGGER ecj_journal_entry_posted_immutable_tg
    BEFORE INSERT OR UPDATE OR DELETE ON ecj_journal_entry
    FOR EACH ROW EXECUTE FUNCTION ecj_journal_entry_enforce_posted_immutability()
    """, "DROP TRIGGER IF EXISTS ecj_journal_entry_posted_immutable_tg ON ecj_journal_entry"

    # -----------------------------------------------------------------------
    # Belt 2: the line table is append-only, except a DELETE whose every
    # affected row's ENTRY is still a draft (the draft-replacement path).
    # -----------------------------------------------------------------------
    execute """
    CREATE OR REPLACE FUNCTION ecl_journal_line_enforce_append_only()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    DECLARE
      armed boolean;
      entry_status text;
      draft_entries integer;
    BEGIN
      -- COALESCE: same unset-GUC NULL-trap as the entry trigger above.
      armed := COALESCE(current_setting('samen.finance_posting', true), 'off') = 'on';

      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'ecl_journal_line is append-only: UPDATE is not permitted. '
          'Line id: %', COALESCE(OLD.ecl_id::text, '?');
      END IF;

      IF TG_OP = 'DELETE' THEN
        SELECT count(*) INTO draft_entries FROM ecj_journal_entry e
        WHERE e.ecj_id = OLD.ecl_entry_id AND e.ecj_status = 'draft';

        IF draft_entries = 0 THEN
          RAISE EXCEPTION 'ecl_journal_line is append-only: DELETE is permitted only '
            'while the line''s entry is a draft. Line id: %',
            COALESCE(OLD.ecl_id::text, '?');
        END IF;
      END IF;

      IF TG_OP = 'INSERT' THEN
        SELECT e.ecj_status INTO entry_status FROM ecj_journal_entry e
        WHERE e.ecj_id = NEW.ecl_entry_id;

        IF entry_status IS DISTINCT FROM 'draft' AND NOT armed THEN
          RAISE EXCEPTION 'ecl_journal_line: INSERT into a non-draft entry requires the '
            'PostGuard transaction-local marker (samen.finance_posting) — a posted '
            'entry''s line set is frozen. Entry id: %, status: %',
            COALESCE(NEW.ecl_entry_id::text, '?'), COALESCE(entry_status, '?');
        END IF;
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $$
    """, "DROP FUNCTION IF EXISTS ecl_journal_line_enforce_append_only()"

    execute """
    CREATE TRIGGER ecl_journal_line_append_only_tg
    BEFORE INSERT OR UPDATE OR DELETE ON ecl_journal_line
    FOR EACH ROW EXECUTE FUNCTION ecl_journal_line_enforce_append_only()
    """, "DROP TRIGGER IF EXISTS ecl_journal_line_append_only_tg ON ecl_journal_line"

    # ── Budget — the plan header (WS-ERP E8; design §2.1) ──────────────────
    create table(:ecb_budget, primary_key: false) do
      add(:ecb_name, :text, null: false)
      add(:ecb_period, :integer, null: false)
      add(:ecb_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecb_org_id, :uuid, null: false)
      add(:ecb_inserted_at, :utc_datetime, null: false)
      add(:ecb_updated_at, :utc_datetime, null: false)
      add(:ecb_archived_at, :utc_datetime_usec)
    end

    create(index(:ecb_budget, [:ecb_org_id]))
    create(index(:ecb_budget, [:ecb_org_id, :ecb_name, :ecb_period], unique: true))

    execute """
    ALTER TABLE ecb_budget
      ADD CONSTRAINT ecb_period_valid CHECK (ecb_period BETWEEN 2000 AND 2999)
    """,
    "ALTER TABLE ecb_budget DROP CONSTRAINT ecb_period_valid"

    # ── BudgetLine — one account's planned amount ──────────────────────────
    create table(:ecd_budget_line, primary_key: false) do
      add(:ecd_planned_cents, :bigint, null: false)
      add(:ecd_memo, :text)
      add(:ecd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecd_org_id, :uuid, null: false)
      add(:ecd_inserted_at, :utc_datetime, null: false)
      add(:ecd_updated_at, :utc_datetime, null: false)

      add(
        :ecd_budget_id,
        references(:ecb_budget,
          column: :ecb_id,
          name: "ecd_budget_line_ecd_budget_id_fkey",
          type: :uuid
        )
      )

      add(
        :ecd_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "ecd_budget_line_ecd_account_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ecd_budget_line, [:ecd_org_id]))
    create(index(:ecd_budget_line, [:ecd_budget_id]))
    create(index(:ecd_budget_line, [:ecd_account_id]))
    create(
      index(:ecd_budget_line, [:ecd_org_id, :ecd_budget_id, :ecd_account_id], unique: true)
    )

    execute """
    ALTER TABLE ecd_budget_line
      ADD CONSTRAINT ecd_planned_non_negative CHECK (ecd_planned_cents >= 0)
    """,
    "ALTER TABLE ecd_budget_line DROP CONSTRAINT ecd_planned_non_negative"


    # ════ Finance documents (WS-ERP E2: AP bills, payment receipts, posting accounts) ════
    # ── PostingAccount — the named GL posting accounts ──────────────────────
    create table(:ecf_posting_account, primary_key: false) do
      add(:ecf_key, :text, null: false)
      add(:ecf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecf_org_id, :uuid, null: false)
      add(:ecf_inserted_at, :utc_datetime, null: false)
      add(:ecf_updated_at, :utc_datetime, null: false)

      add(
        :ecf_account_id,
        references(:eca_account, column: :eca_id, name: "ecf_posting_account_ecf_account_id_fkey", type: :uuid)
      )
    end

    create(index(:ecf_posting_account, [:ecf_org_id]))
    create(index(:ecf_posting_account, [:ecf_account_id]))

    create(index(:ecf_posting_account, [:ecf_org_id, :ecf_key], unique: true))

    # ── ApInvoice — the AP vendor bill ──────────────────────────────────────
    create table(:ecp_ap_invoice, primary_key: false) do
      add(:ecp_vendor_id, :uuid, null: false)
      add(:ecp_number, :text, null: false)
      add(:ecp_bill_date, :date, null: false)
      add(:ecp_due_date, :date)
      add(:ecp_memo, :text)
      add(:ecp_lines, :map, null: false)
      add(:ecp_status, :text, null: false, default: "draft")
      add(:ecp_posted_entry_id, :uuid)
      add(:ecp_posted_at, :utc_datetime)
      add(:ecp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecp_org_id, :uuid, null: false)
      add(:ecp_inserted_at, :utc_datetime, null: false)
      add(:ecp_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecp_ap_invoice, [:ecp_org_id]))
    create(index(:ecp_ap_invoice, [:ecp_vendor_id]))
    create(index(:ecp_ap_invoice, [:ecp_org_id, :ecp_number], unique: true))

    execute """
            ALTER TABLE ecp_ap_invoice
              ADD CONSTRAINT ecp_status_valid CHECK (ecp_status IN ('draft','approved','paid','void'))
            """,
            "ALTER TABLE ecp_ap_invoice DROP CONSTRAINT ecp_status_valid"

    execute """
            CREATE FUNCTION ecp_ap_invoice_enforce() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(
                current_setting('samen.finance_posting', true) = 'on', false
              );
              line jsonb;
            BEGIN
              -- Line shape on every write (belt over ApLines; a CHECK cannot
              -- hold the subquery, so the trigger owns it): at least one
              -- line, every amount a POSITIVE number (missing key and
              -- jsonb null are caught by the ->' NULL test).
              IF TG_OP IN ('INSERT', 'UPDATE') THEN
                IF jsonb_typeof(NEW.ecp_lines) IS DISTINCT FROM 'array'
                   OR jsonb_array_length(NEW.ecp_lines) = 0 THEN
                  RAISE EXCEPTION 'ecp_ap_invoice: an AP bill carries at least one line '
                    '(lines: %)', NEW.ecp_lines;
                END IF;

                FOR line IN SELECT * FROM jsonb_array_elements(NEW.ecp_lines) LOOP
                  IF line->'amount_cents' IS NULL
                     OR jsonb_typeof(line->'amount_cents') <> 'number'
                     OR (line->>'amount_cents')::numeric <= 0 THEN
                    RAISE EXCEPTION 'ecp_ap_invoice: every AP line amount_cents must be a '
                      'positive integer (credits are separate bills) — line: %', line;
                  END IF;
                END LOOP;
              END IF;

              IF TG_OP = 'DELETE' THEN
                IF OLD.ecp_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'ecp_ap_invoice: DELETE of a non-draft bill is refused — '
                    'an AP bill is a business record; voiding is the P2 credit-note carry. '
                    'Bill id: %', OLD.ecp_id;
                END IF;
              ELSE
                -- The UPDATE arm keys on BOTH sides: a draft->approved
                -- TRANSITION carries the new state in NEW (a raw-SQL approval
                -- is refused), and any edit of an already-non-draft row dies
                -- with it. Draft->draft field edits stay free. (UPDATE only —
                -- on INSERT OLD is all-NULL and IS DISTINCT FROM 'draft' is
                -- vacuously TRUE, which would refuse every legal create.)
                IF TG_OP = 'UPDATE' AND (NEW.ecp_status IS DISTINCT FROM 'draft'
                    OR OLD.ecp_status IS DISTINCT FROM 'draft') AND NOT armed THEN
                  RAISE EXCEPTION 'ecp_ap_invoice: UPDATE onto or away from a non-draft '
                    'state requires the transaction-local marker (samen.finance_posting) '
                    '— only the marker-armed :approve transition flips draft to approved. '
                    'Bill id: %, old status: %, new status: %',
                    OLD.ecp_id, OLD.ecp_status, NEW.ecp_status;
                END IF;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ecp_ap_invoice_enforce_approved_immutability()"

    execute """
            CREATE TRIGGER ecp_ap_invoice_enforce_tg
            BEFORE INSERT OR UPDATE OR DELETE ON ecp_ap_invoice
            FOR EACH ROW EXECUTE FUNCTION ecp_ap_invoice_enforce()
            """,
            "DROP TRIGGER IF EXISTS ecp_ap_invoice_enforce_tg ON ecp_ap_invoice"

    # ── PaymentReceipt — the AR intake ──────────────────────────────────────
    create table(:ecr_payment_receipt, primary_key: false) do
      add(:ecr_invoice_key, :text, null: false)
      add(:ecr_invoice_id, :uuid, null: false)
      add(:ecr_amount_cents, :bigint, null: false)
      add(:ecr_currency, :text, null: false, default: "USD")
      add(:ecr_paid_at, :utc_datetime, null: false)
      add(:ecr_memo, :text)
      add(:ecr_status, :text, null: false, default: "draft")
      add(:ecr_posted_entry_id, :uuid)
      add(:ecr_posted_at, :utc_datetime)
      add(:ecr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ecr_org_id, :uuid, null: false)
      add(:ecr_inserted_at, :utc_datetime, null: false)
      add(:ecr_updated_at, :utc_datetime, null: false)
    end

    create(index(:ecr_payment_receipt, [:ecr_org_id]))
    create(index(:ecr_payment_receipt, [:ecr_org_id, :ecr_invoice_key, :ecr_invoice_id]))

    execute """
            CREATE UNIQUE INDEX ecr_anchor_unique ON ecr_payment_receipt (ecr_org_id, ecr_invoice_key, ecr_invoice_id)
            WHERE ecr_status = 'posted'
            """,
            "DROP INDEX IF EXISTS ecr_anchor_unique"

    execute """
            ALTER TABLE ecr_payment_receipt
              ADD CONSTRAINT ecr_status_valid CHECK (ecr_status IN ('draft','posted'))
            """,
            "ALTER TABLE ecr_payment_receipt DROP CONSTRAINT ecr_status_valid"

    execute """
            ALTER TABLE ecr_payment_receipt
              ADD CONSTRAINT ecr_amount_positive CHECK (ecr_amount_cents > 0)
            """,
            "ALTER TABLE ecr_payment_receipt DROP CONSTRAINT ecr_amount_positive"

    execute """
            CREATE FUNCTION ecr_payment_receipt_enforce_posted_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(
                current_setting('samen.finance_posting', true) = 'on', false
              );
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.ecr_status IS DISTINCT FROM 'draft' AND NOT armed THEN
                  RAISE EXCEPTION 'ecr_payment_receipt: INSERT of a non-draft receipt '
                    'requires the transaction-local marker (samen.finance_posting) — a '
                    'posted receipt is a fact, landed only by :post_receipt. '
                    'Receipt id: %', NEW.ecr_id;
                END IF;
              END IF;

              IF TG_OP = 'UPDATE' THEN
                -- Keyed on BOTH sides: the draft->posted TRANSITION carries the
                -- new state in NEW (a raw-SQL posting is refused), and any edit
                -- of a posted row dies with it. Draft->draft edits stay free.
                IF (NEW.ecr_status IS DISTINCT FROM 'draft'
                    OR OLD.ecr_status IS DISTINCT FROM 'draft') AND NOT armed THEN
                  RAISE EXCEPTION 'ecr_payment_receipt: UPDATE onto or away from a posted '
                    'state requires the transaction-local marker (samen.finance_posting) '
                    '— only the marker-armed :post_receipt flips draft to posted. '
                    'Receipt id: %, old status: %, new status: %',
                    OLD.ecr_id, OLD.ecr_status, NEW.ecr_status;
                END IF;
              END IF;

              IF TG_OP = 'DELETE' THEN
                IF OLD.ecr_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'ecr_payment_receipt: DELETE of a posted receipt is '
                    'refused outright — a posted receipt is a fact; receipts are not '
                    'destroyed. Receipt id: %', OLD.ecr_id;
                END IF;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ecr_payment_receipt_enforce_posted_guard()"

    execute """
            CREATE TRIGGER ecr_payment_receipt_posted_guard_tg
            BEFORE INSERT OR UPDATE OR DELETE ON ecr_payment_receipt
            FOR EACH ROW EXECUTE FUNCTION ecr_payment_receipt_enforce_posted_guard()
            """,
            "DROP TRIGGER IF EXISTS ecr_payment_receipt_posted_guard_tg ON ecr_payment_receipt"

    # ════ Inventory core (WS-ERP E3: items, warehouses, the append-only stock ledger + derived level) ════
    # ── Item — the item master ────────────────────────────────────────────
    create table(:eni_item, primary_key: false) do
      add(:eni_sku, :text, null: false)
      add(:eni_name, :text, null: false)
      add(:eni_kind, :text, null: false, default: "stocked")
      add(:eni_uom, :text, null: false, default: "unit")
      add(:eni_reorder_point, :integer)
      add(:eni_default_income_account_id, :uuid)
      add(:eni_default_expense_account_id, :uuid)
      add(:eni_default_inventory_account_id, :uuid)
      add(:eni_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eni_org_id, :uuid, null: false)
      add(:eni_inserted_at, :utc_datetime, null: false)
      add(:eni_updated_at, :utc_datetime, null: false)
    end

    create(index(:eni_item, [:eni_org_id]))
    create(index(:eni_item, [:eni_org_id, :eni_sku], unique: true))

    # ── Warehouse — a stock location with real quantity semantics ─────────
    create table(:enw_warehouse, primary_key: false) do
      add(:enw_code, :text, null: false)
      add(:enw_name, :text, null: false)
      # The per-warehouse NegativeStock opt-out — fail-closed default.
      add(:enw_allow_negative, :boolean, null: false, default: false)
      add(:enw_is_sellable, :boolean, null: false, default: true)
      # Vaulted composite (composite routing convention): opaque vt_* token.
      add(:enw_address, :text)
      add(:enw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:enw_org_id, :uuid, null: false)
      add(:enw_inserted_at, :utc_datetime, null: false)
      add(:enw_updated_at, :utc_datetime, null: false)
    end

    create(index(:enw_warehouse, [:enw_org_id]))
    create(index(:enw_warehouse, [:enw_org_id, :enw_code], unique: true))

    # ── StockLedger — THE append-only movement event ──────────────────────
    create table(:enl_stock_ledger, primary_key: false) do
      add(:enl_kind, :text, null: false)
      add(:enl_qty, :bigint, null: false)
      add(:enl_unit_cost_cents, :bigint, null: false, default: 0)
      add(:enl_source_key, :text)
      add(:enl_source_id, :uuid)
      add(:enl_note, :text)
      add(:enl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:enl_org_id, :uuid, null: false)
      add(:enl_inserted_at, :utc_datetime, null: false)
      add(:enl_updated_at, :utc_datetime, null: false)

      add(
        :enl_item_id,
        references(:eni_item, column: :eni_id, name: "enl_stock_ledger_enl_item_id_fkey", type: :uuid)
      )

      add(
        :enl_warehouse_id,
        references(:enw_warehouse, column: :enw_id, name: "enl_stock_ledger_enl_warehouse_id_fkey", type: :uuid)
      )
    end

    create(index(:enl_stock_ledger, [:enl_org_id]))
    create(index(:enl_stock_ledger, [:enl_item_id]))
    create(index(:enl_stock_ledger, [:enl_warehouse_id]))
    create(index(:enl_stock_ledger, [:enl_org_id, :enl_item_id, :enl_warehouse_id]))

    execute """
            ALTER TABLE enl_stock_ledger
              ADD CONSTRAINT enl_kind_valid CHECK (enl_kind IN
                ('receipt','issue','transfer_out','transfer_in','adjust','sale','production_in','production_consume'))
            """,
            "ALTER TABLE enl_stock_ledger DROP CONSTRAINT enl_kind_valid"

    execute """
            ALTER TABLE enl_stock_ledger
              ADD CONSTRAINT enl_unit_cost_non_negative CHECK (enl_unit_cost_cents >= 0)
            """,
            "ALTER TABLE enl_stock_ledger DROP CONSTRAINT enl_unit_cost_non_negative"

    # APPEND-ONLY at the DB: a stock event is a fact. No UPDATE, no DELETE —
    # corrections are NEW `:adjust` events.
    execute """
            CREATE FUNCTION enl_stock_ledger_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'enl_stock_ledger is append-only: % is refused — a stock event is a '
                'fact; corrections are new :adjust events (event id: %)',
                TG_OP, COALESCE(OLD.enl_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS enl_stock_ledger_enforce_append_only()"

    execute """
            CREATE TRIGGER enl_stock_ledger_append_only_tg
            BEFORE UPDATE OR DELETE ON enl_stock_ledger
            FOR EACH ROW EXECUTE FUNCTION enl_stock_ledger_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS enl_stock_ledger_append_only_tg ON enl_stock_ledger"

    # The NegativeStock floor at the DB: live sum + NEW.qty >= 0 unless the
    # warehouse opts out. `allow IS DISTINCT FROM TRUE` fails CLOSED on a
    # missing warehouse row (a NULL/absent opt-out is never an opt-IN).
    execute """
            CREATE FUNCTION enl_stock_ledger_enforce_negative_stock() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              on_hand bigint;
              allow boolean;
            BEGIN
              SELECT COALESCE(SUM(skl.enl_qty), 0) INTO on_hand
              FROM enl_stock_ledger skl
              WHERE skl.enl_org_id = NEW.enl_org_id
                AND skl.enl_item_id = NEW.enl_item_id
                AND skl.enl_warehouse_id = NEW.enl_warehouse_id;

              SELECT swh.enw_allow_negative INTO allow
              FROM enw_warehouse swh
              WHERE swh.enw_id = NEW.enl_warehouse_id;

              IF allow IS DISTINCT FROM TRUE AND on_hand + NEW.enl_qty < 0 THEN
                RAISE EXCEPTION 'enl_stock_ledger: negative stock refused — the (item, warehouse) '
                  'pair would go to % (floor is 0; the warehouse has not opted out via '
                  'allow_negative). Event qty: %, item: %, warehouse: %',
                  on_hand + NEW.enl_qty, NEW.enl_qty, NEW.enl_item_id, NEW.enl_warehouse_id;
              END IF;

              RETURN NEW;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS enl_stock_ledger_enforce_negative_stock()"

    execute """
            CREATE TRIGGER enl_stock_ledger_negative_stock_tg
            BEFORE INSERT ON enl_stock_ledger
            FOR EACH ROW EXECUTE FUNCTION enl_stock_ledger_enforce_negative_stock()
            """,
            "DROP TRIGGER IF EXISTS enl_stock_ledger_negative_stock_tg ON enl_stock_ledger"

    # ── StockLevel — the derived rollup ───────────────────────────────────
    create table(:ens_stock_level, primary_key: false) do
      add(:ens_qty_on_hand, :bigint, null: false, default: 0)
      add(:ens_qty_on_order, :bigint, null: false, default: 0)
      add(:ens_avg_unit_cost_cents, :bigint)
      add(:ens_stock_value_cents, :bigint, null: false, default: 0)
      add(:ens_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ens_org_id, :uuid, null: false)
      add(:ens_inserted_at, :utc_datetime, null: false)
      add(:ens_updated_at, :utc_datetime, null: false)

      add(
        :ens_item_id,
        references(:eni_item, column: :eni_id, name: "ens_stock_level_ens_item_id_fkey", type: :uuid)
      )

      add(
        :ens_warehouse_id,
        references(:enw_warehouse, column: :enw_id, name: "ens_stock_level_ens_warehouse_id_fkey", type: :uuid)
      )
    end

    create(index(:ens_stock_level, [:ens_org_id]))
    create(index(:ens_stock_level, [:ens_item_id]))
    create(index(:ens_stock_level, [:ens_warehouse_id]))

    create(
      unique_index(:ens_stock_level, [:ens_org_id, :ens_item_id, :ens_warehouse_id],
        name: :ens_stock_level_unique_level
      )
    )

    # The rollup belt: every write needs the transaction-local
    # `samen.stock_sync` marker (only StockLevelSync arms it), and an armed
    # write must MATCH the ledger's own sums — the belt re-derives the truth
    # and refuses divergence. The rollup is derived, never asserted: even a
    # marker-armed hand-edit cannot land a wrong number.
    execute """
            CREATE FUNCTION ens_stock_level_enforce_derived() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(
                current_setting('samen.stock_sync', true) = 'on', false
              );
              on_hand bigint;
              value bigint;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'ens_stock_level: DELETE is refused — the rollup row is derived '
                  'state; it lives and dies with its (item, warehouse) pair. Level id: %',
                  OLD.ens_id;
              END IF;

              IF NOT armed THEN
                RAISE EXCEPTION 'ens_stock_level: write requires the transaction-local sync marker '
                  '(samen.stock_sync) — the rollup is written only by StockLevelSync, inside the '
                  'ledger event''s transaction. Operation: %, level id: %',
                  TG_OP, COALESCE(NEW.ens_id::text, 'n/a');
              END IF;

              SELECT COALESCE(SUM(skl.enl_qty), 0),
                     COALESCE(SUM(skl.enl_qty * skl.enl_unit_cost_cents), 0)
                INTO on_hand, value
              FROM enl_stock_ledger skl
              WHERE skl.enl_org_id = NEW.ens_org_id
                AND skl.enl_item_id = NEW.ens_item_id
                AND skl.enl_warehouse_id = NEW.ens_warehouse_id;

              IF NEW.ens_qty_on_hand IS DISTINCT FROM on_hand
                 OR NEW.ens_stock_value_cents IS DISTINCT FROM value THEN
                RAISE EXCEPTION 'ens_stock_level: the rollup write DIVERGES from the ledger '
                  '(qty: % vs %, value: % vs %) — the rollup is derived from the ledger, '
                  'never asserted over it',
                  NEW.ens_qty_on_hand, on_hand, NEW.ens_stock_value_cents, value;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ens_stock_level_enforce_derived()"

    execute """
            CREATE TRIGGER ens_stock_level_derived_tg
            BEFORE INSERT OR UPDATE OR DELETE ON ens_stock_level
            FOR EACH ROW EXECUTE FUNCTION ens_stock_level_enforce_derived()
            """,
            "DROP TRIGGER IF EXISTS ens_stock_level_derived_tg ON ens_stock_level"


    # ════ Procurement (WS-ERP E4: POs, PO lines, goods receipts, receipt lines) ════
    # ── PurchaseOrder — the SCM document pair's head (posts NOTHING) ───────
    create table(:epo_purchase_order, primary_key: false) do
      add(:epo_vendor_id, :uuid, null: false)
      add(:epo_number, :text, null: false)
      add(:epo_order_date, :date, null: false)
      add(:epo_memo, :text)
      add(:epo_status, :text, null: false, default: "draft")
      add(:epo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epo_org_id, :uuid, null: false)
      add(:epo_inserted_at, :utc_datetime, null: false)
      add(:epo_updated_at, :utc_datetime, null: false)

      add(
        :epo_warehouse_id,
        references(:enw_warehouse, column: :enw_id,
          name: "epo_purchase_order_epo_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:epo_purchase_order, [:epo_org_id]))
    create(index(:epo_purchase_order, [:epo_org_id, :epo_number], unique: true))
    create(index(:epo_purchase_order, [:epo_org_id, :epo_vendor_id]))

    execute """
            ALTER TABLE epo_purchase_order
              ADD CONSTRAINT epo_status_valid CHECK (epo_status IN
                ('draft','approved','sent','received','closed','void'))
            """,
            "ALTER TABLE epo_purchase_order DROP CONSTRAINT epo_status_valid"

    # The PO state machine at the DB (the PoState guard's raw-SQL twin, plus
    # the marker gates the Ash layer cannot express): a PO is born a draft;
    # →approved and →received are marker-gated (the ADR-040 Gate's decision
    # transaction and the :receive chokepoint are the only armed writers —
    # a raw-SQL approval or a raw-SQL receipt stamp cannot land); the host
    # lifecycle moves (→sent/→void/→closed) enforce their pre-states.
    execute """
            CREATE FUNCTION epo_purchase_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.epo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'epo_purchase_order: a PO is born a draft (got %) — the only '
                    'route to any other state is a governed transition (po: %)',
                    NEW.epo_status, NEW.epo_id;
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.epo_status = OLD.epo_status THEN
                RETURN NEW;
              END IF;

              IF NEW.epo_status = 'received' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'epo_purchase_order: →received requires the transaction-local '
                    'posting marker (samen.finance_posting) — a PO is received only inside the '
                    'GoodsReceipt :receive chokepoint (po: %, % → %)',
                    OLD.epo_id, OLD.epo_status, NEW.epo_status;
                END IF;

                IF OLD.epo_status NOT IN ('approved', 'sent') THEN
                  RAISE EXCEPTION 'epo_purchase_order: illegal →received transition from % (po: %)',
                    OLD.epo_status, OLD.epo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.epo_status = 'approved' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'epo_purchase_order: →approved requires the transaction-local '
                    'posting marker (samen.finance_posting) — approval rides the ADR-040 Gate '
                    '(po: %)', OLD.epo_id;
                END IF;

                IF OLD.epo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'epo_purchase_order: illegal →approved transition from % (po: %)',
                    OLD.epo_status, OLD.epo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.epo_status = 'sent' THEN
                IF OLD.epo_status IS DISTINCT FROM 'approved' THEN
                  RAISE EXCEPTION 'epo_purchase_order: illegal →sent transition from % (po: %)',
                    OLD.epo_status, OLD.epo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.epo_status = 'void' THEN
                IF OLD.epo_status NOT IN ('draft', 'approved', 'sent') THEN
                  RAISE EXCEPTION 'epo_purchase_order: illegal →void transition from % — a received '
                    'PO''s realized stock and GL value need a return receipt, not a void (po: %)',
                    OLD.epo_status, OLD.epo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.epo_status = 'closed' THEN
                IF OLD.epo_status IS DISTINCT FROM 'received' THEN
                  RAISE EXCEPTION 'epo_purchase_order: illegal →closed transition from % — only a '
                    'received PO closes (po: %)', OLD.epo_status, OLD.epo_id;
                END IF;

                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'epo_purchase_order: unknown status % (po: %)', NEW.epo_status, OLD.epo_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS epo_purchase_order_enforce_state()"

    execute """
            CREATE TRIGGER epo_purchase_order_enforce_state_tg
            BEFORE INSERT OR UPDATE ON epo_purchase_order
            FOR EACH ROW EXECUTE FUNCTION epo_purchase_order_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS epo_purchase_order_enforce_state_tg ON epo_purchase_order"

    # ── PoLine — the PO's line row (frozen once the PO leaves draft) ───────
    create table(:epl_po_line, primary_key: false) do
      add(:epl_qty, :bigint, null: false)
      add(:epl_unit_cost_cents, :bigint, null: false, default: 0)
      add(:epl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epl_org_id, :uuid, null: false)
      add(:epl_inserted_at, :utc_datetime, null: false)
      add(:epl_updated_at, :utc_datetime, null: false)

      add(
        :epl_purchase_order_id,
        references(:epo_purchase_order, column: :epo_id,
          name: "epl_po_line_epl_purchase_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :epl_item_id,
        references(:eni_item, column: :eni_id,
          name: "epl_po_line_epl_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:epl_po_line, [:epl_org_id]))
    create(index(:epl_po_line, [:epl_purchase_order_id]))
    create(index(:epl_po_line, [:epl_item_id]))

    execute """
            ALTER TABLE epl_po_line
              ADD CONSTRAINT epl_qty_positive CHECK (epl_qty > 0)
            """,
            "ALTER TABLE epl_po_line DROP CONSTRAINT epl_qty_positive"

    execute """
            ALTER TABLE epl_po_line
              ADD CONSTRAINT epl_unit_cost_non_negative CHECK (epl_unit_cost_cents >= 0)
            """,
            "ALTER TABLE epl_po_line DROP CONSTRAINT epl_unit_cost_non_negative"

    # Frozen lines: a PO line is immutable once its PO leaves draft — the
    # receiving quantities reconcile against the order AS ORDERED (R5's
    # ordered side). Draft re-materialization (PoLinesWriter's delete +
    # re-insert) stays open: the parent is still a draft then.
    execute """
            CREATE FUNCTION epl_po_line_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              po_status text;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                SELECT po.epo_status INTO po_status
                FROM epo_purchase_order po WHERE po.epo_id = OLD.epl_purchase_order_id;
              ELSE
                SELECT po.epo_status INTO po_status
                FROM epo_purchase_order po WHERE po.epo_id = NEW.epl_purchase_order_id;
              END IF;

              IF po_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'epl_po_line: % is refused — a PO line is frozen once its PO leaves '
                  'draft (status: %); receiving reconciles against the order AS ORDERED (line: %)',
                  TG_OP, po_status, COALESCE(OLD.epl_id::text, NEW.epl_id::text, 'n/a');
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS epl_po_line_enforce_frozen()"

    execute """
            CREATE TRIGGER epl_po_line_frozen_tg
            BEFORE UPDATE OR DELETE ON epl_po_line
            FOR EACH ROW EXECUTE FUNCTION epl_po_line_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS epl_po_line_frozen_tg ON epl_po_line"

    # ── GoodsReceipt — the ONE-TRANSACTION chokepoint's document ───────────
    create table(:egr_goods_receipt, primary_key: false) do
      add(:egr_number, :text, null: false)
      add(:egr_received_date, :date, null: false)
      add(:egr_memo, :text)
      add(:egr_status, :text, null: false, default: "draft")
      add(:egr_posted_entry_id, :uuid)
      add(:egr_received_at, :utc_datetime)
      add(:egr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:egr_org_id, :uuid, null: false)
      add(:egr_inserted_at, :utc_datetime, null: false)
      add(:egr_updated_at, :utc_datetime, null: false)

      add(
        :egr_purchase_order_id,
        references(:epo_purchase_order, column: :epo_id,
          name: "egr_goods_receipt_egr_purchase_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :egr_warehouse_id,
        references(:enw_warehouse, column: :enw_id,
          name: "egr_goods_receipt_egr_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:egr_goods_receipt, [:egr_org_id]))
    create(index(:egr_goods_receipt, [:egr_org_id, :egr_number], unique: true))
    create(index(:egr_goods_receipt, [:egr_purchase_order_id]))
    create(index(:egr_goods_receipt, [:egr_posted_entry_id]))

    execute """
            ALTER TABLE egr_goods_receipt
              ADD CONSTRAINT egr_status_valid CHECK (egr_status IN ('draft', 'posted'))
            """,
            "ALTER TABLE egr_goods_receipt DROP CONSTRAINT egr_status_valid"

    # The receipt's own state belt: born a draft; draft → posted requires the
    # marker (the :receive chokepoint arms it — exactly-once); posted →
    # anything is refused outright (a posted receipt is a fact).
    execute """
            CREATE FUNCTION egr_goods_receipt_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.egr_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'egr_goods_receipt: a receipt is born a draft (got %) — the only '
                    'route to :posted is the :receive chokepoint (receipt: %)',
                    NEW.egr_status, NEW.egr_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.egr_status = OLD.egr_status THEN
                RETURN NEW;
              END IF;

              IF OLD.egr_status = 'draft' AND NEW.egr_status = 'posted' AND armed THEN
                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'egr_goods_receipt: illegal status transition % → % (marker armed: %) — '
                'a receipt posts exactly once, inside the :receive chokepoint (receipt: %)',
                OLD.egr_status, NEW.egr_status, armed, OLD.egr_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS egr_goods_receipt_enforce_state()"

    execute """
            CREATE TRIGGER egr_goods_receipt_enforce_state_tg
            BEFORE INSERT OR UPDATE ON egr_goods_receipt
            FOR EACH ROW EXECUTE FUNCTION egr_goods_receipt_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS egr_goods_receipt_enforce_state_tg ON egr_goods_receipt"

    # ── ReceiptLine — the materialized received-quantity fact (R5) ─────────
    create table(:erd_receipt_line, primary_key: false) do
      add(:erd_qty, :bigint, null: false)
      add(:erd_unit_cost_cents, :bigint, null: false, default: 0)
      add(:erd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:erd_org_id, :uuid, null: false)
      add(:erd_inserted_at, :utc_datetime, null: false)
      add(:erd_updated_at, :utc_datetime, null: false)

      add(
        :erd_goods_receipt_id,
        references(:egr_goods_receipt, column: :egr_id,
          name: "erd_receipt_line_erd_goods_receipt_id_fkey",
          type: :uuid
        )
      )

      add(
        :erd_po_line_id,
        references(:epl_po_line, column: :epl_id,
          name: "erd_receipt_line_erd_po_line_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:erd_receipt_line, [:erd_org_id]))
    create(index(:erd_receipt_line, [:erd_goods_receipt_id]))
    create(index(:erd_receipt_line, [:erd_po_line_id]))

    execute """
            ALTER TABLE erd_receipt_line
              ADD CONSTRAINT erd_qty_positive CHECK (erd_qty > 0)
            """,
            "ALTER TABLE erd_receipt_line DROP CONSTRAINT erd_qty_positive"

    execute """
            ALTER TABLE erd_receipt_line
              ADD CONSTRAINT erd_unit_cost_non_negative CHECK (erd_unit_cost_cents >= 0)
            """,
            "ALTER TABLE erd_receipt_line DROP CONSTRAINT erd_unit_cost_non_negative"

    # Append-only: a received-quantity fact is written once by the chokepoint
    # (the over-receipt floor and R5's received side read these rows).
    execute """
            CREATE FUNCTION erd_receipt_line_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'erd_receipt_line is append-only: % is refused — a received-quantity '
                'fact is written once by the :receive chokepoint (row: %)',
                TG_OP, COALESCE(OLD.erd_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS erd_receipt_line_enforce_append_only()"

    execute """
            CREATE TRIGGER erd_receipt_line_append_only_tg
            BEFORE UPDATE OR DELETE ON erd_receipt_line
            FOR EACH ROW EXECUTE FUNCTION erd_receipt_line_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS erd_receipt_line_append_only_tg ON erd_receipt_line"


    # ════ Sales bridge (WS-ERP E5: sales orders + SO lines) ════
    # ── SalesOrder — stock's demand document (posts NOTHING until :fulfill) ──
    create table(:eso_sales_order, primary_key: false) do
      add(:eso_customer_id, :uuid, null: false)
      add(:eso_opportunity_id, :uuid)
      add(:eso_number, :text, null: false)
      add(:eso_order_date, :date, null: false)
      add(:eso_memo, :text)
      add(:eso_status, :text, null: false, default: "draft")
      add(:eso_invoice_key, :text)
      add(:eso_invoice_id, :uuid)
      add(:eso_fulfilled_at, :utc_datetime)
      add(:eso_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eso_org_id, :uuid, null: false)
      add(:eso_inserted_at, :utc_datetime, null: false)
      add(:eso_updated_at, :utc_datetime, null: false)

      add(
        :eso_warehouse_id,
        references(:enw_warehouse, column: :enw_id,
          name: "eso_sales_order_eso_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:eso_sales_order, [:eso_org_id]))
    create(index(:eso_sales_order, [:eso_org_id, :eso_number], unique: true))
    create(index(:eso_sales_order, [:eso_org_id, :eso_customer_id]))
    create(index(:eso_sales_order, [:eso_invoice_id]))

    execute """
            ALTER TABLE eso_sales_order
              ADD CONSTRAINT eso_status_valid CHECK (eso_status IN
                ('draft','confirmed','fulfilled','cancelled'))
            """,
            "ALTER TABLE eso_sales_order DROP CONSTRAINT eso_status_valid"

    # The SO state machine at the DB (the SoState guard's raw-SQL twin, plus
    # the marker gate the Ash layer cannot express): born a draft; →fulfilled
    # is marker-gated (the :fulfill bridge is the only armed writer — a
    # raw-SQL fulfillment stamp cannot land); the host lifecycle moves
    # (→confirmed/→cancelled) enforce their pre-states.
    execute """
            CREATE FUNCTION eso_sales_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.eso_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'eso_sales_order: a SO is born a draft (got %) — the only '
                    'route to any other state is a governed transition (so: %)',
                    NEW.eso_status, NEW.eso_id;
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.eso_status = OLD.eso_status THEN
                RETURN NEW;
              END IF;

              IF NEW.eso_status = 'fulfilled' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'eso_sales_order: →fulfilled requires the transaction-local '
                    'posting marker (samen.finance_posting) — a SO fulfills only through the '
                    ':fulfill bridge (so: %, % → %)',
                    OLD.eso_id, OLD.eso_status, NEW.eso_status;
                END IF;

                IF OLD.eso_status IS DISTINCT FROM 'confirmed' THEN
                  RAISE EXCEPTION 'eso_sales_order: illegal →fulfilled transition from % (so: %)',
                    OLD.eso_status, OLD.eso_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.eso_status = 'confirmed' THEN
                IF OLD.eso_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'eso_sales_order: illegal →confirmed transition from % (so: %)',
                    OLD.eso_status, OLD.eso_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.eso_status = 'cancelled' THEN
                IF OLD.eso_status NOT IN ('draft', 'confirmed') THEN
                  RAISE EXCEPTION 'eso_sales_order: illegal →cancelled transition from % — a '
                    'fulfilled SO''s stock and invoice are facts (so: %)',
                    OLD.eso_status, OLD.eso_id;
                END IF;

                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'eso_sales_order: unknown status % (so: %)', NEW.eso_status, OLD.eso_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS eso_sales_order_enforce_state()"

    execute """
            CREATE TRIGGER eso_sales_order_enforce_state_tg
            BEFORE INSERT OR UPDATE ON eso_sales_order
            FOR EACH ROW EXECUTE FUNCTION eso_sales_order_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS eso_sales_order_enforce_state_tg ON eso_sales_order"

    # ── SoLine — the SO's line row (frozen once the SO leaves draft) ───────
    create table(:esl_so_line, primary_key: false) do
      add(:esl_qty, :bigint, null: false)
      add(:esl_unit_price_cents, :bigint, null: false, default: 0)
      add(:esl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esl_org_id, :uuid, null: false)
      add(:esl_inserted_at, :utc_datetime, null: false)
      add(:esl_updated_at, :utc_datetime, null: false)

      add(
        :esl_sales_order_id,
        references(:eso_sales_order, column: :eso_id,
          name: "esl_so_line_esl_sales_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :esl_item_id,
        references(:eni_item, column: :eni_id,
          name: "esl_so_line_esl_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:esl_so_line, [:esl_org_id]))
    create(index(:esl_so_line, [:esl_sales_order_id]))
    create(index(:esl_so_line, [:esl_item_id]))

    execute """
            ALTER TABLE esl_so_line
              ADD CONSTRAINT esl_qty_positive CHECK (esl_qty > 0)
            """,
            "ALTER TABLE esl_so_line DROP CONSTRAINT esl_qty_positive"

    execute """
            ALTER TABLE esl_so_line
              ADD CONSTRAINT esl_unit_price_non_negative CHECK (esl_unit_price_cents >= 0)
            """,
            "ALTER TABLE esl_so_line DROP CONSTRAINT esl_unit_price_non_negative"

    # Frozen lines: a SO line is immutable once its SO leaves draft —
    # fulfillment consumes the order AS ORDERED. Draft re-materialization
    # (SoLinesWriter's delete + re-insert) stays open: the parent is still a
    # draft then.
    execute """
            CREATE FUNCTION esl_so_line_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              so_status text;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                SELECT so.eso_status INTO so_status
                FROM eso_sales_order so WHERE so.eso_id = OLD.esl_sales_order_id;
              ELSE
                SELECT so.eso_status INTO so_status
                FROM eso_sales_order so WHERE so.eso_id = NEW.esl_sales_order_id;
              END IF;

              IF so_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'esl_so_line: % is refused — a SO line is frozen once its SO leaves '
                  'draft (status: %); fulfillment consumes the order AS ORDERED (line: %)',
                  TG_OP, so_status, COALESCE(OLD.esl_id::text, NEW.esl_id::text, 'n/a');
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS esl_so_line_enforce_frozen()"

    execute """
            CREATE TRIGGER esl_so_line_frozen_tg
            BEFORE UPDATE OR DELETE ON esl_so_line
            FOR EACH ROW EXECUTE FUNCTION esl_so_line_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS esl_so_line_frozen_tg ON esl_so_line"

    # ── InvoiceMirror — the E5 emission target (the R2 mirror-leg posture) ──
    create table(:sim_invoice_mirror, primary_key: false) do
      add(:sim_customer_id, :uuid, null: false)

      add(:sim_status, :text, null: false, default: "draft")
      add(:sim_amount_due_cents, :bigint, null: false, default: 0)
      add(:sim_amount_paid_cents, :bigint, null: false, default: 0)
      add(:sim_currency, :text, null: false, default: "USD")
      add(:sim_line_items, :jsonb, null: false, default: "[]")
      add(:sim_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sim_org_id, :uuid, null: false)
      add(:sim_inserted_at, :utc_datetime, null: false)
      add(:sim_updated_at, :utc_datetime, null: false)
    end

    create(index(:sim_invoice_mirror, [:sim_org_id]))
    create(index(:sim_invoice_mirror, [:sim_org_id, :sim_customer_id]))

    execute """
            ALTER TABLE sim_invoice_mirror
              ADD CONSTRAINT sim_status_valid CHECK (sim_status IN
                ('draft','open','paid','void','uncollectible'))
            """,
            "ALTER TABLE sim_invoice_mirror DROP CONSTRAINT sim_status_valid"


    # ════ Manufacturing (WS-ERP E6: BOMs, BOM lines, work orders, production logs) ════
    # ── Bom — the bill of materials (versioned; ONE active per {org, item}) ──
    create table(:ebm_bom, primary_key: false) do
      add(:ebm_version, :integer, null: false)
      add(:ebm_is_active, :boolean, null: false, default: true)
      add(:ebm_name, :text, null: false)
      add(:ebm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ebm_org_id, :uuid, null: false)
      add(:ebm_inserted_at, :utc_datetime, null: false)
      add(:ebm_updated_at, :utc_datetime, null: false)

      add(
        :ebm_item_id,
        references(:eni_item, column: :eni_id,
          name: "ebm_bom_ebm_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ebm_bom, [:ebm_org_id]))
    create(index(:ebm_bom, [:ebm_org_id, :ebm_item_id, :ebm_version], unique: true))

    # ONE ACTIVE version per {org, item} — the blueprint's invariant.
    execute """
            CREATE UNIQUE INDEX ebm_bom_one_active_version_idx
            ON ebm_bom (ebm_org_id, ebm_item_id) WHERE ebm_is_active
            """,
            "DROP INDEX IF EXISTS ebm_bom_one_active_version_idx"

    # ── BomLine — the component row (frozen under an in-flight WO) ─────────
    create table(:ebl_bom_line, primary_key: false) do
      add(:ebl_qty_per, :bigint, null: false)
      add(:ebl_scrap_pct, :integer, null: false, default: 0)
      add(:ebl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ebl_org_id, :uuid, null: false)
      add(:ebl_inserted_at, :utc_datetime, null: false)
      add(:ebl_updated_at, :utc_datetime, null: false)

      add(
        :ebl_bom_id,
        references(:ebm_bom, column: :ebm_id,
          name: "ebl_bom_line_ebl_bom_id_fkey",
          type: :uuid
        )
      )

      add(
        :ebl_item_id,
        references(:eni_item, column: :eni_id,
          name: "ebl_bom_line_ebl_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ebl_bom_line, [:ebl_org_id]))
    create(index(:ebl_bom_line, [:ebl_bom_id]))
    create(index(:ebl_bom_line, [:ebl_item_id]))

    execute """
            ALTER TABLE ebl_bom_line
              ADD CONSTRAINT ebl_qty_per_positive CHECK (ebl_qty_per > 0)
            """,
            "ALTER TABLE ebl_bom_line DROP CONSTRAINT ebl_qty_per_positive"

    execute """
            ALTER TABLE ebl_bom_line
              ADD CONSTRAINT ebl_scrap_pct_bounded
              CHECK (ebl_scrap_pct >= 0 AND ebl_scrap_pct <= 100)
            """,
            "ALTER TABLE ebl_bom_line DROP CONSTRAINT ebl_scrap_pct_bounded"

    # Frozen bill: a BOM's lines are immutable while any released/completed
    # work order references it — R4 reads the bill that produced the facts
    # (new versions, not rewrites). A WO carries its own snapshot, so a
    # BOM with no in-flight orders may re-materialize freely.
    execute """
            CREATE FUNCTION ebl_bom_line_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              in_flight boolean;
              line_id text := COALESCE(OLD.ebl_id::text, NEW.ebl_id::text, 'n/a');
            BEGIN
              SELECT EXISTS (
                SELECT 1 FROM ewo_work_order wo
                WHERE wo.ewo_bom_id = COALESCE(NEW.ebl_bom_id, OLD.ebl_bom_id)
                  AND wo.ewo_status IN ('released', 'completed')
              ) INTO in_flight;

              IF in_flight THEN
                RAISE EXCEPTION 'ebl_bom_line: % is refused — a released/completed work order '
                  'references this BOM; its lines are frozen (new versions, not rewrites) '
                  '(line: %)',
                  TG_OP, line_id;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ebl_bom_line_enforce_frozen()"

    execute """
            CREATE TRIGGER ebl_bom_line_frozen_tg
            BEFORE UPDATE OR DELETE ON ebl_bom_line
            FOR EACH ROW EXECUTE FUNCTION ebl_bom_line_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS ebl_bom_line_frozen_tg ON ebl_bom_line"

    # ── WorkOrder — the manufacturing order (snapshot at release) ──────────
    create table(:ewo_work_order, primary_key: false) do
      add(:ewo_number, :text, null: false)
      add(:ewo_qty, :integer, null: false)
      add(:ewo_scheduled_for, :date)
      add(:ewo_memo, :text)
      add(:ewo_status, :text, null: false, default: "draft")
      add(:ewo_bom_snapshot, :jsonb, null: false, default: "[]")
      add(:ewo_actual_material_cents, :bigint)
      add(:ewo_actual_unit_cost_cents, :bigint)
      add(:ewo_bom_version, :integer)
      add(:ewo_released_at, :utc_datetime)
      add(:ewo_completed_at, :utc_datetime)
      add(:ewo_labor_cents, :bigint, null: false, default: 0)
      add(:ewo_overhead_cents, :bigint, null: false, default: 0)
      add(:ewo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ewo_org_id, :uuid, null: false)
      add(:ewo_inserted_at, :utc_datetime, null: false)
      add(:ewo_updated_at, :utc_datetime, null: false)

      add(
        :ewo_item_id,
        references(:eni_item, column: :eni_id,
          name: "ewo_work_order_ewo_item_id_fkey",
          type: :uuid
        )
      )

      add(
        :ewo_bom_id,
        references(:ebm_bom, column: :ebm_id,
          name: "ewo_work_order_ewo_bom_id_fkey",
          type: :uuid
        )
      )

      add(
        :ewo_warehouse_id,
        references(:enw_warehouse, column: :enw_id,
          name: "ewo_work_order_ewo_warehouse_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:ewo_work_order, [:ewo_org_id]))
    create(index(:ewo_work_order, [:ewo_org_id, :ewo_number], unique: true))
    create(index(:ewo_work_order, [:ewo_org_id, :ewo_item_id]))
    create(index(:ewo_work_order, [:ewo_bom_id]))
    create(index(:ewo_work_order, [:ewo_status]))

    execute """
            ALTER TABLE ewo_work_order
              ADD CONSTRAINT ewo_status_valid CHECK (ewo_status IN
                ('draft','released','completed','cancelled'))
            """,
            "ALTER TABLE ewo_work_order DROP CONSTRAINT ewo_status_valid"

    execute """
            ALTER TABLE ewo_work_order
              ADD CONSTRAINT ewo_qty_positive CHECK (ewo_qty > 0)
            """,
            "ALTER TABLE ewo_work_order DROP CONSTRAINT ewo_qty_positive"

    execute """
            ALTER TABLE ewo_work_order
              ADD CONSTRAINT ewo_costs_non_negative
              CHECK (ewo_labor_cents >= 0 AND ewo_overhead_cents >= 0)
            """,
            "ALTER TABLE ewo_work_order DROP CONSTRAINT ewo_costs_non_negative"

    # The WO state machine at the DB (WoState's raw-SQL twin, plus the
    # marker gates the Ash layer cannot express): born a draft; →released
    # and →completed are marker-gated (the :release/:complete cascades are
    # the only armed writers); →cancelled is refused once completed.
    execute """
            CREATE FUNCTION ewo_work_order_enforce_state() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.ewo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'ewo_work_order: a WO is born a draft (got %) — the only '
                    'route to any other state is a governed transition (wo: %)',
                    NEW.ewo_status, NEW.ewo_id;
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.ewo_status = OLD.ewo_status THEN
                RETURN NEW;
              END IF;

              IF NEW.ewo_status = 'released' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'ewo_work_order: →released requires the transaction-local '
                    'posting marker (samen.finance_posting) — a WO releases only through the '
                    'governed :release action (wo: %, % → %)',
                    OLD.ewo_id, OLD.ewo_status, NEW.ewo_status;
                END IF;

                IF OLD.ewo_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'ewo_work_order: illegal →released transition from % (wo: %)',
                    OLD.ewo_status, OLD.ewo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.ewo_status = 'completed' THEN
                IF NOT armed THEN
                  RAISE EXCEPTION 'ewo_work_order: →completed requires the transaction-local '
                    'posting marker — a WO completes only through the governed :complete '
                    'facade (wo: %, % → %)',
                    OLD.ewo_id, OLD.ewo_status, NEW.ewo_status;
                END IF;

                IF OLD.ewo_status IS DISTINCT FROM 'released' THEN
                  RAISE EXCEPTION 'ewo_work_order: illegal →completed transition from % (wo: %)',
                    OLD.ewo_status, OLD.ewo_id;
                END IF;

                RETURN NEW;
              END IF;

              IF NEW.ewo_status = 'cancelled' THEN
                IF OLD.ewo_status NOT IN ('draft', 'released') THEN
                  RAISE EXCEPTION 'ewo_work_order: illegal →cancelled transition from % — a '
                    'completed WO''s stock facts are facts (wo: %)',
                    OLD.ewo_status, OLD.ewo_id;
                END IF;

                RETURN NEW;
              END IF;

              RAISE EXCEPTION 'ewo_work_order: unknown status % (wo: %)',
                NEW.ewo_status, OLD.ewo_id;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ewo_work_order_enforce_state()"

    execute """
            CREATE TRIGGER ewo_work_order_enforce_state_tg
            BEFORE INSERT OR UPDATE ON ewo_work_order
            FOR EACH ROW EXECUTE FUNCTION ewo_work_order_enforce_state()
            """,
            "DROP TRIGGER IF EXISTS ewo_work_order_enforce_state_tg ON ewo_work_order"

    # A non-draft WO's row is frozen against raw edits (the snapshot is the
    # binding contract — WIP never re-prices): without the marker every
    # column update is refused. The governed cascades (marker-armed) keep
    # writing their flips; the STATE trigger above still enforces legal
    # transitions on top of this freeze.
    execute """
            CREATE FUNCTION ewo_work_order_enforce_frozen() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(current_setting('samen.finance_posting', true) = 'on', false);
            BEGIN
              IF OLD.ewo_status IS DISTINCT FROM 'draft' AND NOT armed THEN
                IF OLD.ewo_status = 'released' AND NEW.ewo_status = 'cancelled' THEN
                  -- The governed :cancel of a released WO posts NOTHING (the
                  -- consumed/produced facts only exist once completed) — no
                  -- marker required; the STATE trigger owns its pre-state.
                  RETURN NEW;
                END IF;

                RAISE EXCEPTION 'ewo_work_order: % is refused — a non-draft WO is frozen (the '
                  'snapshot is the binding contract; raw edits cannot reach WIP) (wo: %)',
                  TG_OP, OLD.ewo_id;
              END IF;

              RETURN NEW;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ewo_work_order_enforce_frozen()"

    execute """
            CREATE TRIGGER ewo_work_order_frozen_tg
            BEFORE UPDATE ON ewo_work_order
            FOR EACH ROW EXECUTE FUNCTION ewo_work_order_enforce_frozen()
            """,
            "DROP TRIGGER IF EXISTS ewo_work_order_frozen_tg ON ewo_work_order"

    # ── ProductionLog — the append-only posting log (the R4 join rows) ─────
    create table(:epg_production_log, primary_key: false) do
      add(:epg_entry_kind, :text, null: false)
      add(:epg_qty, :bigint, null: false)
      add(:epg_unit_cost_cents, :bigint)
      add(:epg_adjustment_cents, :bigint)
      add(:epg_ledger_event_id, :uuid)
      add(:epg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epg_org_id, :uuid, null: false)
      add(:epg_inserted_at, :utc_datetime, null: false)
      add(:epg_updated_at, :utc_datetime, null: false)

      add(
        :epg_work_order_id,
        references(:ewo_work_order, column: :ewo_id,
          name: "epg_production_log_epg_work_order_id_fkey",
          type: :uuid
        )
      )

      add(
        :epg_item_id,
        references(:eni_item, column: :eni_id,
          name: "epg_production_log_epg_item_id_fkey",
          type: :uuid
        )
      )
    end

    create(index(:epg_production_log, [:epg_org_id]))
    create(index(:epg_production_log, [:epg_work_order_id]))
    create(index(:epg_production_log, [:epg_item_id]))
    create(index(:epg_production_log, [:epg_ledger_event_id]))

    execute """
            ALTER TABLE epg_production_log
              ADD CONSTRAINT epg_entry_kind_valid CHECK (epg_entry_kind IN
                ('consume','produce','adjust'))
            """,
            "ALTER TABLE epg_production_log DROP CONSTRAINT epg_entry_kind_valid"

    # Append-only: the posting log is the audit trail of the landed facts —
    # UPDATE/DELETE refused outright (the E4 ReceiptLine shape).
    execute """
            CREATE FUNCTION epg_production_log_enforce_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'epg_production_log: % is refused — the posting log is '
                'append-only (a landed fact is a fact; row: %)',
                TG_OP, COALESCE(OLD.epg_id::text, NEW.epg_id::text, 'n/a');
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS epg_production_log_enforce_append_only()"

    execute """
            CREATE TRIGGER epg_production_log_append_only_tg
            BEFORE UPDATE OR DELETE ON epg_production_log
            FOR EACH ROW EXECUTE FUNCTION epg_production_log_enforce_append_only()
            """,
            "DROP TRIGGER IF EXISTS epg_production_log_append_only_tg ON epg_production_log"


    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # ════ Manufacturing (WS-ERP E6: BOMs, BOM lines, work orders, production logs) (reverse) ════

    drop(table(:epg_production_log))
    execute "DROP TRIGGER IF EXISTS ewo_work_order_frozen_tg ON ewo_work_order"
    execute "DROP FUNCTION IF EXISTS ewo_work_order_enforce_frozen()"
    execute "DROP TRIGGER IF EXISTS ewo_work_order_enforce_state_tg ON ewo_work_order"
    execute "DROP FUNCTION IF EXISTS ewo_work_order_enforce_state()"
    drop(table(:ewo_work_order))
    execute "DROP TRIGGER IF EXISTS ebl_bom_line_frozen_tg ON ebl_bom_line"
    execute "DROP FUNCTION IF EXISTS ebl_bom_line_enforce_frozen()"
    drop(table(:ebl_bom_line))
    execute "DROP INDEX IF EXISTS ebm_bom_one_active_version_idx"
    drop(table(:ebm_bom))

    # ════ Sales bridge (WS-ERP E5: sales orders + SO lines) (reverse) ════

    drop(table(:sim_invoice_mirror))
    execute "DROP TRIGGER IF EXISTS esl_so_line_frozen_tg ON esl_so_line"
    execute "DROP FUNCTION IF EXISTS esl_so_line_enforce_frozen()"
    execute "DROP TRIGGER IF EXISTS eso_sales_order_enforce_state_tg ON eso_sales_order"
    execute "DROP FUNCTION IF EXISTS eso_sales_order_enforce_state()"
    drop(table(:esl_so_line))
    drop(table(:eso_sales_order))

    # ════ Procurement (WS-ERP E4: POs, PO lines, goods receipts, receipt lines) (reverse) ════

    execute "DROP TRIGGER IF EXISTS erd_receipt_line_append_only_tg ON erd_receipt_line"
    execute "DROP FUNCTION IF EXISTS erd_receipt_line_enforce_append_only()"
    execute "DROP TRIGGER IF EXISTS egr_goods_receipt_enforce_state_tg ON egr_goods_receipt"
    execute "DROP FUNCTION IF EXISTS egr_goods_receipt_enforce_state()"
    execute "DROP TRIGGER IF EXISTS epl_po_line_frozen_tg ON epl_po_line"
    execute "DROP FUNCTION IF EXISTS epl_po_line_enforce_frozen()"
    execute "DROP TRIGGER IF EXISTS epo_purchase_order_enforce_state_tg ON epo_purchase_order"
    execute "DROP FUNCTION IF EXISTS epo_purchase_order_enforce_state()"
    drop(table(:erd_receipt_line))
    drop(table(:egr_goods_receipt))
    drop(table(:epl_po_line))
    drop(table(:epo_purchase_order))

    # ════ Inventory core (WS-ERP E3: items, warehouses, the append-only stock ledger + derived level) (reverse) ════

    execute "DROP TRIGGER IF EXISTS ens_stock_level_derived_tg ON ens_stock_level"
    execute "DROP FUNCTION IF EXISTS ens_stock_level_enforce_derived()"
    execute "DROP TRIGGER IF EXISTS enl_stock_ledger_negative_stock_tg ON enl_stock_ledger"
    execute "DROP FUNCTION IF EXISTS enl_stock_ledger_enforce_negative_stock()"
    execute "DROP TRIGGER IF EXISTS enl_stock_ledger_append_only_tg ON enl_stock_ledger"
    execute "DROP FUNCTION IF EXISTS enl_stock_ledger_enforce_append_only()"
    drop(table(:ens_stock_level))
    drop(table(:enl_stock_ledger))
    drop(table(:enw_warehouse))
    drop(table(:eni_item))

    # ════ Finance documents (WS-ERP E2: AP bills, payment receipts, posting accounts) (reverse) ════

    execute "DROP TRIGGER IF EXISTS ecr_payment_receipt_posted_guard_tg ON ecr_payment_receipt"
    execute "DROP FUNCTION IF EXISTS ecr_payment_receipt_enforce_posted_guard()"
    execute "DROP TRIGGER IF EXISTS ecp_ap_invoice_enforce_tg ON ecp_ap_invoice"
    execute "DROP FUNCTION IF EXISTS ecp_ap_invoice_enforce()"
    execute "DROP INDEX IF EXISTS ecr_anchor_unique"

    drop(table(:ecr_payment_receipt))
    drop(table(:ecp_ap_invoice))
    drop(table(:ecf_posting_account))

    # ════ Finance scope (WS-ERP E1: CoA, journal, AP/AR documents, posting accounts, budgets) (reverse) ════

    drop(table(:ecd_budget_line))
    execute "ALTER TABLE ecd_budget_line DROP CONSTRAINT IF EXISTS ecd_planned_non_negative"
    drop(table(:ecb_budget))
    execute "ALTER TABLE ecb_budget DROP CONSTRAINT IF EXISTS ecb_period_valid"
    execute "DROP TRIGGER IF EXISTS ecl_journal_line_append_only_tg ON ecl_journal_line"
    execute "DROP FUNCTION IF EXISTS ecl_journal_line_enforce_append_only()"
    execute "DROP TRIGGER IF EXISTS ecj_journal_entry_posted_immutable_tg ON ecj_journal_entry"
    execute "DROP FUNCTION IF EXISTS ecj_journal_entry_enforce_posted_immutability()"
    drop(table(:ecl_journal_line))
    drop(table(:ecj_journal_entry))
    drop(table(:eca_account))

  end
end
