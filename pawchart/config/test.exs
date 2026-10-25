import Config

config :pawchart, PawChart.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  # Per-SLICE test database (unset ⇒ "pawchart_test", unchanged): the sabotage harness's parallel
  # driver exports SAMEN_TEST_DB per intra-app slice, so two slices can run concurrently without
  # sharing one test_helper drop/create/migrate.
  database: System.get_env("SAMEN_TEST_DB") || "pawchart_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  # pool_size 20 + queue slack, the same shape samen_web's and samen_core's test configs carry:
  # this host's gate runs in the ROOT gate's concurrent tier (five apps against one local
  # Postgres) and its verifiers start the app on top of the suite's shared sandbox pool. The
  # default pool of 10 with Ecto's 5s queue target produced
  # `could not checkout the connection … request was dropped from queue after 5889ms` inside
  # `mix samen.verify.vault_declared_parity` during that tier (observed 2026-10-24), failing a
  # gate whose own assertions never ran. Headroom kills the flake — not a correctness change.
  pool_size: 20,
  queue_target: 200,
  queue_interval: 2_000

config :logger, level: :warning

config :pawchart, start_repo?: false

# In test: manual Oban (job rows visible but not auto-executed) + no plugins.
config :samen_core, Oban, testing: :manual, plugins: false
