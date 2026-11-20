defmodule SamenCore.TestRepo.Migrations.AddPaymentRailDimensions do
  @moduledoc """
  B2 schema belt: payment rail dimensions and the TD originator profile.

  This migration is deliberately data-shape only. It adds the rail to vendor
  payment profiles and ACH artifacts, and creates the environment-split TD
  originator profile with its own FCN sequence. It does not add services,
  renderers, or web paths.

  The existing ACH profile guard is replaced in-place so a CAD profile can
  vault its institution/transit numbers instead of an ABA routing number. The
  existing ACH rules (dual control, verification reset, immutable identity,
  no delete) remain the same. The ACH artifact trigger and its file-token rule
  are untouched.

  `down/0` refuses to erase a live CAD rail. An originator profile without CAD
  profile/artifact rows is configuration only and is dropped with its table.
  """

  # Additive expand: USD defaults preserve every existing row, and the custom
  # down/0 refuses to erase live CAD rows. Marked :expand so the host gate's
  # `mix samen.verify.migrations` exercises the down/0 in a scratch database.
  use Samen.Migration, phase: :expand

  def up do
    create_originator_profile()
    add_profile_rail()
    add_artifact_rail()
  end

  def down do
    refuse_cad_rows()

    drop(constraint(:ach_ap_payment_ach_file, :ach_rail_fingerprints))
    drop(constraint(:ach_ap_payment_ach_file, :ach_rail_valid))

    alter table(:ach_ap_payment_ach_file) do
      remove(:ach_receiver_transit_last4)
      remove(:ach_receiver_institution_last4)
      remove(:ach_originator_return_account_last4)
      remove(:ach_originator_institution_last4)
      remove(:ach_file_creation_number)
      remove(:ach_rail)
    end

    drop(constraint(:fvp_vendor_payment_profile, :fvp_rail_valid))
    drop(constraint(:fvp_vendor_payment_profile, :fvp_bank_details_vaulted))

    drop(
      unique_index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_vendor_id, :fvp_rail],
        name: :fvp_vendor_payment_profile_org_vendor_rail_index
      )
    )

    create(
      unique_index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_vendor_id],
        name: :fvp_vendor_payment_profile_org_vendor_index
      )
    )

    # Restore the pre-B2 trigger body before the rail columns disappear. The
    # function is still attached to the same trigger name.
    execute("""
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

      -- UPDATE: identity is immutable.
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

      -- Any bank-detail change MUST reset verification and record the changer.
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
    """)

    alter table(:fvp_vendor_payment_profile) do
      remove(:fvp_transit_last4)
      remove(:fvp_institution_last4)
      remove(:pii_fvp_transit_number)
      remove(:pii_fvp_institution_number)
      remove(:fvp_rail)
      modify(:pii_fvp_routing_number, :text, null: false)
    end

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_bank_details_vaulted,
        check:
          "LEFT(pii_fvp_account_number, 3) = 'vt_' AND " <>
            "LEFT(pii_fvp_routing_number, 3) = 'vt_'"
      )
    )

    drop_originator_profile()
  end

  defp create_originator_profile do
    create table(:eop_ap_eft_originator_profile, primary_key: false) do
      add(:eop_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:eop_org_id, :uuid, null: false)
      add(:eop_bank, :text, null: false, default: "td_business_central")
      add(:eop_environment, :text, null: false)
      add(:eop_client_number, :text, null: false)
      add(:eop_destination_data_centre, :text, null: false, default: "00420")
      add(:eop_return_institution, :text, null: false)
      add(:pii_eop_return_account, :text, null: false)
      add(:eop_next_file_creation_number, :integer, null: false, default: 1)
      add(:eop_encoding, :text, null: false, default: "ascii")
      add(:eop_record_separator, :text, null: false, default: "crlf")
      add(:eop_inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:eop_updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(
        :eop_ap_eft_originator_profile,
        [:eop_org_id, :eop_bank, :eop_environment],
        name: :eop_ap_eft_originator_profile_org_bank_environment_index
      )
    )

    create(
      constraint(:eop_ap_eft_originator_profile, :eop_td_fields,
        check: """
        eop_bank = 'td_business_central'
        AND eop_environment IN ('test','production')
        AND eop_client_number ~ '^[0-9]{10}$'
        AND eop_destination_data_centre = '00420'
        AND eop_return_institution ~ '^0004[0-9]{5}$'
        AND LEFT(pii_eop_return_account, 3) = 'vt_'
        AND eop_next_file_creation_number BETWEEN 1 AND 9999
        AND eop_encoding = 'ascii'
        AND eop_record_separator = 'crlf'
        """
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION eop_environment_immutable_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'eop_ap_eft_originator_profile: originator profiles are never deleted';
      END IF;

      IF NEW.eop_environment IS DISTINCT FROM OLD.eop_environment THEN
        RAISE EXCEPTION 'eop_ap_eft_originator_profile: the environment is immutable';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER eop_environment_immutable
    BEFORE UPDATE OR DELETE ON eop_ap_eft_originator_profile
    FOR EACH ROW EXECUTE FUNCTION eop_environment_immutable_guard()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION eop_ap_eft_originator_profile_touch() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.eop_updated_at := now();
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER eop_ap_eft_originator_profile_touch
    BEFORE UPDATE ON eop_ap_eft_originator_profile
    FOR EACH ROW EXECUTE FUNCTION eop_ap_eft_originator_profile_touch()
    """)
  end

  defp drop_originator_profile do
    drop(table(:eop_ap_eft_originator_profile))
    execute("DROP FUNCTION IF EXISTS eop_environment_immutable_guard()")
    execute("DROP FUNCTION IF EXISTS eop_ap_eft_originator_profile_touch()")
  end

  defp add_profile_rail do
    alter table(:fvp_vendor_payment_profile) do
      add(:fvp_rail, :text, null: false, default: "ach_usd")
      add(:pii_fvp_institution_number, :text)
      add(:pii_fvp_transit_number, :text)
      add(:fvp_institution_last4, :text)
      add(:fvp_transit_last4, :text)
      modify(:pii_fvp_routing_number, :text, null: true)
    end

    drop(
      unique_index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_vendor_id],
        name: :fvp_vendor_payment_profile_org_vendor_index
      )
    )

    create(
      unique_index(:fvp_vendor_payment_profile, [:fvp_org_id, :fvp_vendor_id, :fvp_rail],
        name: :fvp_vendor_payment_profile_org_vendor_rail_index
      )
    )

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_rail_valid,
        check: "fvp_rail IN ('ach_usd','eft_cad')"
      )
    )

    drop(constraint(:fvp_vendor_payment_profile, :fvp_bank_details_vaulted))

    create(
      constraint(:fvp_vendor_payment_profile, :fvp_bank_details_vaulted,
        check: """
        (fvp_rail = 'ach_usd'
         AND LEFT(pii_fvp_account_number, 3) = 'vt_'
         AND pii_fvp_routing_number IS NOT NULL AND LEFT(pii_fvp_routing_number, 3) = 'vt_'
         AND pii_fvp_institution_number IS NULL AND pii_fvp_transit_number IS NULL
         AND fvp_institution_last4 IS NULL AND fvp_transit_last4 IS NULL)
        OR
        (fvp_rail = 'eft_cad'
         AND LEFT(pii_fvp_account_number, 3) = 'vt_'
         AND pii_fvp_routing_number IS NULL
         AND pii_fvp_institution_number IS NOT NULL AND LEFT(pii_fvp_institution_number, 3) = 'vt_'
         AND pii_fvp_transit_number IS NOT NULL AND LEFT(pii_fvp_transit_number, 3) = 'vt_'
         AND fvp_institution_last4 IS NOT NULL AND fvp_transit_last4 IS NOT NULL)
        """
      )
    )

    execute("""
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

        IF NEW.fvp_rail IS NULL OR NEW.fvp_rail NOT IN ('ach_usd','eft_cad') THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: unknown payment rail';
        END IF;

        IF NEW.fvp_rail = 'ach_usd' THEN
          IF LEFT(NEW.pii_fvp_account_number, 3) <> 'vt_'
             OR NEW.pii_fvp_routing_number IS NULL
             OR LEFT(NEW.pii_fvp_routing_number, 3) <> 'vt_' THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: ACH details are stored only as vault tokens';
          END IF;

          IF NEW.pii_fvp_institution_number IS NOT NULL
             OR NEW.pii_fvp_transit_number IS NOT NULL
             OR NEW.fvp_institution_last4 IS NOT NULL
             OR NEW.fvp_transit_last4 IS NOT NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: an ACH profile carries no CAD branch identifiers';
          END IF;
        ELSE
          IF LEFT(NEW.pii_fvp_account_number, 3) <> 'vt_'
             OR NEW.pii_fvp_routing_number IS NOT NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: CAD details use a vaulted account and no routing number';
          END IF;

          IF NEW.pii_fvp_institution_number IS NULL
             OR LEFT(NEW.pii_fvp_institution_number, 3) <> 'vt_'
             OR NEW.pii_fvp_transit_number IS NULL
             OR LEFT(NEW.pii_fvp_transit_number, 3) <> 'vt_' THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: CAD branch identifiers are stored only as vault tokens';
          END IF;

          IF NEW.fvp_institution_last4 IS NULL OR NEW.fvp_transit_last4 IS NULL THEN
            RAISE EXCEPTION 'fvp_vendor_payment_profile: a CAD profile records branch fingerprints';
          END IF;
        END IF;

        RETURN NEW;
      END IF;

      -- UPDATE: identity is immutable, including the rail. Changing the rail
      -- would turn a verified ACH profile into a CAD profile with stale evidence.
      IF NEW.fvp_id IS DISTINCT FROM OLD.fvp_id
         OR NEW.fvp_org_id IS DISTINCT FROM OLD.fvp_org_id
         OR NEW.fvp_vendor_id IS DISTINCT FROM OLD.fvp_vendor_id
         OR NEW.fvp_rail IS DISTINCT FROM OLD.fvp_rail
         OR NEW.fvp_inserted_at IS DISTINCT FROM OLD.fvp_inserted_at THEN
        RAISE EXCEPTION 'fvp_vendor_payment_profile: the vendor identity and rail are immutable';
      END IF;

      IF NEW.fvp_rail = 'ach_usd' THEN
        IF LEFT(NEW.pii_fvp_account_number, 3) <> 'vt_'
           OR NEW.pii_fvp_routing_number IS NULL
           OR LEFT(NEW.pii_fvp_routing_number, 3) <> 'vt_' THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: ACH details are stored only as vault tokens';
        END IF;

        IF NEW.pii_fvp_institution_number IS NOT NULL
           OR NEW.pii_fvp_transit_number IS NOT NULL
           OR NEW.fvp_institution_last4 IS NOT NULL
           OR NEW.fvp_transit_last4 IS NOT NULL THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: an ACH profile carries no CAD branch identifiers';
        END IF;
      ELSIF NEW.fvp_rail = 'eft_cad' THEN
        IF LEFT(NEW.pii_fvp_account_number, 3) <> 'vt_'
           OR NEW.pii_fvp_routing_number IS NOT NULL THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: CAD details use a vaulted account and no routing number';
        END IF;

        IF NEW.pii_fvp_institution_number IS NULL
           OR LEFT(NEW.pii_fvp_institution_number, 3) <> 'vt_'
           OR NEW.pii_fvp_transit_number IS NULL
           OR LEFT(NEW.pii_fvp_transit_number, 3) <> 'vt_' THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: CAD branch identifiers are stored only as vault tokens';
        END IF;

        IF NEW.fvp_institution_last4 IS NULL OR NEW.fvp_transit_last4 IS NULL THEN
          RAISE EXCEPTION 'fvp_vendor_payment_profile: a CAD profile records branch fingerprints';
        END IF;
      ELSE
        RAISE EXCEPTION 'fvp_vendor_payment_profile: unknown payment rail';
      END IF;

      -- Any bank-detail change MUST reset verification and record the changer.
      IF NEW.fvp_bank_name IS DISTINCT FROM OLD.fvp_bank_name
         OR NEW.fvp_account_holder IS DISTINCT FROM OLD.fvp_account_holder
         OR NEW.fvp_account_type IS DISTINCT FROM OLD.fvp_account_type
         OR NEW.pii_fvp_account_number IS DISTINCT FROM OLD.pii_fvp_account_number
         OR NEW.pii_fvp_routing_number IS DISTINCT FROM OLD.pii_fvp_routing_number
         OR NEW.pii_fvp_institution_number IS DISTINCT FROM OLD.pii_fvp_institution_number
         OR NEW.pii_fvp_transit_number IS DISTINCT FROM OLD.pii_fvp_transit_number
         OR NEW.fvp_account_last4 IS DISTINCT FROM OLD.fvp_account_last4
         OR NEW.fvp_institution_last4 IS DISTINCT FROM OLD.fvp_institution_last4
         OR NEW.fvp_transit_last4 IS DISTINCT FROM OLD.fvp_transit_last4 THEN
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
    """)
  end

  defp add_artifact_rail do
    alter table(:ach_ap_payment_ach_file) do
      add(:ach_rail, :text, null: false, default: "ach_usd")
      add(:ach_file_creation_number, :text)
      add(:ach_originator_institution_last4, :text)
      add(:ach_originator_return_account_last4, :text)
      add(:ach_receiver_institution_last4, :text)
      add(:ach_receiver_transit_last4, :text)
    end

    create(
      constraint(:ach_ap_payment_ach_file, :ach_rail_valid,
        check: "ach_rail IN ('ach_usd','eft_cad')"
      )
    )

    create(
      constraint(:ach_ap_payment_ach_file, :ach_rail_fingerprints,
        check: """
        (ach_rail = 'ach_usd'
         AND ach_file_creation_number IS NULL
         AND ach_originator_institution_last4 IS NULL
         AND ach_originator_return_account_last4 IS NULL
         AND ach_receiver_institution_last4 IS NULL
         AND ach_receiver_transit_last4 IS NULL)
        OR
        (ach_rail = 'eft_cad'
         AND ach_file_creation_number IS NOT NULL
         AND ach_file_creation_number ~ '^[0-9]{4}$'
         AND ach_file_creation_number <> '0000'
         AND ach_originator_dfi_last4 IS NULL
         AND ach_receiver_routing_last4 IS NULL
         AND ach_originator_institution_last4 IS NOT NULL
         AND ach_originator_return_account_last4 IS NOT NULL
         AND ach_receiver_institution_last4 IS NOT NULL
         AND ach_receiver_transit_last4 IS NOT NULL)
        """
      )
    )
  end

  defp refuse_cad_rows do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM fvp_vendor_payment_profile WHERE fvp_rail = 'eft_cad')
         OR EXISTS (SELECT 1 FROM ach_ap_payment_ach_file WHERE ach_rail = 'eft_cad') THEN
        RAISE EXCEPTION 'add_payment_rail_dimensions: CAD payment-rail rows exist; rollback would erase live rail data';
      END IF;
    END
    $$
    """)
  end
end
