defmodule Samenerp.Repo.Migrations.AddApPaymentArtifactsAndReversals do
  @moduledoc """
  Durable ACH artifacts and dual-controlled payment-run reversals.

  `ach_ap_payment_ach_file` stores one generated NACHA file per row. The file
  bytes contain the receiver's account/routing numbers, so `ach_file_token` is a
  `Samen.Vault` token and the trigger refuses anything else. Rows are immutable
  and undeletable; a run may have several artifacts (for example a regeneration
  with different originator details).

  `prv_ap_payment_reversal` is the compensating fact for a paid run. One row per
  run, born `pending_approval`, decided by a different admin, with the run
  snapshot frozen on the row. Approval voids the `ap_payment` entries and
  returns the bills to `approved`; the trigger refuses a rewritten request, a
  self-approval, a second decision and every DELETE.
  """

  use Samen.Migration

  def up do
    create table(:ach_ap_payment_ach_file, primary_key: false) do
      add(:ach_org_id, :uuid, null: false)
      add(:ach_run_id, :uuid, null: false)
      add(:ach_name, :text, null: false)
      add(:ach_digest, :text, null: false)
      # 🔒 Vault token only; the trigger refuses anything that is not vt_*.
      add(:ach_file_token, :text, null: false)
      add(:ach_size_bytes, :bigint, null: false)
      add(:ach_originator_name, :text)
      add(:ach_originator_id, :text)
      add(:ach_originator_dfi_last4, :text)
      add(:ach_receiver_name, :text)
      add(:ach_receiver_account_last4, :text)
      add(:ach_receiver_routing_last4, :text)
      add(:ach_generated_by, :text, null: false)
      add(:ach_generated_at, :utc_datetime_usec, null: false)
      add(:ach_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ach_inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:ach_ap_payment_ach_file, [:ach_org_id, :ach_run_id]))
    create(index(:ach_ap_payment_ach_file, [:ach_org_id, :ach_inserted_at]))

    create(
      constraint(:ach_ap_payment_ach_file, :ach_token_vault,
        check: "left(ach_file_token, 3) = 'vt_'"
      )
    )

    create(
      constraint(:ach_ap_payment_ach_file, :ach_digest_shape,
        check: "ach_digest ~ '^[0-9a-f]{64}$'"
      )
    )

    create(
      constraint(:ach_ap_payment_ach_file, :ach_size_positive,
        check: "ach_size_bytes > 0"
      )
    )

    execute(
      """
      CREATE OR REPLACE FUNCTION ach_ap_payment_ach_file_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'ach_ap_payment_ach_file: ACH artifacts are audit records and are never deleted';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          RAISE EXCEPTION 'ach_ap_payment_ach_file: an ACH artifact is immutable';
        END IF;

        IF left(NEW.ach_file_token, 3) <> 'vt_' THEN
          RAISE EXCEPTION 'ach_ap_payment_ach_file: the file must be stored as a vault token';
        END IF;

        IF NEW.ach_generated_by IS NULL OR NEW.ach_generated_by = '' THEN
          RAISE EXCEPTION 'ach_ap_payment_ach_file: generated_by is required';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS ach_ap_payment_ach_file_guard()"
    )

    execute(
      """
      CREATE TRIGGER ach_ap_payment_ach_file_guard
      BEFORE INSERT OR UPDATE OR DELETE ON ach_ap_payment_ach_file
      FOR EACH ROW EXECUTE FUNCTION ach_ap_payment_ach_file_guard()
      """,
      "DROP TRIGGER IF EXISTS ach_ap_payment_ach_file_guard ON ach_ap_payment_ach_file"
    )

    create table(:prv_ap_payment_reversal, primary_key: false) do
      add(:prv_org_id, :uuid, null: false)
      add(:prv_run_id, :uuid, null: false)
      add(:prv_reason, :text, null: false)
      add(:prv_status, :text, null: false, default: "pending_approval")
      add(:prv_total_cents, :bigint, null: false, default: 0)
      add(:prv_bill_count, :integer, null: false, default: 0)
      add(:prv_payments, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:prv_requested_by, :text, null: false)
      add(:prv_requested_at, :utc_datetime_usec, null: false)
      add(:prv_approved_by, :text)
      add(:prv_approved_at, :utc_datetime_usec)
      add(:prv_executed_at, :utc_datetime_usec)
      add(:prv_rejected_by, :text)
      add(:prv_rejected_at, :utc_datetime_usec)
      add(:prv_cancelled_by, :text)
      add(:prv_cancelled_at, :utc_datetime_usec)
      add(:prv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:prv_inserted_at, :utc_datetime_usec, null: false)
      add(:prv_updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:prv_ap_payment_reversal, [:prv_org_id, :prv_run_id],
        name: :prv_ap_payment_reversal_org_run_index
      )
    )

    create(index(:prv_ap_payment_reversal, [:prv_org_id, :prv_status]))
    create(index(:prv_ap_payment_reversal, [:prv_org_id, :prv_inserted_at]))

    create(
      constraint(:prv_ap_payment_reversal, :prv_status_valid,
        check: "prv_status IN ('pending_approval','reversed','rejected','cancelled')"
      )
    )

    create(
      constraint(:prv_ap_payment_reversal, :prv_amounts_valid,
        check:
          "prv_total_cents > 0 AND prv_bill_count > 0 AND " <>
            "jsonb_typeof(prv_payments) = 'array' AND " <>
            "jsonb_array_length(prv_payments) > 0 AND " <>
            "jsonb_array_length(prv_payments) = prv_bill_count"
      )
    )

    create(
      constraint(:prv_ap_payment_reversal, :prv_reason_present,
        check: "length(btrim(prv_reason)) > 0"
      )
    )

    create(
      constraint(:prv_ap_payment_reversal, :prv_requested_by_present,
        check: "prv_requested_by <> '' AND prv_approved_by IS DISTINCT FROM prv_requested_by"
      )
    )

    execute(
      """
      CREATE OR REPLACE FUNCTION prv_ap_payment_reversal_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'prv_ap_payment_reversal: reversals are audit records and are never deleted';
        END IF;

        IF TG_OP = 'INSERT' THEN
          IF NEW.prv_status IS DISTINCT FROM 'pending_approval' THEN
            RAISE EXCEPTION 'prv_ap_payment_reversal: a reversal is born pending_approval';
          END IF;

          IF NEW.prv_approved_by IS NOT NULL OR NEW.prv_approved_at IS NOT NULL
             OR NEW.prv_executed_at IS NOT NULL
             OR NEW.prv_rejected_by IS NOT NULL OR NEW.prv_rejected_at IS NOT NULL
             OR NEW.prv_cancelled_by IS NOT NULL OR NEW.prv_cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION 'prv_ap_payment_reversal: decision evidence is written only by a decision';
          END IF;

          RETURN NEW;
        END IF;

        IF OLD.prv_status IS DISTINCT FROM 'pending_approval' THEN
          RAISE EXCEPTION 'prv_ap_payment_reversal: a decided reversal is immutable (id %, status %)',
            OLD.prv_id, OLD.prv_status;
        END IF;

        IF NEW.prv_id IS DISTINCT FROM OLD.prv_id
           OR NEW.prv_org_id IS DISTINCT FROM OLD.prv_org_id
           OR NEW.prv_run_id IS DISTINCT FROM OLD.prv_run_id
           OR NEW.prv_reason IS DISTINCT FROM OLD.prv_reason
           OR NEW.prv_total_cents IS DISTINCT FROM OLD.prv_total_cents
           OR NEW.prv_bill_count IS DISTINCT FROM OLD.prv_bill_count
           OR NEW.prv_payments IS DISTINCT FROM OLD.prv_payments
           OR NEW.prv_requested_by IS DISTINCT FROM OLD.prv_requested_by
           OR NEW.prv_requested_at IS DISTINCT FROM OLD.prv_requested_at
           OR NEW.prv_inserted_at IS DISTINCT FROM OLD.prv_inserted_at THEN
          RAISE EXCEPTION 'prv_ap_payment_reversal: the requested reversal snapshot is immutable';
        END IF;

        IF NEW.prv_status = 'reversed' THEN
          IF NEW.prv_approved_by IS NULL OR NEW.prv_approved_by = NEW.prv_requested_by
             OR NEW.prv_approved_at IS NULL OR NEW.prv_executed_at IS NULL
             OR NEW.prv_rejected_by IS NOT NULL OR NEW.prv_rejected_at IS NOT NULL
             OR NEW.prv_cancelled_by IS NOT NULL OR NEW.prv_cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION
              'prv_ap_payment_reversal: a reversed run needs a distinct approver and execution evidence';
          END IF;
        ELSIF NEW.prv_status = 'rejected' THEN
          IF NEW.prv_rejected_by IS NULL OR NEW.prv_rejected_by = NEW.prv_requested_by
             OR NEW.prv_rejected_at IS NULL
             OR NEW.prv_approved_by IS NOT NULL OR NEW.prv_approved_at IS NOT NULL
             OR NEW.prv_executed_at IS NOT NULL
             OR NEW.prv_cancelled_by IS NOT NULL OR NEW.prv_cancelled_at IS NOT NULL THEN
            RAISE EXCEPTION
              'prv_ap_payment_reversal: a rejected reversal needs a distinct rejecter and timestamp';
          END IF;
        ELSIF NEW.prv_status = 'cancelled' THEN
          IF NEW.prv_cancelled_by IS NULL OR NEW.prv_cancelled_by <> NEW.prv_requested_by
             OR NEW.prv_cancelled_at IS NULL
             OR NEW.prv_approved_by IS NOT NULL OR NEW.prv_approved_at IS NOT NULL
             OR NEW.prv_executed_at IS NOT NULL
             OR NEW.prv_rejected_by IS NOT NULL OR NEW.prv_rejected_at IS NOT NULL THEN
            RAISE EXCEPTION
              'prv_ap_payment_reversal: only the requester may cancel a pending reversal';
          END IF;
        ELSE
          RAISE EXCEPTION
            'prv_ap_payment_reversal: a pending reversal may only move to reversed, rejected, or cancelled';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS prv_ap_payment_reversal_guard()"
    )

    execute(
      """
      CREATE TRIGGER prv_ap_payment_reversal_guard
      BEFORE INSERT OR UPDATE OR DELETE ON prv_ap_payment_reversal
      FOR EACH ROW EXECUTE FUNCTION prv_ap_payment_reversal_guard()
      """,
      "DROP TRIGGER IF EXISTS prv_ap_payment_reversal_guard ON prv_ap_payment_reversal"
    )
  end

  def down do
    drop(table(:prv_ap_payment_reversal))
    execute("DROP FUNCTION IF EXISTS prv_ap_payment_reversal_guard()")
    drop(table(:ach_ap_payment_ach_file))
    execute("DROP FUNCTION IF EXISTS ach_ap_payment_ach_file_guard()")
  end
end
