defmodule Samen.WebTest.RateLimitFlood do
  @moduledoc """
  Test support for `Samen.Web.RateLimit`'s wall-clock-ALIGNED fixed window: pin the window so
  a multi-request flood cannot straddle a boundary mid-count, and (where it is sound) re-run a
  flood that somehow did.

  ## The hazard this removes

  The seam's counter backend is Hammer's ETS `:fix_window` store, whose buckets are
  `div(now_ms, window_ms)` — aligned to multiples of the window since the Unix epoch. At the
  production-shaped windows (`60_000` for the auth sign-in surface, both webhook ingress
  surfaces and all three fleet surfaces; `900_000` for the bounded `:login_failed_audit` edge)
  a bucket flips on every wall-clock minute / 15-minute mark. A test that sends `limit + 1`
  requests and then asserts the last was REFUSED is asserting a count a boundary crossing
  RESETS halfway through: the counter starts over, the flood never reaches its limit, and the
  refusal never happens. Observed in the wild in `fleet_ingress_test.exs`
  (`assert over_limit != []` read `[]`, reported at 12:22:00.0 — the minute boundary itself, on
  a concurrent full-suite run).

  Every affected test is about the LIMIT, the bucket KEY or the response SHAPE — never about
  where the window happens to fall — so `pin!/1` replaces ONLY the window, with one no test
  floods across (a day). The LIMITS, the keys and the assertions stay exactly as authored:
  `Samen.Web.RateLimit.limit_for/1` still returns the numbers each test wrote down, which is
  what sizes its flood.

  This is test-infra only. The seam, the backend and the window arithmetic it exercises are
  untouched — the shipped `:fix_window` posture is the thing under test, and pinning a window
  in a test does not (and must not) change it.

  ## Discipline

  Callers must be `async: false`: ExUnit runs non-async modules exclusively, so no other test
  observes the override, which is restored LIFO on exit (`on_exit/1`). Pass your OWN
  `%{surface => {limit, window_ms}}` map — the same shape the seam's config takes — so the
  authored limits stay visible at the call site. Pair it with `Samen.Web.RateLimit.reset/0`
  as the module already does.

  `flood/2` is the belt-and-braces companion for floods whose assertions do NOT count
  accumulated side effects: on a window flip it re-runs the whole flood, because the counts
  every request accumulated in the flipped window are gone (so the re-run behaves as a fresh
  flood). Do NOT wrap a flood whose assertion counts persisted rows (e.g. "exactly 3 deliveries
  stored") — a re-run would add its own rows; rely on `pin!/1` alone there.

  ## The guard this feeds

  `pin!/1` also DECLARES each surface straddle-safe for the calling test, so the suite-wide
  `Samen.Web.RateLimit.FloodGuard` (armed by `test_helper.exs`, and enforced on the real HTTP
  surfaces by the guard's own suite) lets the flood through instead of failing it. A test that
  floods a limiter bucket on an unpinned window — the pre-fix shape of every file above — is
  failed by that guard, with this module named in the message.
  """

  alias Samen.Web.RateLimit
  alias Samen.Web.RateLimit.FloodGuard

  # One day. Orders of magnitude longer than any test flood (they run in well under a second,
  # so the odds of crossing an aligned boundary collapse from ~1-in-100 to ~1-in-10^8), and
  # still finite, so Hammer's window arithmetic and the backend's cleanup period stay ordinary.
  @window_ms 86_400_000

  @doc """
  Replace the WINDOW of every surface in `limits` (`%{surface => {limit, window_ms}}`) with
  `#{@window_ms}` ms, keeping each LIMIT exactly as authored and merging into whatever the
  seam is already configured with. Restores the previous config when the test exits.

  Call it in a `setup` block (before the counters are reset), or at the top of a test that
  overrides the limits for its own flood.
  """
  @spec pin!(map()) :: :ok
  def pin!(limits) when is_map(limits) do
    previous = Application.get_env(:samen_web, RateLimit) || []

    pinned =
      limits
      |> Map.new(fn {surface, {limit, _window_ms}} -> {surface, {limit, @window_ms}} end)
      |> then(&Map.merge(Keyword.get(previous, :limits, %{}), &1))

    Application.put_env(:samen_web, RateLimit, Keyword.put(previous, :limits, pinned))
    # Tell the suite-wide flood guard this test's floods on these surfaces cannot be reset
    # mid-count (`Samen.Web.RateLimit.FloodGuard`).
    FloodGuard.declare_straddle_safe(Map.keys(limits))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:samen_web, RateLimit, previous) end)
    :ok
  end

  @doc """
  Declare `surfaces` straddle-safe for THIS test WITHOUT touching the seam's config — for the rare
  test that IS about the window boundary (it deliberately crosses a window edge, e.g. to prove the
  counter resets, and so must not pin). Every other flood should use `pin!/1`.
  """
  @spec straddle_safe!([atom()]) :: :ok
  def straddle_safe!(surfaces) when is_list(surfaces),
    do: FloodGuard.declare_straddle_safe(surfaces)

  @doc "The pinned window (ms) — public so a call site can name the number it relies on."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc """
  Run `fun` `times` times and return the responses in order, re-running the WHOLE flood if the
  counter window flipped while it ran (see the moduledoc for when that re-run is sound). The
  assertions on the returned responses are the caller's, unchanged.
  """
  @spec flood(pos_integer(), (-> term())) :: [term()]
  def flood(times, fun) when is_integer(times) and is_function(fun, 0) do
    started_at = System.system_time(:millisecond)
    responses = for _ <- 1..times, do: fun.()

    if div(started_at, @window_ms) == div(System.system_time(:millisecond), @window_ms) do
      responses
    else
      flood(times, fun)
    end
  end
end
