defmodule Samen.AnalyticsReplayTest do
  @moduledoc """
  The session-replay CAPTURE boundary (`Samen.Analytics.Replay`) — tested with NO host ledger
  wired, exactly as `analytics_track_test.exs` does for `track/1`, because every one of these
  refusals returns BEFORE the write: an `{:error, _}` means REFUSED, and the inert `{:ok,
  :dropped}` means "accepted, and would have been written had the host mounted Analytics".

  The proofs:

    1. **A surface is a BOUNDED token, never a path.** `"/crm/contacts"`, a URL, a freeform
       label, an email, a `vt_*` token, an over-long string — all REFUSED, so no replayed step
       can carry a tenant's data, an entity id or a URL.
    2. **Module → token normalization** is deterministic and total: a LiveView module maps to
       its surface token (no module needs to be loaded — this is name arithmetic), and anything
       that is not a module is refused rather than guessed.
    3. **The label helper is pure presentation** over an already-bounded token, so a humanized
       label can never reintroduce a value the capture refused.

  The catalog↔ledger-constraint drift guard (that a registered event name is ALSO accepted by
  the host resource's `one_of` gate) lives in `samen_web/test/samen/web/operator_replay_test.exs`,
  where a real materialized ledger resource exists to read the compiled constraint back out of.
  """
  use ExUnit.Case, async: false

  alias Samen.Analytics.Replay

  setup do
    # INERT by default (the `analytics_track_test.exs` posture): `{:ok, :dropped}` is the
    # ACCEPTED discriminator, `{:error, _}` the REFUSED one — no repo required.
    prior = Application.get_env(:samen_core, Samen.Analytics)
    Application.delete_env(:samen_core, Samen.Analytics)
    on_exit(fn -> if prior, do: Application.put_env(:samen_core, Samen.Analytics, prior) end)

    :ok
  end

  describe "the surface gate — a token, never a path or a label" do
    test "a LiveView module normalizes to its bounded surface token" do
      assert {:ok, "broker"} = Replay.surface_token(MyHostWeb.BrokerLive)
      assert {:ok, "dashboard"} = Replay.surface_token(MyHostWeb.CRM.DashboardLive)
      # A page whose module does not end in `_live` still normalizes.
      assert {:ok, "portal_kb"} = Replay.surface_token(MyHostWeb.Support.PortalKB)
    end

    test "a path, a URL, a label and a vault token are all REFUSED as surfaces" do
      for bad <- [
            "/crm/contacts",
            "https://acme.example/crm/contacts?org=9f2c",
            "Crm Dashboard",
            "crm.contacts",
            "Alice Smith",
            "alice@example.com",
            "vt_9f2c8d1e",
            "9f2c8d1e-0000-4000-8000-000000000000",
            String.duplicate("a", 65)
          ] do
        assert {:error, :unbounded_surface} = Replay.record_visit(org_id: "org-1", surface: bad),
               "surface #{inspect(bad)} must be refused, not coerced into a token"
      end
    end

    test "a non-module atom is refused rather than guessed into a module name" do
      assert {:error, :unbounded_surface} = Replay.surface_token(:broker)
      assert {:error, :unbounded_surface} = Replay.surface_token(nil)
      assert {:error, :unbounded_surface} = Replay.record_visit(org_id: "org-1", surface: :Broker)
    end

    test "a missing org is refused, and an already-bounded token is accepted" do
      assert {:error, :missing_org_id} = Replay.record_visit(surface: "broker")
      assert {:error, :invalid_request} = Replay.record_visit("not a request")
      assert {:ok, :dropped} = Replay.record_visit(org_id: "org-1", surface: "broker")
      assert {:ok, :dropped} = Replay.record_visit(%{org_id: "org-1", surface: "crm_dashboard"})
    end

    test "the recorded step carries the bounded surface and nothing else" do
      assert Replay.event() == "nav.visited"
      assert Replay.prop() == "surface"
      assert Replay.bounded?("broker")
      refute Replay.bounded?("Broker")
      refute Replay.bounded?("alice@example.com")
      refute Replay.bounded?("/crm/contacts")
    end
  end

  describe "the label helper is pure presentation" do
    test "a bounded token humanizes; anything else is the neutral fallback" do
      assert Replay.surface_label("broker") == "Broker"
      assert Replay.surface_label("crm_dashboard") == "Crm dashboard"
      assert Replay.surface_label(nil) == "Unknown surface"
      assert Replay.surface_label("") == "Unknown surface"
    end
  end
end
