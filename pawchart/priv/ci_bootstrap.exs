# PawChart ci.sh bootstrap (run under MIX_ENV=test): recreate + migrate the
# pawchart_test DB so the standalone verifier tasks (which query the LIVE DB) have a
# fully-migrated schema. Idempotent.
#
# PawChart registers NO reviewed non_pii! columns — the additive case has no plain
# columns whose NAME trips the pii_classify heuristic (contrast Driftwood's cdl_state /
# cdl_expiry, which needed distinct-reviewer clearance). Every PII value on PawChart is
# vault-routed by declaration (owner name/emails/phones + pii_pet_microchip), so
# pii_classify passes with an empty non_pii registry.

alias PawChart.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "pawchart_keystore_ci_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)

# Tolerant boot (create-if-absent + migrate): the root gate runs sibling app gates
# concurrently against one Postgres, so a contended DROP/CREATE must not crash the bootstrap.
# See `Samen.TestDb`.
Samen.TestDb.boot!(Repo)

IO.puts("pawchart ci bootstrap: DB migrated")
