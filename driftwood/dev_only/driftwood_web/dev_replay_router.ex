defmodule DriftwoodWeb.DevReplayRouter do
  @moduledoc """
  The DEV-ONLY `phoenix_replay` dashboard (WS-Masked-Replay P0), mounted by
  `DriftwoodWeb.Router` at `/dev/replay` when `config :driftwood, :dev_replay_dashboard` is
  true at COMPILE time.

  ## Why this module is its own router, in its own directory

  `phoenix_replay`'s dashboard is a router macro (`import PhoenixReplay.Router` +
  `phoenix_replay/2`), so it must be expanded where it is mounted. Expanding it inside
  `DriftwoodWeb.Router` would make every environment's compile depend on the dependency — and
  the dependency is declared `only: :dev` precisely so a prod build never contains it.

  This file lives in `dev_only/` — OUTSIDE `lib/`, because `elixirc_paths` compiles a path
  recursively and a dev-only subdirectory of `lib/` would still be compiled by the `"lib"`
  entry in `:test`/`:prod`. `mix.exs`'s `elixirc_paths(:dev)` adds it to the compile path, and
  the main router only ever names this module as the target of a `forward/2` inside a
  compile-time-false branch in `:test`/`:prod`, so no non-dev build references a
  `PhoenixReplay` module at all. `test/replay_dev_only_test.exs` proves it.

  ## What it records (and why that is acceptable HERE)

  `PhoenixReplay.Recorder` records mount assigns, `handle_params` params, `handle_event`
  names/params and changed assigns — raw. On this foundry's tenant plane those assigns are
  already PII-resolved plaintext and form events carry typed plaintext, which is exactly why
  the product mechanism is `Samen.Replay` (record by reference) and not this package.
  Acceptable here because it is dev-only, over seeded fake data, never pointed at a real
  tenant org in a deployed environment, and pointed at a throwaway directory
  (`priv/replay_recordings/`, gitignored).
  """

  use Phoenix.Router

  import PhoenixReplay.Router

  # The routes carry the FULL `/dev/replay` prefix and the host router forwards `"/"` to this
  # module (as its last route). That is not cosmetic: `phoenix_replay/2` builds every link the
  # dashboard renders from `Phoenix.Router.scoped_path(__MODULE__, path)`, so a router that does
  # not itself carry the prefix generates `/3RPG…` instead of `/dev/replay/3RPG…` — a dashboard
  # whose session links 404. (A `forward "/dev/replay"` mount would strip the prefix before this
  # module sees it, so the routes would sit at the wrong path.) The forwarded conn keeps its
  # full `path_info` because the host's prefix is `"/"`.
  #
  # The dashboard's socket path is the endpoint's default (`/live`, `DriftwoodWeb.Endpoint`).
  # Before the dashboard decodes anything: create this host's module atoms so the package's
  # `:safe` decode succeeds on the first try (see `DriftwoodWeb.DevReplayWarmup`). A router can
  # only `plug` inside a pipeline, hence the one-plug pipeline.
  pipeline :replay_warmup do
    plug(DriftwoodWeb.DevReplayWarmup)
  end

  scope "/dev/replay" do
    pipe_through([:replay_warmup])

    phoenix_replay("/")
  end
end
