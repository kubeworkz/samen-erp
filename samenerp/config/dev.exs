import Config

config :samenerp, Samenerp.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samenerp_dev",
  pool_size: 10

config :logger, level: :info

# In dev the Endpoint actually serves HTTP (`mix phx.server` → a running product).
config :samenerp, SamenerpWeb.Endpoint, server: true

# Local dev KMS key store (file-backed) — the vault needs a keystore to boot.
config :samen_core, :kms_key_dir, Path.expand("../priv/dev_keystore", __DIR__)
