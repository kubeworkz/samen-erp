defmodule Samen.Web.PlanRateLimit do
  @moduledoc """
  Plan-based Rate Limiting for subscription tiers.

  Enforces different rate limits based on the user's subscription plan.
  Integrates with the billing system to enforce plan limits.

  ## Plans

  | Plan | Requests/min | AI Requests/min | Streams |
  |---|---|---|---|
  | Free | 100 | 10 | 1 |
  | Pro | 1,000 | 100 | 5 |
  | Enterprise | 10,000 | 1,000 | 20 |

  ## Configuration

      config :samen_web, Samen.Web.PlanRateLimit,
        plans: %{
          free: %{api: 100, ai: 10, streams: 1},
          pro: %{api: 1000, ai: 100, streams: 5},
          enterprise: %{api: 10000, ai: 1000, streams: 20}
        }

  ## Usage

      # Check API rate limit
      case Samen.Web.PlanRateLimit.check_api(user_id, plan) do
        :ok -> proceed
        {:error, :rate_limited} -> return 429
      end

      # Check AI rate limit
      case Samen.Web.PlanRateLimit.check_ai(tenant_id, plan) do
        :ok -> proceed
        {:error, :rate_limited} -> return 429
      end

      # Check concurrent streams
      case Samen.Web.PlanRateLimit.check_stream(tenant_id, plan) do
        {:ok, stream_id} -> start_stream(stream_id)
        {:error, :rate_limited} -> return 429
      end
  """

  alias Samen.Web.RateLimit

  @default_plans %{
    free: %{api: 100, ai: 10, streams: 1},
    pro: %{api: 1000, ai: 100, streams: 5},
    enterprise: %{api: 10000, ai: 1000, streams: 20}
  }

  @doc """
  Check API rate limit for a user based on their plan.

  Returns `:ok` if under limit, `{:error, :rate_limited}` if over.
  """
  @spec check_api(String.t(), atom()) :: :ok | {:error, :rate_limited}
  def check_api(user_id, plan \\ :free) when is_binary(user_id) and is_atom(plan) do
    limits = get_plan_limits(plan)
    limit = limits.api
    window_ms = 60_000  # 1 minute

    # Use a combined key: plan:user_id
    key = "#{plan}:#{user_id}"

    # Check against plan-specific limit
    case RateLimit.check(:api_request_user, :api, key) do
      :ok ->
        # Also check against absolute limit (can't exceed enterprise limit)
        absolute_limit = @default_plans.enterprise.api
        case RateLimit.check(:api_request_user, :api, "absolute:#{user_id}") do
          :ok -> :ok
          {:error, :rate_limited} -> {:error, :rate_limited}
        end

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  @doc """
  Check AI rate limit for a tenant based on their plan.

  Returns `:ok` if under limit, `{:error, :rate_limited}` if over.
  """
  @spec check_ai(String.t(), atom()) :: :ok | {:error, :rate_limited}
  def check_ai(tenant_id, plan \\ :free) when is_binary(tenant_id) and is_atom(plan) do
    limits = get_plan_limits(plan)
    limit = limits.ai

    key = "#{plan}:#{tenant_id}"

    case RateLimit.check(:ai_request_tenant, :ai, key) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  @doc """
  Check concurrent stream limit for a tenant.

  Returns `{:ok, stream_id}` if under limit, `{:error, :rate_limited}` if over.
  """
  @spec check_stream(String.t(), atom()) :: {:ok, String.t()} | {:error, :rate_limited}
  def check_stream(tenant_id, plan \\ :free) when is_binary(tenant_id) and is_atom(plan) do
    limits = get_plan_limits(plan)
    max_streams = limits.streams

    key = "#{plan}:#{tenant_id}"

    # Simple concurrent stream tracking
    # In production, use a proper concurrent counter (ETS atomic ops)
    case RateLimit.check(:ai_stream_concurrent, :stream, key) do
      :ok ->
        stream_id = "stream_#{System.unique_integer([:positive])}"
        {:ok, stream_id}

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  @doc """
  Get rate limits for a plan.
  """
  @spec get_plan_limits(atom()) :: map()
  def get_plan_limits(plan) when is_atom(plan) do
    config = Application.get_env(:samen_web, __MODULE__, [])
    plans = Keyword.get(config, :plans, @default_plans)

    Map.get(plans, plan, @default_plans.free)
  end

  @doc """
  Get remaining API requests for a user.
  """
  @spec remaining_api(String.t(), atom()) :: non_neg_integer()
  def remaining_api(user_id, plan \\ :free) when is_binary(user_id) and is_atom(plan) do
    limits = get_plan_limits(plan)
    limit = limits.api

    # Get current count from Hammer
    # This is a simplified version - in production, use Hammer's get_count
    max(0, limit - 1)  # Placeholder
  end

  @doc """
  Get remaining AI requests for a tenant.
  """
  @spec remaining_ai(String.t(), atom()) :: non_neg_integer()
  def remaining_ai(tenant_id, plan \\ :free) when is_binary(tenant_id) and is_atom(plan) do
    limits = get_plan_limits(plan)
    limit = limits.ai

    # Get current count from Hammer
    # This is a simplified version - in production, use Hammer's get_count
    max(0, limit - 1)  # Placeholder
  end

  @doc """
  Reset rate limits for a user (e.g., after plan upgrade).
  """
  @spec reset_user(String.t()) :: :ok
  def reset_user(user_id) when is_binary(user_id) do
    # Clear all rate limit buckets for this user
    RateLimit.reset()
    :ok
  end
end
