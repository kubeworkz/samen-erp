import Config

# samen_web is a LIBRARY — the host app owns runtime config.
# This file exists only so `MIX_ENV=prod mix compile` succeeds
# (config.exs does `import_config "#{config_env()}.exs"`).

config :samen_web, Samen.WebTest.Repo,
  pool_size: 10
