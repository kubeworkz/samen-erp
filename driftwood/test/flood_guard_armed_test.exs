defmodule Driftwood.FloodGuardArmedTest do
  @moduledoc """
  The TRIPWIRE for driftwood's rate-limit flood guard (`Samen.Web.RateLimit.FloodGuard`).

  This host MOUNTS the framework's rate-limited routes (`samen_auth_routes` /
  `samen_fleet_routes` / `samen_files_routes`), so its tests DO consult `Samen.Web.RateLimit` — and
  `test/test_helper.exs` arms the guard so an unpinned flood written HERE fails at the offending
  consultation instead of flaking when a wall-clock window boundary (`div(now, window)`) resets the
  counter mid-count.

  Arming is ONE line, and losing it is SILENT: unarmed, every other test in this suite still passes
  and only a future flood flakes. So this file asserts, permanently, that the guard is armed here
  AND biting here — delete the `arm!()` line from `test/test_helper.exs` and THIS test fails.

  The probe itself is the framework's own (`Samen.Web.RateLimit.assert_flood_guard_armed!/1`), so
  the "armed and biting" protocol has exactly one definition, shared with pawchart and samenerp;
  this host authors none of it. The surface it probes is one this host really exposes: the
  `samen_auth_routes` verify/resend arc, whose POST is
  `Samen.Web.Auth.AccountController.resend_verify/2` — the same `:token_request_account` gate
  `samen_web`'s own `flood_guard_test.exs` floods.
  """
  use ExUnit.Case, async: false

  alias Samen.Web.RateLimit
  alias Samen.Web.RateLimit.FloodGuard

  @surface :token_request_account

  test "the framework flood guard is ARMED and BITING in driftwood" do
    assert FloodGuard.armed?(),
           "Samen.Web.RateLimit.FloodGuard.arm!() is missing from driftwood/test/test_helper.exs — " <>
             "without it an unpinned flood written in this suite FLAKES (a wall-clock window " <>
             "boundary resets the counter mid-count) instead of failing at the offending " <>
             "consultation."

    # The probed surface is not hypothetical here: this host mounts the framework auth spine, so
    # real requests in driftwood pass through the `:token_request_account` gate.
    assert Enum.any?(DriftwoodWeb.Router.__routes__(), fn route ->
             route.verb == :post and route.plug == Samen.Web.Auth.AccountController and
               route.plug_opts == :resend_verify
           end),
           "expected driftwood to mount samen_auth_routes' POST verify/resend arc " <>
             "(the :token_request_account gate this probe consults)"

    # ARMED *and* BITING, proven through the same seam the routes above call: the framework probe
    # flushes `limit + 1` consultations of one fresh bucket and requires the last to raise.
    assert :ok = RateLimit.assert_flood_guard_armed!(@surface)
  end
end
