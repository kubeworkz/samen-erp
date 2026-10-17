import Config

config :driftwood, Driftwood.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "driftwood_dev"

# In dev the Endpoint actually serves HTTP (boot + curl dogfood evidence, T5.3 clause (d)).
config :driftwood, DriftwoodWeb.Endpoint, server: true

# Local dev KMS key store (file-backed). Real deploy uses AWS KMS (OPERATOR TODO).
config :samen_core, :kms_key_dir, Path.expand("../priv/dev_keystore", __DIR__)

config :driftwood, Driftwood.Repo, log: false
config :logger, level: :info

# WS-Masked-Replay P0 (docs/ws-masked-replay/build-plan.md) — the ENGINEER-ONLY
# `phoenix_replay` probe, compiled into dev alone (`only: :dev` + `dev_only/`). OFF
# everywhere else: `prod.exs`/`test.exs` never set this key, and an unset key is false.
#
# It records raw assigns and form values, which on a tenant plane are plaintext — acceptable
# ONLY over seeded dev data. Never point it at a real tenant org in a deployed environment;
# the product mechanism in this workstream is the masked `Samen.Replay`, not this package.
config :driftwood, dev_replay_dashboard: true

# Recordings are compressed term files, relative to the cwd, so this lands in
# `driftwood/priv/replay_recordings/` — gitignored, and pruned so a dev box never accumulates
# them.
config :phoenix_replay,
  storage: {PhoenixReplay.Storage.File, path: "priv/replay_recordings"},
  retention: [max_age: :timer.hours(48), max_count: 200]
