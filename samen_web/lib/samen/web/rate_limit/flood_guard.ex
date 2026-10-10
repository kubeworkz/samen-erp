defmodule Samen.Web.RateLimit.FloodGuard do
  @moduledoc """
  The guard against the ONE flake shape `Samen.Web.RateLimit`'s tests can have: a multi-request
  flood that asserts a count or a refusal on a **wall-clock-aligned** fixed window.

  ## The hazard

  The seam's counter backend is Hammer's ETS `:fix_window` store, whose buckets are
  `div(now_ms, window_ms)` — aligned to multiples of the window since the Unix epoch. A boundary
  therefore falls on every wall-clock minute (the `60_000` ms surfaces: sign-in, both webhook
  ingress surfaces, all three fleet surfaces), every 15 minutes (`:token_request_account`), every
  hour (`:signin_ip`, `:registration_ip`) and so on.

  A test that consults one bucket more times than that surface's LIMIT is asserting a count that
  a boundary crossing **resets** halfway through: the counter starts over, the flood never
  reaches its limit, and the refusal the test asserts never happens — a flake whose shape is
  "the mitigation looks absent" (observed in the wild in `fleet_ingress_test.exs`: `assert
  over_limit != []` read `[]`, reported at 12:22:00.0 — the minute boundary itself).

  ## What it does

  The seam calls `gate/5` before every GATE consultation (`check/3` and `over_limit?/3` — the
  calls each request makes against the surface it is limited on). Per test process, per
  `{surface, kind, value}` bucket, the Nth consultation raises `Violation` the moment `N` exceeds
  that surface's configured LIMIT — unless the test DECLARED the surface straddle-safe for itself
  (see below), so the failure lands in the offending test with the surface, the limit, the window
  and the two sanctioned fixes spelled out.

  ## Armed for the whole suite, not opt-in

  `samen_web/test/test_helper.exs` calls `arm!/0`, so every test in the suite is guarded — a new
  flood does not have to remember to opt in (`armed?/0` is what makes it suite-wide, and the
  guard's own suite asserts it).

  In PRODUCTION the audit table is never created: `armed?/0` is a single `:ets.whereis/1` that
  returns immediately, and nothing else in the seam changes — the window arithmetic, the backend
  and the `:ok | {:error, :rate_limited}` contract are untouched.

  ## The two sanctioned shapes

  `Samen.WebTest.RateLimitFlood.pin!/1` keeps every authored LIMIT verbatim and swaps only the
  WINDOW for one no flood can cross, declaring each surface straddle-safe as it does. For the
  rare test that IS about the boundary (it deliberately crosses a window edge to prove the
  counter resets), `RateLimitFlood.straddle_safe!/1` declares the surface without touching config.

  ## What counts as a consultation

  GATES only: `check/3` and `over_limit?/3`, exactly one per request per surface the request is
  limited on. The non-enforcing counters are accounting, not gates — `bump/3` on the
  `:login_failed_audit` window-edge counter (which is not a rate limit at all; its tuple's first
  slot only bounds the counter cell) and `record_failure/3` on `:webhook_bad_sig` — and
  `Samen.Web.Plugs.ApiRateLimit` legitimately calls `bump/3` on the SAME bucket right after its
  `check/3` for the `X-RateLimit-Remaining` header, so counting increments would double-count that
  one request.

  Deliberately conservative in one direction: a path that PEEKS a bucket it also enforces (the
  fleet bad-signature starvation guard peeks the main `:fleet_heartbeat` bucket before consulting
  it) is counted twice, so a test can be failed for *being able* to exceed the limit on an
  unpinned window, not only for proving it did. The remedy is the same in every case — pin the
  window (or declare the surface, if the boundary is the point).

  Counts are per PROCESS: the test process for a request issued there (the usual case — the
  controllers' `check/3` runs in the caller), or the LiveView/task process that issues the
  request. A flood deliberately split across many processes is charged to each of them separately
  and so is not attributed to one bucket; `Samen.WebTest.RateLimitFlood.pin!/1` is the fix for a
  flood of that shape too.
  """

  @table __MODULE__

  defmodule Violation do
    @moduledoc """
    Raised inside the offending test the moment it consults ONE limiter bucket more times than
    that surface's limit on an unpinned window — see `Samen.Web.RateLimit.FloodGuard`.
    """
    defexception [:message]
  end

  @doc """
  Create the audit table — making `armed?/0` true for the rest of the run. Called once by
  `samen_web/test/test_helper.exs`; idempotent, so a host app's test helper may call it too.
  """
  @spec arm! :: :ok
  def arm! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Whether the audit is armed. False in production (the table is never created there), which is
  what makes the seam's per-consultation call a no-op outside tests.
  """
  @spec armed? :: boolean()
  def armed?, do: :ets.whereis(@table) != :undefined

  @doc "Drop the audit table (owned by the test run, so it normally dies with it)."
  @spec disarm :: :ok
  def disarm do
    if armed?(), do: :ets.delete(@table)
    :ok
  end

  @doc """
  Declare `surfaces` straddle-safe **for the calling test process**: its floods on them cannot be
  reset mid-count, so the guard must not fail them. Called by
  `Samen.WebTest.RateLimitFlood.pin!/1` and `...straddle_safe!/1`. A no-op when unarmed.
  """
  @spec declare_straddle_safe([atom()]) :: :ok
  def declare_straddle_safe(surfaces) when is_list(surfaces) do
    if armed?() do
      pid = self()
      for surface <- surfaces, do: :ets.insert(@table, {{:declared, pid, surface}})
    end

    :ok
  end

  @doc """
  Whether `pid` declared `surface` straddle-safe. Public so a test (and the guard's own suite) can
  assert the declaration it relies on actually landed.
  """
  @spec straddle_safe?(pid(), atom()) :: boolean()
  def straddle_safe?(pid, surface) when is_pid(pid) and is_atom(surface) do
    armed?() and :ets.member(@table, {:declared, pid, surface})
  end

  @doc """
  Forget `pid`'s consultation counts — `Samen.Web.RateLimit.reset/0` calls this, because wiping the
  counters genuinely starts a fresh budget (so the next flood is audited on its own). Declarations
  are kept: they are about the test, not the counters.
  """
  @spec clear(pid()) :: :ok
  def clear(pid) when is_pid(pid) do
    # The stored object is `{key, count}`, and the key is the 5-tuple `{:hits, pid, surface, kind,
    # value}` — so the match pattern is the 2-tuple, not the bare key.
    if armed?(), do: :ets.match_delete(@table, {{:hits, pid, :_, :_, :_}, :_})
    :ok
  end

  @doc """
  Record one GATE consultation of `{surface, kind, value}` and raise `Violation` if this test has
  now consulted that bucket more times than `limit` without declaring `surface` straddle-safe.
  Called by the seam (`Samen.Web.RateLimit.check/3` and `over_limit?/3`) only while armed.
  """
  @spec gate(atom(), atom(), String.t(), pos_integer(), pos_integer()) :: :ok
  def gate(surface, kind, value, limit, window_ms) do
    pid = self()
    key = {:hits, pid, surface, kind, value}
    consultations = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if consultations > limit and not straddle_safe?(pid, surface) do
      raise Violation, message(surface, limit, window_ms, consultations)
    end

    :ok
  rescue
    # `disarm/0` (suite shutdown) can drop the table between the seam's `armed?/0` and this call;
    # with no audit table there is nothing to record. ONLY the table-vanished `:badarg` is
    # swallowed — `Violation` above is a different exception and never reaches this clause.
    e in ArgumentError ->
      if armed?(), do: reraise(e, __STACKTRACE__), else: :ok
  end

  defp message(surface, limit, window_ms, consultations) do
    """
    #{surface} was consulted #{consultations} times (> its limit of #{limit}) on an UNPINNED,
    wall-clock-ALIGNED window (#{window_ms} ms) inside ONE test — the straddle-the-window hazard.

    Hammer's fixed-window bucket is `div(now_ms, window_ms)`, so a boundary can fall inside this
    flood: the counter resets, the flood never reaches its limit, and the refusal (or count) this
    test asserts may never happen. The assertion is only reproducible while the window happens not
    to turn, which is what makes it a flake rather than a failure.

    Two sanctioned fixes (`Samen.WebTest.RateLimitFlood`):

      * the test is about the LIMIT, not the boundary (the usual case) — pin the WINDOW, keeping
        the limit exactly as authored:

            RateLimitFlood.pin!(%{#{surface} => {#{limit}, #{window_ms}}})

      * the test IS about the boundary (it deliberately crosses a window edge) — declare it and
        leave the config alone:

            RateLimitFlood.straddle_safe!([:#{surface}])

    See Samen.Web.RateLimit.FloodGuard. Nothing about the shipped window, the limits or the
    backend is changed by either fix — only the test's own window.
    """
  end
end
