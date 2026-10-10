defmodule Samen.Web.RateLimit.FloodGuardTest do
  @moduledoc """
  The flood guard's own suite — the refutability proof for `Samen.Web.RateLimit.FloodGuard`.

  `FloodGuard` is armed for the whole `samen_web` suite by `test_helper.exs`, so this file is not
  what enforces it; what this file proves is that the guard is neither inert nor over-eager, on the
  REAL surfaces rather than on a mock of them:

    1. **Armed, not opt-in** — `armed?/0` is true and this test declared nothing, so the guard is
       suite-wide and a new flood cannot escape it by forgetting to opt in.
    2. **RED, refutable** — a flood of ONE bucket past its limit on an unpinned window RAISES, on
       the seam directly AND through a real surface (`POST /verify/resend`, the same
       `:token_request_account` gate `account_controller_test.exs` pins). Asserting the exception
       by name plus the surface, the count, the window and the two fixes is what makes the green
       cases below meaningful: an inert guard would fail this test.
    3. **GREEN, the three sanctioned shapes** — at-limit (and volume spread over distinct
       buckets), `pin!/1` (limit kept verbatim, window swapped, flood allowed through to the
       seam's own refusal) and `straddle_safe!/1` (declared without touching config, enforcement
       unchanged), plus `reset/0` starting the audit over because a wipe is a fresh budget.
  """
  use Samen.WebTest.DataCase, async: false

  import Plug.Conn

  alias Samen.Web.Auth.AccountController
  alias Samen.Web.Mount
  alias Samen.Web.RateLimit
  alias Samen.Web.RateLimit.FloodGuard
  alias Samen.WebTest.RateLimitFlood

  # The two numbers the guard compares, and the production-shaped (ALIGNED) windows this file
  # deliberately leaves UNPINNED — the guard only bites while the window is unpinned, so unpinning
  # here is what makes the red cases red.
  @limit 3
  @signin_window_ms 60_000
  @token_window_ms 900_000

  @secret_key_base String.duplicate("a", 64)

  setup do
    prev = Application.get_env(:samen_web, RateLimit)

    Application.put_env(:samen_web, RateLimit,
      limits: %{
        signin_account: {@limit, @signin_window_ms},
        token_request_account: {@limit, @token_window_ms},
        # The PRE-CRYPTO peek surface (the webhook/fleet bad-signature floods) gets its own small
        # limit, also unpinned — `over_limit?/3` is a gate and must be audited on the same terms.
        webhook_bad_sig: {2, @signin_window_ms}
      }
    )

    RateLimit.reset()

    # The resend arc's real send goes through the fail-honest Delivery chokepoint; point it at the
    # test LocalSink (the house convention — account_controller_test.exs / rate_limit_test.exs).
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_web, RateLimit, prev),
        else: Application.delete_env(:samen_web, RateLimit)

      if prev_delivery,
        do: Application.put_env(:samen_core, :delivery_env, prev_delivery),
        else: Application.delete_env(:samen_core, :delivery_env)

      RateLimit.reset()
    end)

    :ok
  end

  # ===========================================================================
  # 1. Armed for the whole suite (not opt-in)
  # ===========================================================================

  test "the guard is ARMED and this test declared nothing — a new flood cannot opt out of it" do
    assert FloodGuard.armed?(),
           "test_helper.exs must arm Samen.Web.RateLimit.FloodGuard for the whole suite"

    # No `pin!`/`straddle_safe!` in this test's setup: everything below is therefore enforced.
    refute FloodGuard.straddle_safe?(self(), :signin_account)
    refute FloodGuard.straddle_safe?(self(), :token_request_account)
  end

  # ===========================================================================
  # 2. RED — the guard fires, on the seam and on a real surface
  # ===========================================================================

  test "the (limit + 1)th consultation of ONE bucket on an unpinned window raises, with the fix in the message" do
    value = unique_value()

    for _ <- 1..@limit, do: assert(RateLimit.check(:signin_account, :email_bidx, value) == :ok)

    err =
      assert_raise FloodGuard.Violation, fn ->
        RateLimit.check(:signin_account, :email_bidx, value)
      end

    assert err.message =~ "signin_account"
    assert err.message =~ "consulted #{@limit + 1} times (> its limit of #{@limit})"
    assert err.message =~ "#{@signin_window_ms}"

    assert err.message =~
             "RateLimitFlood.pin!(%{signin_account => {#{@limit}, #{@signin_window_ms}}})"

    assert err.message =~ "RateLimitFlood.straddle_safe!([:signin_account])"
  end

  test "the PRE-CRYPTO peek gate is audited too (the webhook/fleet bad-signature flood shape)" do
    ip = "203.0.113.#{:rand.uniform(250)}"

    # `over_limit?/3` is the gate a bad-signature flood consults (429 BEFORE the crypto work), so it
    # counts exactly like `check/3` — including though it does not itself increment the counter.
    refute RateLimit.over_limit?(:webhook_bad_sig, :ip, ip)
    refute RateLimit.over_limit?(:webhook_bad_sig, :ip, ip)

    err =
      assert_raise FloodGuard.Violation, fn ->
        RateLimit.over_limit?(:webhook_bad_sig, :ip, ip)
      end

    assert err.message =~ "webhook_bad_sig"
  end

  test "a REAL surface flood (POST /verify/resend for ONE email) fails the same way" do
    email = unique_email()

    for _ <- 1..@limit, do: assert(resend(email) == "/verify/resend?sent=1")

    err = assert_raise FloodGuard.Violation, fn -> resend(email) end
    assert err.message =~ "token_request_account"
  end

  # ===========================================================================
  # 3. GREEN — the sanctioned shapes are not failed
  # ===========================================================================

  test "AT the limit on an unpinned window is fine, and volume across DISTINCT buckets is not a flood" do
    value = unique_value()

    # Exactly the limit on one bucket: allowed, and the guard stays silent (it bites at limit + 1).
    for _ <- 1..@limit, do: assert(RateLimit.check(:signin_account, :email_bidx, value) == :ok)

    # The same number of consultations spread over distinct buckets: a test that is busy is not a
    # test that floods — the guard is bucket-scoped, not volume-scoped.
    for _ <- 1..(@limit + 5),
        do: assert(RateLimit.check(:signin_account, :email_bidx, unique_value()) == :ok)
  end

  test "pin!/1 keeps the LIMIT verbatim, swaps only the window, and the flood reaches the seam's own refusal" do
    RateLimitFlood.pin!(%{token_request_account: {@limit, @token_window_ms}})
    RateLimit.reset()

    # The LIMIT is exactly the number this file authored; only the WINDOW moved (to the pinned one).
    assert RateLimit.limit_for(:token_request_account) ==
             {@limit, RateLimitFlood.window_ms()}

    assert FloodGuard.straddle_safe?(self(), :token_request_account)

    email = unique_email()
    for _ <- 1..@limit, do: assert(resend(email) == "/verify/resend?sent=1")

    # The (limit + 1)th request is the SEAM's refusal, not a guard failure.
    assert resend(email) == "/verify/resend?throttled=1"
  end

  test "straddle_safe!/1 declares without touching config — for a test that IS about the boundary" do
    RateLimitFlood.straddle_safe!([:token_request_account])

    assert FloodGuard.straddle_safe?(self(), :token_request_account)
    # Config UNTOUCHED: the shipped 15-minute window is still the one enforced.
    assert RateLimit.limit_for(:token_request_account) == {@limit, @token_window_ms}

    email = unique_email()
    for _ <- 1..@limit, do: assert(resend(email) == "/verify/resend?sent=1")
    assert resend(email) == "/verify/resend?throttled=1"
  end

  test "reset/0 starts the audit over — a wiped counter is a fresh budget, so the next flood is audited on its own" do
    value = unique_value()

    # limit consultations, then a wipe (exactly what login_failure_durable_test.exs simulates for a
    # node restart), then limit consultations again: without the audit following `reset/0`, the
    # second batch would be the (limit + 1)th..(2 × limit)th of the same bucket and would fire.
    for _ <- 1..@limit, do: assert(RateLimit.check(:signin_account, :email_bidx, value) == :ok)
    RateLimit.reset()
    for _ <- 1..@limit, do: assert(RateLimit.check(:signin_account, :email_bidx, value) == :ok)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp unique_value, do: "flood-guard-#{System.unique_integer([:positive])}"
  defp unique_email, do: "flood-guard-#{System.unique_integer([:positive])}@example.test"

  # POST /verify/resend for one email through the REAL controller (the `:token_request_account`
  # gate); returns the redirect target, which is uniform whether or not the account exists.
  defp resend(email) do
    Plug.Test.conn(:post, "/verify/resend")
    |> Map.put(:secret_key_base, @secret_key_base)
    |> Map.put(:remote_ip, {203, 0, 113, 5})
    |> Plug.Session.call(
      Plug.Session.init(
        store: :cookie,
        key: "_test",
        signing_salt: "salt",
        encryption_salt: "esalt"
      )
    )
    |> fetch_session()
    |> put_private(:samen_mount, Mount.new(:auth, Samen.WebTest.Operator, Repo))
    |> put_private(:samen_resend_path, "/verify/resend")
    |> AccountController.resend_verify(%{"resend_verify" => %{"email" => email}})
    |> then(&(&1 |> get_resp_header("location") |> List.first()))
  end
end
