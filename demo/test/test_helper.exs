# Demo dogfood app test helper (T1.9).
# Mirrors samen_core's test setup: fresh KMS key store per run, DB lifecycle,
# Oban, SQL sandbox.

alias Demo.Repo

# Per-run FileBacked KMS key store isolation (same reason as samen_core).
kms_key_dir =
  Path.join(System.tmp_dir!(), "demo_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

# Drop + create + migrate, tolerantly (the DB may still be held by the VM that just exited):
# the drop is best-effort, the create retries, anything genuinely wrong still raises.
# See `Samen.TestDb`.
Samen.TestDb.boot!(Repo)

# The `aud_event` migration creates only the FIXED launch-month (July 2026) partition; the daily
# `Samen.AuditEvent.PartitionManager` Oban job that rolls partitions forward in production never
# runs under the test harness. Ensure the CURRENT + upcoming months' partitions so audit-writing
# tests never hit "no partition of relation aud_event" once the wall clock rolls past the launch
# month (forward-safe; the ensure is idempotent).
Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(Repo, Date.utc_today(), 2)

# Start Oban (same-tx auto-revoke).
{:ok, _} = Oban.start_link(Application.fetch_env!(:samen_core, Oban))

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

# T4.6: the adversarial suite (test/adversarial/, tagged :adversarial) is EXCLUDED from
# the default `mix test` run and driven as its OWN numbered CI step:
#     mix test --only adversarial
# `--only adversarial` re-includes it (ExUnit's --only overrides the exclude). This keeps
# the default dogfood suite fast and the Phase-4 attack matrix a distinct, gateable step.
ExUnit.configure(exclude: [:adversarial])

ExUnit.start()

# Deliberately NOT armed: the framework rate-limit flood guard is
# `Samen.Web.RateLimit.FloodGuard`, and `Samen.Web.RateLimit` is not in this app's dep graph at all
# — demo does NOT depend on `samen_web` (its API-only standalone posture), so nothing here can
# consult the limiter and there is nothing to guard. The hosts that DO mount the framework web
# routes (driftwood, pawchart, samenerp) arm it in their own test helpers.
