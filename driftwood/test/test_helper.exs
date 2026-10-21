# Driftwood test helper — mirrors demo/samen_core setup: fresh KMS key store per
# run, DB lifecycle, Oban, SQL sandbox.

alias Driftwood.Repo

kms_key_dir =
  Path.join(System.tmp_dir!(), "driftwood_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

# Tolerant boot: this suite runs right after another gate may have held the database, so the
# drop is best-effort and the create retries. Anything genuinely wrong still raises. See
# `Samen.TestDb`.
Samen.TestDb.boot!(Repo)

# The `aud_event` migration creates only the FIXED launch-month (July 2026) partition; the daily
# `Samen.AuditEvent.PartitionManager` Oban job that rolls partitions forward in production never
# runs under the test harness. Ensure the CURRENT + upcoming months' partitions so audit-writing
# tests never hit "no partition of relation aud_event" once the wall clock rolls past the launch
# month (forward-safe; the ensure is idempotent).
Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(Repo, Date.utc_today(), 2)

{:ok, _} = Oban.start_link(Application.fetch_env!(:samen_core, Oban))

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

# The adversarial suite (test/adversarial/, tagged :adversarial) is EXCLUDED from
# the default `mix test` run and driven as its OWN CI step (`mix test --only adversarial`).
ExUnit.configure(exclude: [:adversarial])

ExUnit.start()

# The framework rate-limit FLOOD GUARD (`Samen.Web.RateLimit.FloodGuard`). This host MOUNTS the
# framework web routes (`samen_auth_routes` / `samen_fleet_routes` / `samen_files_routes`), so its
# tests DO consult `Samen.Web.RateLimit`. Armed here, a test that consults one limiter bucket more
# times than that surface's limit on an unpinned window fails at the offending consultation instead
# of flaking when a wall-clock boundary (`div(now, window)`) resets the count mid-flood — the same
# guarantee samen_web's own suite holds. Production never arms it: the table is absent there, so the
# seam stays a no-op outside tests.
Samen.Web.RateLimit.FloodGuard.arm!()
