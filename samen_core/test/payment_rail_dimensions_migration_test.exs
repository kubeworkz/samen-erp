defmodule SamenCore.PaymentRailDimensionsMigrationTest do
  @moduledoc """
  Seed-level proof for the B2 payment-rail expand migration.

  The empty-DB `Samen.Migration.DownCheck` proves a clean down/up, but it cannot
  prove what happens to real rows. This test seeds valid ACH profile/artifact
  rows, rolls the rail migration down, and proves the USD rows and the old
  shape survive. It then re-applies the migration, seeds valid CAD rows, and
  proves `down/0` refuses to erase them and leaves the rail schema intact.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  alias SamenCore.TestRepo

  @migrations Path.expand("../priv/test_repo/migrations", __DIR__)
  @rail_version 20_261_117_130_000

  defmodule ScratchRepo do
    use Ecto.Repo, otp_app: :samen_core, adapter: Ecto.Adapters.Postgres
  end

  test "ACH rows survive the rail down/up; CAD rows make down refuse without schema loss" do
    {repo, config} = start_scratch_repo("payment_rail_seed")

    try do
      migrate!(repo, :up, to: @rail_version)

      assert column?(repo, "fvp_vendor_payment_profile", "fvp_rail")
      assert column?(repo, "ach_ap_payment_ach_file", "ach_rail")

      ach = seed_ach!(repo)

      migrate!(repo, :down, to: @rail_version - 1)

      refute column?(repo, "fvp_vendor_payment_profile", "fvp_rail")
      refute column?(repo, "ach_ap_payment_ach_file", "ach_rail")

      assert index?(repo, "fvp_vendor_payment_profile_org_vendor_index")
      refute index?(repo, "fvp_vendor_payment_profile_org_vendor_rail_index")

      assert constraint?(repo, "fvp_vendor_payment_profile", "fvp_bank_details_vaulted")
      refute constraint?(repo, "fvp_vendor_payment_profile", "fvp_rail_valid")

      # The restored legacy trigger must accept a row inserted without fvp_rail;
      # if the B2 trigger survived, this insert would reference a dropped column.
      legacy_profile_id = seed_legacy_ach!(repo)
      assert count_by_id(repo, "fvp_vendor_payment_profile", "fvp_id", legacy_profile_id) == 1

      assert count_by_id(repo, "fvp_vendor_payment_profile", "fvp_id", ach.profile_id) == 1

      assert count_by_id(repo, "ach_ap_payment_ach_file", "ach_id", ach.artifact_id) == 1

      assert %{rows: [["ACH Holder", "ach.txt"]]} =
               repo.query!(
                 """
                 SELECT p.fvp_account_holder, a.ach_name
                 FROM fvp_vendor_payment_profile p
                 JOIN ach_ap_payment_ach_file a ON a.ach_org_id = p.fvp_org_id
                 WHERE p.fvp_id = $1 AND a.ach_id = $2
                 """,
                 [uuid_param(ach.profile_id), uuid_param(ach.artifact_id)]
               )

      migrate!(repo, :up, to: @rail_version)

      assert column?(repo, "fvp_vendor_payment_profile", "fvp_rail")
      assert column?(repo, "ach_ap_payment_ach_file", "ach_rail")
      assert index?(repo, "fvp_vendor_payment_profile_org_vendor_rail_index")
      refute index?(repo, "fvp_vendor_payment_profile_org_vendor_index")
      assert constraint?(repo, "fvp_vendor_payment_profile", "fvp_rail_valid")

      assert %{rows: [["ach_usd", "ach_usd"]]} =
               repo.query!(
                 """
                 SELECT p.fvp_rail, a.ach_rail
                 FROM fvp_vendor_payment_profile p
                 JOIN ach_ap_payment_ach_file a ON a.ach_org_id = p.fvp_org_id
                 WHERE p.fvp_id = $1 AND a.ach_id = $2
                 """,
                 [uuid_param(ach.profile_id), uuid_param(ach.artifact_id)]
               )

      cad = seed_cad!(repo)

      refusal =
        try do
          migrate!(repo, :down, to: @rail_version - 1)
          :no_refusal
        rescue
          exception -> {:refused, exception}
        end

      assert {:refused, exception} = refusal
      assert Exception.message(exception) =~ "CAD payment-rail rows exist"

      # The refused down ran in a transaction: the rail shape and both sets of
      # rows must still be there, not partially erased.
      assert column?(repo, "fvp_vendor_payment_profile", "fvp_rail")
      assert column?(repo, "ach_ap_payment_ach_file", "ach_rail")
      assert index?(repo, "fvp_vendor_payment_profile_org_vendor_rail_index")
      assert constraint?(repo, "fvp_vendor_payment_profile", "fvp_rail_valid")

      assert count_by_id(repo, "fvp_vendor_payment_profile", "fvp_id", ach.profile_id) == 1
      assert count_by_id(repo, "ach_ap_payment_ach_file", "ach_id", ach.artifact_id) == 1
      assert count_by_id(repo, "fvp_vendor_payment_profile", "fvp_id", cad.profile_id) == 1
      assert count_by_id(repo, "ach_ap_payment_ach_file", "ach_id", cad.artifact_id) == 1
    after
      stop_scratch_repo(repo, config)
    end
  end

  # --- seeds -----------------------------------------------------------------

  defp seed_ach!(repo) do
    org_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    vendor_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    run_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    %{rows: [[profile_id]]} =
      repo.query!(
        """
        INSERT INTO fvp_vendor_payment_profile
          (fvp_org_id, fvp_vendor_id, fvp_bank_name, fvp_account_holder,
           fvp_account_type, pii_fvp_account_number, pii_fvp_routing_number,
           fvp_account_last4, fvp_status, fvp_changed_by, fvp_changed_at,
           fvp_inserted_at, fvp_updated_at, fvp_rail)
        VALUES ($1, $2, 'ACH Bank', 'ACH Holder', 'checking', 'vt_ach_account',
                'vt_ach_routing', '1234', 'unverified', 'seed', now(), now(),
                now(), 'ach_usd')
        RETURNING fvp_id
        """,
        [org_id, vendor_id]
      )

    %{rows: [[artifact_id]]} =
      repo.query!(
        """
        INSERT INTO ach_ap_payment_ach_file
          (ach_org_id, ach_run_id, ach_name, ach_digest, ach_file_token,
           ach_size_bytes, ach_originator_name, ach_originator_id,
           ach_originator_dfi_last4, ach_receiver_name,
           ach_receiver_account_last4, ach_receiver_routing_last4,
           ach_generated_by, ach_generated_at, ach_inserted_at)
        VALUES ($1, $2, 'ach.txt', $3, 'vt_ach_file', 1, 'ACH Originator',
                '1234567890', '6789', 'ACH Receiver', '5678', '0210', 'seed',
                now(), now())
        RETURNING ach_id
        """,
        [org_id, run_id, String.duplicate("a", 64)]
      )

    %{profile_id: profile_id, artifact_id: artifact_id}
  end

  defp seed_legacy_ach!(repo) do
    org_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    vendor_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    %{rows: [[profile_id]]} =
      repo.query!(
        """
        INSERT INTO fvp_vendor_payment_profile
          (fvp_org_id, fvp_vendor_id, fvp_bank_name, fvp_account_holder,
           fvp_account_type, pii_fvp_account_number, pii_fvp_routing_number,
           fvp_account_last4, fvp_status, fvp_changed_by, fvp_changed_at,
           fvp_inserted_at, fvp_updated_at)
        VALUES ($1, $2, 'Legacy Bank', 'Legacy Holder', 'checking',
                'vt_legacy_account', 'vt_legacy_routing', '4321', 'unverified',
                'seed', now(), now(), now())
        RETURNING fvp_id
        """,
        [org_id, vendor_id]
      )

    profile_id
  end

  defp seed_cad!(repo) do
    org_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    vendor_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    run_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    %{rows: [[profile_id]]} =
      repo.query!(
        """
        INSERT INTO fvp_vendor_payment_profile
          (fvp_org_id, fvp_vendor_id, fvp_bank_name, fvp_account_holder,
           fvp_account_type, pii_fvp_account_number, pii_fvp_routing_number,
           pii_fvp_institution_number, pii_fvp_transit_number,
           fvp_account_last4, fvp_institution_last4, fvp_transit_last4,
           fvp_status, fvp_changed_by, fvp_changed_at, fvp_inserted_at,
           fvp_updated_at, fvp_rail)
        VALUES ($1, $2, 'CAD Bank', 'CAD Holder', 'checking', 'vt_cad_account',
                NULL, 'vt_cad_institution', 'vt_cad_transit', '6789', '004',
                '12345', 'unverified', 'seed', now(), now(), now(), 'eft_cad')
        RETURNING fvp_id
        """,
        [org_id, vendor_id]
      )

    %{rows: [[artifact_id]]} =
      repo.query!(
        """
        INSERT INTO ach_ap_payment_ach_file
          (ach_org_id, ach_run_id, ach_name, ach_digest, ach_file_token,
           ach_size_bytes, ach_originator_name, ach_originator_id,
           ach_originator_dfi_last4, ach_receiver_name,
           ach_receiver_account_last4, ach_receiver_routing_last4,
           ach_generated_by, ach_generated_at, ach_inserted_at, ach_rail,
           ach_file_creation_number, ach_originator_institution_last4,
           ach_originator_return_account_last4, ach_receiver_institution_last4,
           ach_receiver_transit_last4)
        VALUES ($1, $2, 'eft.txt', $3, 'vt_cad_file', 1, 'CAD Originator',
                '1234567890', NULL, 'CAD Receiver', '5678', NULL, 'seed',
                now(), now(), 'eft_cad', '0001', '004', '12345', '004',
                '54321')
        RETURNING ach_id
        """,
        [org_id, run_id, String.duplicate("b", 64)]
      )

    %{profile_id: profile_id, artifact_id: artifact_id}
  end

  # --- scratch database ------------------------------------------------------

  defp start_scratch_repo(suffix) do
    base = TestRepo.config()
    database = "#{Keyword.fetch!(base, :database)}_#{suffix}_#{:rand.uniform(1_000_000)}"

    config =
      base
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 5)
      |> Keyword.put(:database, database)

    :ok = Samen.TestDb.ensure_up!(config)
    {:ok, _} = ScratchRepo.start_link(config)
    {ScratchRepo, config}
  end

  defp stop_scratch_repo(repo, config) do
    if Process.whereis(repo), do: Supervisor.stop(repo)
    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok
  end

  # --- schema helpers --------------------------------------------------------

  defp column?(repo, table, column) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    rows != []
  end

  defp index?(repo, name) do
    %{rows: rows} = repo.query!("SELECT 1 FROM pg_indexes WHERE indexname = $1", [name])
    rows != []
  end

  defp constraint?(repo, table, name) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM pg_constraint WHERE conname = $1 AND conrelid = to_regclass($2)",
        [name, table]
      )

    rows != []
  end

  defp uuid_param(uuid) when is_binary(uuid) and byte_size(uuid) == 16, do: uuid
  defp uuid_param(uuid), do: Ecto.UUID.dump!(uuid)

  defp count_by_id(repo, table, primary_key, id) do
    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM #{table} WHERE #{primary_key} = $1", [uuid_param(id)])

    count
  end

  defp migrate!(repo, direction, opts) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(repo, @migrations, direction, Keyword.put(opts, :log, false))
    after
      Code.put_compiler_option(:ignore_module_conflict, previous || false)
    end
  end
end
