import Config

config :samenerp, Samenerp.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  # Per-SLICE test database (unset ⇒ "samenerp_test", unchanged): the sabotage harness's parallel
  # driver exports SAMEN_TEST_DB per intra-app slice, so two slices can run concurrently without
  # sharing one test_helper drop/create/migrate.
  database: System.get_env("SAMEN_TEST_DB") || "samenerp_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# Test-only payroll opt-in: the host suite exercises the reference importer
# against THIS host's journal/migration and the durable PayrollImport record.
# All three parts are intentional; the kernel boot guard refuses a half-wired
# host. Production config sets none of them.
config :samen_core, Samen.Hr.PayrollProvider, provider: Samen.Hr.Payroll.JournalProvider

config :samen_core, Samen.Hr.Payroll.JournalProvider,
  entry_module: Samenerp.Erp.JournalEntry,
  import_module: Samenerp.Erp.PayrollImport

config :samenerp, start_repo?: false

# In test: manual Oban (job rows visible but not auto-executed) + no plugins.
config :samen_core, Oban, testing: :manual, plugins: false
