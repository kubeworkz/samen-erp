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

config :samenerp, start_repo?: false

# In test: manual Oban (job rows visible but not auto-executed) + no plugins.
config :samen_core, Oban, testing: :manual, plugins: false
