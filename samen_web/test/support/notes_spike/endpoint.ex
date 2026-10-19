defmodule Samen.WebTest.NotesSpike.Router do
  @moduledoc """
  Throwaway router for the **P0 live-browser pass** (`serve.exs`). One route, no auth, no
  macros — it exists so a real browser can drive the four mechanics assertions, including the
  one a server cannot see (the caret).
  """
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)

    # No layouts: the spike's `render/1` IS the document (scripts included).
    live_session :notes_spike, root_layout: false, layout: false do
      live("/notes-spike", Samen.WebTest.NotesSpike)
    end
  end
end

defmodule Samen.WebTest.NotesSpike.Endpoint do
  @moduledoc """
  A minimal, throwaway `Phoenix.Endpoint` for the spike's browser pass. **Never mounted by a
  host and never started by the test suite** — `serve.exs` starts it by hand on loopback.
  """
  use Phoenix.Endpoint, otp_app: :samen_web

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.Static, at: "/assets", from: "priv/static/assets", gzip: false)

  plug(Plug.Static,
    at: "/phoenix",
    from: "deps/phoenix/priv/static",
    gzip: false
  )

  plug(Plug.Static,
    at: "/live_view",
    from: "deps/phoenix_live_view/priv/static",
    gzip: false
  )

  plug(Plug.Static, at: "/spike", from: "test/support/notes_spike", gzip: false)

  plug(Plug.Session,
    store: :cookie,
    key: "_notes_spike",
    signing_salt: "notes-spike-session-salt"
  )

  plug(Samen.WebTest.NotesSpike.Router)
end
