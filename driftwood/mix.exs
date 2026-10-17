defmodule Driftwood.MixProject do
  use Mix.Project

  # Driftwood — the Phase-5 reference vertical (freight brokerage) on the Samen
  # substrate. It mounts the samen_core scopes exactly as demo/ does (path dep),
  # composes vertical resources (Driver / Settlement / DispatchEvent), lays a
  # Driftwood.Context (Carrier/Shipper/Load aliases + the settlement reshape), and
  # runs the FULL verifier gate in its own driftwood/ci.sh.
  def project do
    [
      app: :driftwood,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Driftwood.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # WS-Masked-Replay P0 — `dev_only/` holds the phoenix_replay probe (dashboard router). It is
  # compiled ONLY in dev, so no test/prod build can reference a `PhoenixReplay` module. It sits
  # OUTSIDE `lib/` on purpose: `elixirc_paths` compiles a path recursively, so a dev-only
  # subdirectory of `lib/` would still be compiled by the `:test`/`:prod` `"lib"` entry.
  defp elixirc_paths(:dev), do: ["lib", "dev_only"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:samen_core, path: "../samen_core"},
      # ADR-009 — the framework UI library. Driftwood no longer forks the UI kit +
      # CRM/Billing/Support LiveViews driftwood-local; it MOUNTS them from samen_web
      # (Samen.UI components + Samen.Web.{CRM,Billing,Support} via the router macro), so
      # the inherited-80% product surface travels at the framework level like the data.
      {:samen_web, path: "../samen_web"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_live_view, "~> 1.2.9"},
      {:phoenix_html, "~> 4.1"},
      # T5.3: Bandit is the HTTP server adapter behind the DriftwoodWeb.Endpoint that
      # serves the tenant + operator LiveView planes over localhost. phoenix_pubsub is
      # pulled transitively by phoenix; declared explicitly for the Endpoint's PubSub.
      {:bandit, "~> 1.12.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:stream_data, "== 1.3.0"},
      {:simple_sat, "~> 0.1"},
      {:ash_json_api, "~> 1.7"},
      # WS-Masked-Replay P0 (docs/ws-masked-replay/build-plan.md) — an ENGINEER-ONLY session
      # replay for this dev host, fetched/compiled in `:dev` ALONE so a prod release does not
      # contain it and `:test` cannot reference it. It records raw LiveView assigns, which on a
      # tenant plane are plane-resolved PLAINTEXT (and form values before any vault write), so
      # it must never be pointed at a real tenant org — the product mechanism is the masked
      # first-party `Samen.Replay` in the same workstream, not this dependency.
      {:phoenix_replay, "~> 0.6", only: :dev}
    ]
  end

  defp aliases do
    []
  end
end
