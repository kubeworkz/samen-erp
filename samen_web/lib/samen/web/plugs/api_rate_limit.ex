defmodule Samen.Web.Plugs.ApiRateLimit do
  @moduledoc """
  API Rate Limiting Plug for authenticated users.

  Enforces per-user, per-org, and per-plan rate limits on API endpoints.
  Uses the same Hammer-backed ETS store as auth rate limiting.

  ## Usage

      plug Samen.Web.Plugs.ApiRateLimit

  Or with custom options:

      plug Samen.Web.Plugs.ApiRateLimit,
        limits: [user: 1000, org: 10000],
        plan_limits: %{free: 100, pro: 1000, enterprise: 10000}

  ## Rate Limit Strategy

  1. **Per-User Limit** — Each authenticated user has a per-minute limit
  2. **Per-Org Limit** — Each organization has a shared limit across all users
  3. **Per-Plan Limit** — Limits based on subscription plan (free/pro/enterprise)
  4. **Per-IP Limit** — Fallback for unauthenticated requests

  ## Response Headers

  - `X-RateLimit-Limit` — The rate limit for the current window
  - `X-RateLimit-Remaining` — Remaining requests in the current window
  - `X-RateLimit-Reset` — Time when the window resets (Unix timestamp)

  ## Error Response

  Returns 429 Too Many Requests with:
  ```json
  {
    "error": "rate_limited",
    "message": "Rate limit exceeded. Please try again later.",
    "retry_after": 60
  }
  ```
  """

  import Plug.Conn
  alias Samen.Web.RateLimit

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Get user/org info from conn (set by auth middleware)
    user_id = get_user_id(conn)
    org_id = get_org_id(conn)
    plan = get_plan(conn)
    ip = get_ip(conn)

    # Determine rate limit key and surface
    {surface, key} = determine_limit_key(user_id, org_id, plan, ip)

    # Check rate limit
    case RateLimit.check(surface, :api, key) do
      :ok ->
        # Add rate limit headers
        {limit, window_ms} = RateLimit.limit_for(surface)
        remaining = max(0, limit - RateLimit.bump(surface, :api, key))
        reset_at = System.system_time(:second) + div(window_ms, 1000)

        conn
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
        |> put_resp_header("x-ratelimit-reset", to_string(reset_at))

      {:error, :rate_limited} ->
        {_limit, window_ms} = RateLimit.limit_for(surface)
        retry_after = div(window_ms, 1000)

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_header("x-ratelimit-limit", "0")
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("x-ratelimit-reset", to_string(System.system_time(:second) + retry_after))
        |> send_resp(429, Jason.encode!(%{
          error: "rate_limited",
          message: "Rate limit exceeded. Please try again later.",
          retry_after: retry_after
        }))
        |> halt()
    end
  end

  # Determine which rate limit to enforce
  defp determine_limit_key(user_id, org_id, _plan, ip) do
    cond do
      # Authenticated user with org — use user + org limits
      user_id && org_id ->
        {:api_request_user, "#{user_id}:#{org_id}"}

      # Authenticated user without org — use user limit
      user_id ->
        {:api_request_user, user_id}

      # Unauthenticated — use IP limit
      true ->
        {:api_request_ip, ip || "unknown"}
    end
  end

  # Get user_id from conn (set by auth middleware)
  defp get_user_id(conn) do
    conn.assigns[:current_user_id] ||
      conn.private[:current_user_id] ||
      get_session(conn, "user_id")
  end

  # Get org_id from conn (set by auth middleware or query param)
  defp get_org_id(conn) do
    conn.assigns[:org_id] ||
      conn.private[:org_id] ||
      get_session(conn, "org_id") ||
      conn.params["org"]
  end

  # Get subscription plan from conn
  defp get_plan(conn) do
    conn.assigns[:plan] ||
      conn.private[:plan] ||
      :free  # Default to free plan
  end

  # Get client IP address
  defp get_ip(conn) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
end
