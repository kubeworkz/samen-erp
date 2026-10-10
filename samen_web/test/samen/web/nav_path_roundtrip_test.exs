defmodule Samen.Web.NavPathRoundtripTest do
  @moduledoc """
  SIDEBAR-REACHABILITY (2026-10-10) — the phase-module nav seams `Samen.UI.Nav.nav_paths/1`
  reads (`:files_path`, `:chat_path`, `:search_path`, `:analytics_path`, `:ics_path`,
  `:ai_path`, `:flags_path`) ride the host's TENANT mount labels, and a framework sidebar
  reads them off a `%Samen.Web.Mount{}` rebuilt by `from_session/1` in a fresh LiveView
  `mount/3` process (the initial DEAD RENDER + every websocket reconnect). A key that is read
  but NOT whitelisted in `Samen.Web.Mount.@label_keys/0` is silently dropped there — the exact
  A4 cold-BEAM bug (the marketing leads lens 500ing until another page happened to load first),
  which now would silently DISARM the whole phase-module nav.

  Two independent assertions, so neither alone can pass vacuously:

    * the round trip preserves every key (behavioural: the rebuilt mount resolves the same nav
      paths as the original), and
    * each key is in the whitelist `Mount.label_keys/0` (refutable: delete a key from the
      whitelist and this fails on its own).
  """
  use ExUnit.Case, async: true

  alias Samen.Web.{Mount, Plane}

  # The phase-module path labels, exactly as a host threads them into its shared tenant labels
  # map (samenerp's `@current_org_labels`; see docs/samenerp-mount-ledger.md).
  @phase_paths %{
    files_path: "/files",
    chat_path: "/chat",
    search_path: "/search",
    analytics_path: "/analytics",
    ics_path: "/calendar.ics",
    ai_path: "/ai",
    flags_path: "/flags"
  }

  test "the phase-module path labels survive Mount.to_session/1 → from_session/1" do
    mount =
      Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: Plane.tenant(),
        labels: @phase_paths
      )

    rebuilt = mount |> Mount.to_session() |> Mount.from_session()

    assert Map.keys(@phase_paths) -- Mount.label_keys() == [],
           "every phase-module nav path key must be whitelisted in Samen.Web.Mount.@label_keys/0"

    for {key, path} <- @phase_paths do
      assert Mount.label(rebuilt, key, nil) == path,
             "#{key} did not survive the session round trip (dropped => the sidebar group " <>
               "silently disappears on a cold BEAM)"
    end

    # Behavioural half: the rebuilt mount resolves the SAME gated nav paths.
    assert Samen.UI.nav_paths(rebuilt) == Samen.UI.nav_paths(mount)

    # The paths really are gated on the labels (anti-tautology): a mount without them resolves
    # none of the tenant-only groups.
    bare = Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: Plane.tenant())
    bare_paths = Samen.UI.nav_paths(bare)

    for key <- Map.keys(@phase_paths) do
      assert bare_paths[key] == nil, "#{key} resolved without its label — the gate is broken"
    end

    assert bare_paths[:files_path] == nil
  end
end
