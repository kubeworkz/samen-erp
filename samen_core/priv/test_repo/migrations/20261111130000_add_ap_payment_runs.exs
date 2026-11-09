defmodule SamenCore.TestRepo.Migrations.AddApPaymentRuns do
  @moduledoc """
  The durable AP payment-run audit table (dual control for cash release).

  A run is born `pending_approval` with its exact bill snapshot. A different
  admin's approval writes the approval evidence and the remittance CSV; a
  rejection or cancellation writes its own evidence. The trigger makes the
  request snapshot immutable, refuses a second decision, refuses a
  self-approval/self-rejection, and refuses every DELETE, so the row is the
  audit trail even below the service. The table is a control table, not an
  Ash/catalog resource: it has no `fld_field` rows and no tenant resource.
  """

  use Samen.Migration

  def up do
    create table(:prn_ap_payment_run, primary_key: false) do
      add(:prn_org_id, :uuid, null: false)
      add(:prn_reference, :text, null: false)
      add(:prn_vendor_id, :uuid, null: false)
      add(:prn_vendor_name, :text)
      add(:prn_remittance_address, :text)
      add(:prn_payment_date, :date, null: false)
      add(:prn_memo, :text)
      add(:prn_status, :text, null: false, default: "pending_approval")
      add(:prn_total_cents, :bigint, null: false, default: 0)
      add(:prn_bill_count, :integer, null: false, default: 0)
      add(:prn_payments, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:prn_remittance_csv, :text)
      add(:prn_requested_by, :text, null: false)
      add(:prn_requested_at, :utc_datetime_usec, null: false)
      add(:prn_approved_by, :text)
      add(:prn_approved_at, :utc_datetime_usec)
      add(:prn_executed_at, :utc_datetime_usec)
      add(:prn_rejected_by, :text)
      add(:prn_rejected_at, :utc_datetime_usec)
      add(:prn_cancelled_by, :text)
      add(:prn_cancelled_at, :utc_datetime_usec)
      add(:prn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:prn_inserted_at, :utc_datetime_usec, null: false)
      add(:prn_updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:prn_ap_payment_run, [:prn_org_id, :prn_reference],
        name: :prn_ap_payment_run_org_reference_index
      )
    )

    create(index(:prn_ap_payment_run, [:prn_org_id, :prn_status]))
    create(index(:prn_ap_payment_run, [:prn_org_id, :prn_inserted_at]))

    create(
      constraint(:prn_ap_payment_run, :prn_status_valid,
        check: "prn_status IN ('pending_approval','paid','rejected','cancelled')"
      )
    )

    create(
      constraint(:prn_ap_payment_run, :prn_amounts_valid,
        check:
          "prn_total_cents > 0 AND prn_bill_count > 0 AND " <>
            "jsonb_typeof(prn_payments) = 'array' AND " <>
            "jsonb_array_length(prn_payments) > 0 AND " <>
            "jsonb_array_length(prn_payments) = prn_bill_count"
      )
    )

    create(
      constraint(:prn_ap_payment_run, :prn_requested_by_present,
        check: "prn_requested_by <> '' AND prn_approved_by IS DISTINCT FROM prn_requested_by"
      )
    )

    create(
      constraint(:prn_ap_payment_run, :prn_rejected_by_present,
        check: "prn_rejected_by IS DISTINCT FROM prn_requested_by"
      )
    )

    execute(
      """
      CREATE OR REPLACE FUNCTION prn_ap_payment_run_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'prn_ap_payment_run: payment runs are audit records and are never deleted';
        END IF;

        IF TG_OP = 'INSERT' THEN
          IF NEW.prn_status IS DISTINCT FROM 'pending_approval' THEN
            RAISE EXCEPTION 'prn_ap_payment_run: a run is born pending_approval';
          END IF;

          IF NEW.prn_approved_by IS NOT NULL OR NEW.prn_approved_at IS NOT NULL
             OR NEW.prn_executed_at IS NOT NULL OR NEW.prn_remittance_csv IS NOT NULL
             OR NEW.prn_rejected_by IS NOT NULL OR NEW.prn_rejected_at IS NOT NULL
             OR NEW.prn_cancelled_by IS NOT NULL OR NEW.prn_cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION 'prn_ap_payment_run: decision evidence is written only by a decision';
          END IF;

          RETURN NEW;
        END IF;

        -- UPDATE: a decided run is a closed audit record.
        IF OLD.prn_status IS DISTINCT FROM 'pending_approval' THEN
          RAISE EXCEPTION 'prn_ap_payment_run: a decided run is immutable (id %, status %)',
            OLD.prn_id, OLD.prn_status;
        END IF;

        IF NEW.prn_id IS DISTINCT FROM OLD.prn_id
           OR NEW.prn_inserted_at IS DISTINCT FROM OLD.prn_inserted_at
           OR NEW.prn_requested_by IS DISTINCT FROM OLD.prn_requested_by
           OR NEW.prn_requested_at IS DISTINCT FROM OLD.prn_requested_at
           OR NEW.prn_reference IS DISTINCT FROM OLD.prn_reference
           OR NEW.prn_vendor_id IS DISTINCT FROM OLD.prn_vendor_id
           OR NEW.prn_vendor_name IS DISTINCT FROM OLD.prn_vendor_name
           OR NEW.prn_remittance_address IS DISTINCT FROM OLD.prn_remittance_address
           OR NEW.prn_payment_date IS DISTINCT FROM OLD.prn_payment_date
           OR NEW.prn_memo IS DISTINCT FROM OLD.prn_memo
           OR NEW.prn_total_cents IS DISTINCT FROM OLD.prn_total_cents
           OR NEW.prn_bill_count IS DISTINCT FROM OLD.prn_bill_count
           OR NEW.prn_payments IS DISTINCT FROM OLD.prn_payments THEN
          RAISE EXCEPTION 'prn_ap_payment_run: the requested run snapshot is immutable';
        END IF;

        IF NEW.prn_status = 'paid' THEN
          IF NEW.prn_approved_by IS NULL OR NEW.prn_approved_by = NEW.prn_requested_by
             OR NEW.prn_approved_at IS NULL OR NEW.prn_executed_at IS NULL
             OR NEW.prn_remittance_csv IS NULL
             OR NEW.prn_rejected_by IS NOT NULL OR NEW.prn_rejected_at IS NOT NULL
             OR NEW.prn_cancelled_by IS NOT NULL OR NEW.prn_cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION
              'prn_ap_payment_run: a paid run needs a distinct approver and execution evidence';
          END IF;
        ELSIF NEW.prn_status = 'rejected' THEN
          IF NEW.prn_rejected_by IS NULL OR NEW.prn_rejected_by = NEW.prn_requested_by
             OR NEW.prn_rejected_at IS NULL
             OR NEW.prn_approved_by IS NOT NULL OR NEW.prn_approved_at IS NOT NULL
             OR NEW.prn_executed_at IS NOT NULL OR NEW.prn_remittance_csv IS NOT NULL
             OR NEW.prn_cancelled_by IS NOT NULL OR NEW.prn_cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION
              'prn_ap_payment_run: a rejected run needs a distinct rejecter and timestamp';
          END IF;
        ELSIF NEW.prn_status = 'cancelled' THEN
          IF NEW.prn_cancelled_by IS NULL OR NEW.prn_cancelled_by <> NEW.prn_requested_by
             OR NEW.prn_cancelled_at IS NULL
             OR NEW.prn_approved_by IS NOT NULL OR NEW.prn_approved_at IS NOT NULL
             OR NEW.prn_executed_at IS NOT NULL OR NEW.prn_remittance_csv IS NOT NULL
             OR NEW.prn_rejected_by IS NOT NULL OR NEW.prn_rejected_at IS NOT NULL THEN
            RAISE EXCEPTION
              'prn_ap_payment_run: only the requester may cancel a pending run';
          END IF;
        ELSE
          RAISE EXCEPTION
            'prn_ap_payment_run: a pending run may only move to paid, rejected, or cancelled';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS prn_ap_payment_run_guard()"
    )

    execute(
      """
      CREATE TRIGGER prn_ap_payment_run_guard
      BEFORE INSERT OR UPDATE OR DELETE ON prn_ap_payment_run
      FOR EACH ROW EXECUTE FUNCTION prn_ap_payment_run_guard()
      """,
      "DROP TRIGGER IF EXISTS prn_ap_payment_run_guard ON prn_ap_payment_run"
    )
  end

  def down do
    drop(table(:prn_ap_payment_run))
    execute("DROP FUNCTION IF EXISTS prn_ap_payment_run_guard()")
  end
end
