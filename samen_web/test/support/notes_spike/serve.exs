# WS-Notes P0 — throwaway launcher for the LIVE BROWSER pass.
#
#   cd samen_web && MIX_ENV=test mix run --no-halt test/support/notes_spike/serve.exs
#
# Then open http://localhost:4011/notes-spike in two tabs. Nothing here is a product surface, and
# no host router or endpoint references it.

# PRECONDITION — a webserver adapter. `samen_web` is a LIBRARY and depends on none on purpose
# (its only endpoint runs `server: false`), so `server: true` cannot bind without one. This script
# REFUSES instead of half-starting:
#
#   * add `{:bandit, "~> 1.0", only: :test}` and put `adapter: Bandit.PhoenixAdapter` in the config
#     below; or
#   * mount `Samen.WebTest.NotesSpike.Router` in a HOST that already ships an adapter
#     (driftwood/samenerp/pawchart all have `bandit`) and open its `/notes-spike`.
#
# The four mechanics assertions do not depend on this: they run on real connected sockets in
# `test/samen/web/notes_spike_mechanics_test.exs`. This script is only for the browser pass.
unless Code.ensure_loaded?(Bandit) or Code.ensure_loaded?(Plug.Cowboy) do
  IO.puts(:stderr, """
  notes_spike/serve.exs: no webserver adapter available in this VM.
  samen_web deliberately depends on neither Bandit nor Plug.Cowboy.
  Add `{:bandit, "~> 1.0", only: :test}` (+ `adapter: Bandit.PhoenixAdapter`) to run the browser
  pass, or mount Samen.WebTest.NotesSpike.Router in a host that already has one.
  """)

  System.halt(2)
end

Application.put_env(:samen_web, Samen.WebTest.NotesSpike.Endpoint,
  secret_key_base: String.duplicate("notes-spike-secret-", 4),
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4011],
  url: [host: "localhost", port: 4011],
  live_view: [signing_salt: "notes-spike-lv"],
  check_origin: false
)

# Created in THIS process (which then sleeps forever), so the table outlives every LiveView.
Samen.WebTest.NotesSpike.seed!()

{:ok, _sup} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: Samen.WebTest.NotesSpike.pubsub()},
      Samen.WebTest.NotesSpike.Endpoint
    ],
    strategy: :one_for_one,
    name: Samen.WebTest.NotesSpike.Supervisor
  )

IO.puts("WS-Notes P0 spike: http://localhost:4011/notes-spike")
Process.sleep(:infinity)
