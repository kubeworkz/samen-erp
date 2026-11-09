defmodule Samenerp.Repo.Migrations.AddVendorPaymentProfiles do
  @moduledoc """
  The durable vendor payment profile (bank details + verification evidence).
  See the kernel test-repo migration of the same name for the control model.
  """

  use Samen.Migration

  def up do
    create table(:fvp_vendor_payment_profile, primary_key: false) do
      add(:fvp_org_id, :uuid, null: false)
      add(:fvp_vendor_id, :uuid, null: false)
      add(:fvp_bank_name, :text)
      add(:fvp_account_holder, :text, null: false)
      add(:fvp_account_type, :text, null: false, default: "checking")
      add(:pii_fvp_account_number, :text, null: false)
      add(:pii_fvp_routing_number, :text, null: false)
      add(:fvp_account_last4, :text, null: false)
      add(:fvp_status, :text, null: false, default: "unverified")
      add(:fvp_changed_by, :text, null: false)
      add(:fvp_changed_at, :utc_datetime_usec, null: false)
      add(:fvp_verified_by, :text)
      add(:fvp_verified_at, :utc_datetime_usec)
      add(:fvp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fvp_inserted_at, :utc_datetime_usec, null: false)
      add(:fvp_updated_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_vendor_id],
        name: :fvp_vendor_payment_profile_org_vendor_index
      )
    )

    create(index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_status]))

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_status_valid,
        check: "fvp_status IN ('unverified','verified')"
      )
    )

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_account_type_valid,
        check: "fvp_account_type IN ('checking','savings')"
      )
    )

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_bank_details_vaulted,
        check:
          "LEFT(pii_fvp_account_number, 3) = 'vt_' AND " <>
            "LEFT(pii_fvp_routing_number, 3) = 'vt_'"
      )
    )

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_verification_evidence,
        check:
          "(fvp_status = 'verified' AND fvp_verified_by IS NOT NULL AND " <>
            "fvp_verified_at IS NOT NULL AND fvp_verified_by <> fvp_changed_by) OR " <>
            "(fvp_status = 'unverified' AND fvp_verified_by IS NULL AND fvp_verified_at IS NULL)"
      )
    )

    execute(
      """
      CREATE OR REPLACE FUNCTION fvp_vendor_payment_profile_guard() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: bank profiles are never deleted';
        END IF;

        IF TG_OP = 'INSERT' THEN
          IF NEW.fvp_status IS DISTINCT FROM 'unverified'
             OR NEW.fvp_verified_by IS NOT NULL OR NEW.fvp_verified_at IS NOT NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: a profile is born unverified';
          END IF;

          IF NEW.fvp_changed_by IS NULL OR NEW.fvp_changed_by = '' THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: a profile records who registered its bank details';
          END IF;

          IF LEFT(NEW.pii_fvp_account_number, 3) <> 'vt_'
             OR LEFT(NEW.pii_fvp_routing_number, 3) <> 'vt_' THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: bank details are stored only as vault tokens';
          END IF;

          RETURN NEW;
        END IF;

        IF NEW.fvp_id IS DISTINCT FROM OLD.fvp_id
           OR NEW.fvp_org_id IS DISTINCT FROM OLD.fvp_org_id
           OR NEW.fvp_vendor_id IS DISTINCT FROM OLD.fvp_vendor_id
           OR NEW.fvp_inserted_at IS DISTINCT FROM OLD.fvp_inserted_at THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: the vendor identity is immutable';
        END IF;

        IF LEFT(NEW.pii_fvp_account_number, 3) <> 'vt_'
           OR LEFT(NEW.pii_fvp_routing_number, 3) <> 'vt_' THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: bank details are stored only as vault tokens';
        END IF;

        IF NEW.fvp_bank_name IS DISTINCT FROM OLD.fvp_bank_name
           OR NEW.fvp_account_holder IS DISTINCT FROM OLD.fvp_account_holder
           OR NEW.fvp_account_type IS DISTINCT FROM OLD.fvp_account_type
           OR NEW.pii_fvp_account_number IS DISTINCT FROM OLD.pii_fvp_account_number
           OR NEW.pii_fvp_routing_number IS DISTINCT FROM OLD.pii_fvp_routing_number
           OR NEW.fvp_account_last4 IS DISTINCT FROM OLD.fvp_account_last4 THEN
          IF NEW.fvp_status IS DISTINCT FROM 'unverified'
             OR NEW.fvp_verified_by IS NOT NULL OR NEW.fvp_verified_at IS NOT NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: a bank-detail change resets verification';
          END IF;

          IF NEW.fvp_changed_by IS NOT DISTINCT FROM OLD.fvp_changed_by
             AND NEW.fvp_changed_at IS NOT DISTINCT FROM OLD.fvp_changed_at THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: a bank-detail change records who changed it';
          END IF;
        END IF;

        IF NEW.fvp_status = 'verified' THEN
          IF NEW.fvp_verified_by IS NULL OR NEW.fvp_verified_at IS NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: verification needs who and when';
          END IF;

          IF NEW.fvp_verified_by = NEW.fvp_changed_by THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: bank details need a distinct verifier';
          END IF;
        ELSIF NEW.fvp_status = 'unverified' THEN
          IF NEW.fvp_verified_by IS NOT NULL OR NEW.fvp_verified_at IS NOT NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: an unverified profile carries no verification';
          END IF;
        ELSE
          RAISE EXCEPTION 'fvp_vendor_payment_profile: unknown profile status';
        END IF;

        RETURN NEW;
      END;
      $$
      """,
      "DROP FUNCTION IF EXISTS fvp_vendor_payment_profile_guard()"
    )

    execute(
      """
      CREATE TRIGGER fvp_vendor_payment_profile_guard
      BEFORE INSERT OR UPDATE OR DELETE ON fvp_vendor_payment_profile
      FOR EACH ROW EXECUTE FUNCTION fvp_vendor_payment_profile_guard()
      """,
      "DROP TRIGGER IF EXISTS fvp_vendor_payment_profile_guard ON fvp_vendor_payment_profile"
    )
  end

  def down do
    drop(table(:fvp_vendor_payment_profile))
    execute("DROP FUNCTION IF EXISTS fvp_vendor_payment_profile_guard()")
  end
end
