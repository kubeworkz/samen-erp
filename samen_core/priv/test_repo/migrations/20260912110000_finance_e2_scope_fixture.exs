defmodule SamenCore.TestRepo.Migrations.FinanceE2ScopeFixture do
  @moduledoc """
  Tables + DB belts for the Finance scope's E2 documents (WS-ERP E2; ADR-049
  §2): `fav_posting_account` + `sap_ap_invoice` + `prc_payment_receipt` + the
  R2 mirror leg `sbp_payment_mirror`, mounted in `samen_core` tests via
  `test/support/finance_fixture.ex`. DB belts (belt over the Ash-side braces):

    * the unique index on `{fav_org_id, fav_key}` — one posting account per
      `{org, key}`: a re-point is an UPDATE of `fav_account_id`, never a
      duplicate row (the PostingAccount doc's contract).
    * `sap_status_valid` + `prc_status_valid` + `sbp_status_valid` CHECKs —
      the status enums at the DB layer.
    * `sap_ap_invoice_enforce_tg` — every AP line amount is a positive
      integer and a bill carries at least one line (a CHECK cannot hold the
      subquery, so the trigger owns the shape — `ApLines`' belt; credits are
      separate bills), PLUS the approved-bill immutability arm.
    * `prc_amount_positive` — a receipt's amount is a positive integer.
    * `sbp_amount_non_negative` — a mirror payment never carries a negative
      amount.
    * `sap_ap_invoice_approved_immutable_tg` — the approved-bill belt:
      DELETE of a non-draft bill is refused outright (AP bills are business
      records); UPDATE of a non-draft bill is refused unless the
      transaction-local `samen.finance_posting` marker is set (only the
      marker-armed `:approve` transition may flip draft → approved — the
      Gate's re-invocation). A raw-SQL approved bill is structurally
      impossible.
    * `prc_payment_receipt_posted_guard_tg` — the receipt belt: INSERT of a
      non-draft receipt and UPDATE/DELETE of a posted receipt are refused
      unless the same marker is present (only `:post_receipt`'s
      marker-armed flip is sanctioned).
    * `prc_anchor_unique` — partial unique index on
      `{org, invoice_key, invoice_id}` `WHERE status = 'posted'`: a receipt
      for one upstream invoice event posts EXACTLY ONCE (the DB half of the
      exactly-once contract; the Ash half is ReceiptPosting's in-transaction
      status re-check).

  The entry/line tables keep E1's own belts (this migration adds none there —
  the E2 posting cascades ride the marker-armed `:create_reversal` factory,
  which the E1 triggers already sanction). Catalog rows are written by
  `catalog_sync/1` in the SAME transaction (ADR-004), over all SEVEN fixture
  resources.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.Account,
    SamenCore.Support.FinanceFixture.JournalEntry,
    SamenCore.Support.FinanceFixture.JournalLine,
    SamenCore.Support.FinanceFixture.ApInvoice,
    SamenCore.Support.FinanceFixture.PaymentReceipt,
    SamenCore.Support.FinanceFixture.PostingAccount,
    SamenCore.Support.FinanceFixture.PaymentMirror
  ]

  def up do
    # ── PostingAccount — the named GL posting accounts ──────────────────────
    create table(:fav_posting_account, primary_key: false) do
      add(:fav_key, :text, null: false)
      add(:fav_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fav_org_id, :uuid, null: false)
      add(:fav_inserted_at, :utc_datetime, null: false)
      add(:fav_updated_at, :utc_datetime, null: false)

      add(
        :fav_account_id,
        references(:sac_account, column: :sac_id, name: "fav_posting_account_fav_account_id_fkey", type: :uuid)
      )
    end

    create(index(:fav_posting_account, [:fav_org_id]))
    create(index(:fav_posting_account, [:fav_account_id]))

    create(index(:fav_posting_account, [:fav_org_id, :fav_key], unique: true))

    # ── ApInvoice — the AP vendor bill ──────────────────────────────────────
    create table(:sap_ap_invoice, primary_key: false) do
      add(:sap_vendor_id, :uuid, null: false)
      add(:sap_number, :text, null: false)
      add(:sap_bill_date, :date, null: false)
      add(:sap_due_date, :date)
      add(:sap_memo, :text)
      add(:sap_lines, :map, null: false)
      add(:sap_status, :text, null: false, default: "draft")
      add(:sap_posted_entry_id, :uuid)
      add(:sap_posted_at, :utc_datetime)
      add(:sap_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sap_org_id, :uuid, null: false)
      add(:sap_inserted_at, :utc_datetime, null: false)
      add(:sap_updated_at, :utc_datetime, null: false)
    end

    create(index(:sap_ap_invoice, [:sap_org_id]))
    create(index(:sap_ap_invoice, [:sap_vendor_id]))
    create(index(:sap_ap_invoice, [:sap_org_id, :sap_number], unique: true))

    execute """
            ALTER TABLE sap_ap_invoice
              ADD CONSTRAINT sap_status_valid CHECK (sap_status IN ('draft','approved','paid','void'))
            """,
            "ALTER TABLE sap_ap_invoice DROP CONSTRAINT sap_status_valid"

    execute """
            CREATE FUNCTION sap_ap_invoice_enforce() RETURNS trigger LANGUAGE plpgsql AS $$
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
                IF jsonb_typeof(NEW.sap_lines) IS DISTINCT FROM 'array'
                   OR jsonb_array_length(NEW.sap_lines) = 0 THEN
                  RAISE EXCEPTION 'sap_ap_invoice: an AP bill carries at least one line '
                    '(lines: %)', NEW.sap_lines;
                END IF;

                FOR line IN SELECT * FROM jsonb_array_elements(NEW.sap_lines) LOOP
                  IF line->'amount_cents' IS NULL
                     OR jsonb_typeof(line->'amount_cents') <> 'number'
                     OR (line->>'amount_cents')::numeric <= 0 THEN
                    RAISE EXCEPTION 'sap_ap_invoice: every AP line amount_cents must be a '
                      'positive integer (credits are separate bills) — line: %', line;
                  END IF;
                END LOOP;
              END IF;

              IF TG_OP = 'DELETE' THEN
                IF OLD.sap_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'sap_ap_invoice: DELETE of a non-draft bill is refused — '
                    'an AP bill is a business record; voiding is the P2 credit-note carry. '
                    'Bill id: %', OLD.sap_id;
                END IF;
              ELSE
                -- The UPDATE arm keys on BOTH sides: a draft->approved
                -- TRANSITION carries the new state in NEW (a raw-SQL approval
                -- is refused), and any edit of an already-non-draft row dies
                -- with it. Draft->draft field edits stay free. (UPDATE only —
                -- on INSERT OLD is all-NULL and IS DISTINCT FROM 'draft' is
                -- vacuously TRUE, which would refuse every legal create.)
                IF TG_OP = 'UPDATE' AND (NEW.sap_status IS DISTINCT FROM 'draft'
                    OR OLD.sap_status IS DISTINCT FROM 'draft') AND NOT armed THEN
                  RAISE EXCEPTION 'sap_ap_invoice: UPDATE onto or away from a non-draft '
                    'state requires the transaction-local marker (samen.finance_posting) '
                    '— only the marker-armed :approve transition flips draft to approved. '
                    'Bill id: %, old status: %, new status: %',
                    OLD.sap_id, OLD.sap_status, NEW.sap_status;
                END IF;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS sap_ap_invoice_enforce_approved_immutability()"

    execute """
            CREATE TRIGGER sap_ap_invoice_enforce_tg
            BEFORE INSERT OR UPDATE OR DELETE ON sap_ap_invoice
            FOR EACH ROW EXECUTE FUNCTION sap_ap_invoice_enforce()
            """,
            "DROP TRIGGER IF EXISTS sap_ap_invoice_enforce_tg ON sap_ap_invoice"

    # ── PaymentReceipt — the AR intake ──────────────────────────────────────
    create table(:prc_payment_receipt, primary_key: false) do
      add(:prc_invoice_key, :text, null: false)
      add(:prc_invoice_id, :uuid, null: false)
      add(:prc_amount_cents, :bigint, null: false)
      add(:prc_currency, :text, null: false, default: "USD")
      add(:prc_paid_at, :utc_datetime, null: false)
      add(:prc_memo, :text)
      add(:prc_status, :text, null: false, default: "draft")
      add(:prc_posted_entry_id, :uuid)
      add(:prc_posted_at, :utc_datetime)
      add(:prc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:prc_org_id, :uuid, null: false)
      add(:prc_inserted_at, :utc_datetime, null: false)
      add(:prc_updated_at, :utc_datetime, null: false)
    end

    create(index(:prc_payment_receipt, [:prc_org_id]))
    create(index(:prc_payment_receipt, [:prc_org_id, :prc_invoice_key, :prc_invoice_id]))

    execute """
            CREATE UNIQUE INDEX prc_anchor_unique ON prc_payment_receipt (prc_org_id, prc_invoice_key, prc_invoice_id)
            WHERE prc_status = 'posted'
            """,
            "DROP INDEX IF EXISTS prc_anchor_unique"

    execute """
            ALTER TABLE prc_payment_receipt
              ADD CONSTRAINT prc_status_valid CHECK (prc_status IN ('draft','posted'))
            """,
            "ALTER TABLE prc_payment_receipt DROP CONSTRAINT prc_status_valid"

    execute """
            ALTER TABLE prc_payment_receipt
              ADD CONSTRAINT prc_amount_positive CHECK (prc_amount_cents > 0)
            """,
            "ALTER TABLE prc_payment_receipt DROP CONSTRAINT prc_amount_positive"

    execute """
            CREATE FUNCTION prc_payment_receipt_enforce_posted_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE
              armed boolean := COALESCE(
                current_setting('samen.finance_posting', true) = 'on', false
              );
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.prc_status IS DISTINCT FROM 'draft' AND NOT armed THEN
                  RAISE EXCEPTION 'prc_payment_receipt: INSERT of a non-draft receipt '
                    'requires the transaction-local marker (samen.finance_posting) — a '
                    'posted receipt is a fact, landed only by :post_receipt. '
                    'Receipt id: %', NEW.prc_id;
                END IF;
              END IF;

              IF TG_OP = 'UPDATE' THEN
                -- Keyed on BOTH sides: the draft->posted TRANSITION carries the
                -- new state in NEW (a raw-SQL posting is refused), and any edit
                -- of a posted row dies with it. Draft->draft edits stay free.
                IF (NEW.prc_status IS DISTINCT FROM 'draft'
                    OR OLD.prc_status IS DISTINCT FROM 'draft') AND NOT armed THEN
                  RAISE EXCEPTION 'prc_payment_receipt: UPDATE onto or away from a posted '
                    'state requires the transaction-local marker (samen.finance_posting) '
                    '— only the marker-armed :post_receipt flips draft to posted. '
                    'Receipt id: %, old status: %, new status: %',
                    OLD.prc_id, OLD.prc_status, NEW.prc_status;
                END IF;
              END IF;

              IF TG_OP = 'DELETE' THEN
                IF OLD.prc_status IS DISTINCT FROM 'draft' THEN
                  RAISE EXCEPTION 'prc_payment_receipt: DELETE of a posted receipt is '
                    'refused outright — a posted receipt is a fact; receipts are not '
                    'destroyed. Receipt id: %', OLD.prc_id;
                END IF;
              END IF;

              RETURN COALESCE(NEW, OLD);
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS prc_payment_receipt_enforce_posted_guard()"

    execute """
            CREATE TRIGGER prc_payment_receipt_posted_guard_tg
            BEFORE INSERT OR UPDATE OR DELETE ON prc_payment_receipt
            FOR EACH ROW EXECUTE FUNCTION prc_payment_receipt_enforce_posted_guard()
            """,
            "DROP TRIGGER IF EXISTS prc_payment_receipt_posted_guard_tg ON prc_payment_receipt"

    # ── PaymentMirror — the R2 Billing-shaped mirror leg ────────────────────
    create table(:sbp_payment_mirror, primary_key: false) do
      add(:sbp_amount_cents, :bigint, null: false)
      add(:sbp_status, :text, null: false, default: "pending")
      add(:sbp_currency, :text, null: false, default: "USD")
      add(:sbp_paid_at, :utc_datetime)
      add(:sbp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sbp_org_id, :uuid, null: false)
      add(:sbp_inserted_at, :utc_datetime, null: false)
      add(:sbp_updated_at, :utc_datetime, null: false)
    end

    create(index(:sbp_payment_mirror, [:sbp_org_id]))

    execute """
            ALTER TABLE sbp_payment_mirror
              ADD CONSTRAINT sbp_status_valid
              CHECK (sbp_status IN ('pending','succeeded','failed','cancelled'))
            """,
            "ALTER TABLE sbp_payment_mirror DROP CONSTRAINT sbp_status_valid"

    execute """
            ALTER TABLE sbp_payment_mirror
              ADD CONSTRAINT sbp_amount_non_negative CHECK (sbp_amount_cents >= 0)
            """,
            "ALTER TABLE sbp_payment_mirror DROP CONSTRAINT sbp_amount_non_negative"

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute "DROP TRIGGER IF EXISTS prc_payment_receipt_posted_guard_tg ON prc_payment_receipt"
    execute "DROP FUNCTION IF EXISTS prc_payment_receipt_enforce_posted_guard()"
    execute "DROP TRIGGER IF EXISTS sap_ap_invoice_enforce_tg ON sap_ap_invoice"
    execute "DROP FUNCTION IF EXISTS sap_ap_invoice_enforce()"
    execute "DROP INDEX IF EXISTS prc_anchor_unique"

    drop(table(:sbp_payment_mirror))
    drop(table(:prc_payment_receipt))
    drop(table(:sap_ap_invoice))
    drop(table(:fav_posting_account))
  end
end
