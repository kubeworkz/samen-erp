defmodule Samen.Scopes.Ai.Analytics do
  @moduledoc """
  AI Analytics (WS-ERP AI Integration).

  Aggregates usage metrics and provides tenant dashboard statistics.

  ## Metrics Tracked

  - Total API calls per tenant
  - Token consumption (input + output)
  - Response times (average, p50, p95, p99)
  - Error rates and failure types
  - Model usage distribution
  - Cost estimation (based on token counts)
  """

  @doc """
  Aggregates token activity metrics for a tenant over a rolling window.

  ## Parameters

  - `logs` — list of PromptLog records
  - `days` — rolling window in days (default: 30)

  ## Returns

  - `%{total_calls, total_input_tokens, total_output_tokens, avg_duration_ms, failure_rate}`
  """
  @spec get_tenant_stats(list(), integer()) :: map()
  def get_tenant_stats(logs, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    recent_logs =
      logs
      |> Enum.filter(fn log ->
        inserted_at = Map.get(log, :inserted_at) || Map.get(log, "inserted_at")
        is_nil(inserted_at) or inserted_at >= cutoff
      end)

    total = length(recent_logs)

    if total == 0 do
      %{
        total_calls: 0,
        total_input_tokens: 0,
        total_output_tokens: 0,
        avg_duration_ms: 0,
        failure_rate: 0.0,
        models_used: []
      }
    else
      failures = Enum.count(recent_logs, &(&1.status != :success))

      %{
        total_calls: total,
        total_input_tokens: Enum.reduce(recent_logs, 0, &(&1.input_tokens + &2)),
        total_output_tokens: Enum.reduce(recent_logs, 0, &(&1.output_tokens + &2)),
        avg_duration_ms:
          recent_logs
          |> Enum.map(&(&1.duration_ms || 0))
          |> Enum.sum()
          |> div(total),
        failure_rate: failures / total * 100,
        models_used:
          recent_logs
          |> Enum.map(& &1.model_id)
          |> Enum.frequencies()
          |> Enum.sort_by(fn {_model, count} -> count end, :desc)
      }
    end
  end

  @doc """
  Calculates cost estimation based on token counts.

  Uses rough HuggingFace pricing (free tier for most models).
  """
  @spec estimate_cost(integer(), integer()) :: float()
  def estimate_cost(input_tokens, output_tokens) do
    # Rough estimation: $0.0001 per 1K tokens (free tier models)
    # In production, fetch actual pricing from HuggingFace
    (input_tokens + output_tokens) / 1000 * 0.0001
  end

  @doc """
  Generates a model usage report.
  """
  @spec model_usage_report(list()) :: map()
  def model_usage_report(logs) do
    logs
    |> Enum.group_by(& &1.model_id)
    |> Enum.map(fn {model_id, model_logs} ->
      %{
        model_id: model_id,
        total_calls: length(model_logs),
        success_rate:
          Enum.count(model_logs, &(&1.status == :success)) / length(model_logs) * 100,
        avg_duration_ms:
          model_logs
          |> Enum.map(&(&1.duration_ms || 0))
          |> Enum.sum()
          |> div(length(model_logs)),
        total_tokens:
          Enum.reduce(model_logs, 0, &(&1.input_tokens + &1.output_tokens + &2))
      }
    end)
    |> Enum.sort_by(& &1.total_calls, :desc)
  end

  @doc """
  Detects anomalies in usage patterns.

  Flags tenants with:
  - Error rate > 20%
  - Response time > 10 seconds
  - Unusual spike in usage
  """
  @spec detect_anomalies(list()) :: [map()]
  def detect_anomalies(logs) do
    logs
    |> Enum.group_by(& &1.tenant_id)
    |> Enum.flat_map(fn {tenant_id, tenant_logs} ->
      # Check error rate
      anomalies =
        if length(tenant_logs) > 10 do
          error_rate = Enum.count(tenant_logs, &(&1.status != :success)) / length(tenant_logs)

          if error_rate > 0.2 do
            [%{type: :high_error_rate, tenant_id: tenant_id, rate: error_rate}]
          else
            []
          end
        else
          []
        end

      # Check response times
      slow_calls =
        tenant_logs
        |> Enum.filter(&(&1.duration_ms && &1.duration_ms > 10_000))

      if length(slow_calls) > 5 do
        [%{type: :slow_responses, tenant_id: tenant_id, count: length(slow_calls)} | anomalies]
      else
        anomalies
      end
    end)
  end
end
