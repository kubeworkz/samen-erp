defmodule Samenerp.Monitoring do
  @moduledoc """
  Monitoring and Alerting module for production deployment.

  Provides integration with Sentry for error tracking and OpenTelemetry for
  distributed tracing and metrics.

  ## Configuration

      # In config/runtime.exs
      config :sentry, dsn: System.get_env("SENTRY_DSN")
      config :opentelemetry,
        resource: [service: "samenerp"],
        exporters: [otlp: [endpoint: "http://localhost:4318"]]

  ## Features

  - Error tracking with Sentry
  - Distributed tracing with OpenTelemetry
  - Custom metrics and spans
  - Performance monitoring
  - Alert rules configuration
  """

  require Logger

  @doc """
  Initialize monitoring with the given configuration.
  """
  @spec init(map()) :: :ok
  def init(config \\ %{}) do
    Logger.info("[Monitoring] Initializing monitoring and alerting")

    # Initialize Sentry if configured
    if dsn = config[:sentry_dsn] || System.get_env("SENTRY_DSN") do
      Logger.info("[Monitoring] Sentry configured")
    end

    # Initialize OpenTelemetry if configured
    if endpoint = config[:otel_endpoint] || System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      Logger.info("[Monitoring] OpenTelemetry configured: #{endpoint}")
    end

    :ok
  end

  @doc """
  Capture an exception with context.
  """
  @spec capture_exception(Exception.t(), map()) :: :ok
  def capture_exception(exception, context \\ %{}) do
    Logger.error("[Monitoring] Exception: #{Exception.message(exception)}")

    # In production, send to Sentry
    if System.get_env("SENTRY_DSN") do
      Sentry.capture_exception(exception, extra: context)
    end

    :ok
  end

  @doc """
  Capture a message with level.
  """
  @spec capture_message(String.t(), atom(), map()) :: :ok
  def capture_message(message, level \\ :info, context \\ %{}) do
    Logger.bare_log(level, "[Monitoring] #{message}")

    # In production, send to Sentry
    if System.get_env("SENTRY_DSN") do
      Sentry.capture_message(message, level: level, extra: context)
    end

    :ok
  end

  @doc """
  Start a new span for distributed tracing.
  """
  @spec start_span(String.t(), map()) :: :ok
  def start_span(name, attributes \\ %{}) do
    Logger.debug("[Monitoring] Starting span: #{name}")

    # In production, create OpenTelemetry span
    if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      :otel_tracer.start_span(name, attributes: attributes)
    end

    :ok
  end

  @doc """
  End the current span.
  """
  @spec end_span() :: :ok
  def end_span do
    Logger.debug("[Monitoring] Ending span")

    # In production, end OpenTelemetry span
    if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      :otel_tracer.end_span()
    end

    :ok
  end

  @doc """
  Record a custom metric.
  """
  @spec record_metric(String.t(), number(), map()) :: :ok
  def record_metric(name, value, labels \\ %{}) do
    Logger.debug("[Monitoring] Metric: #{name} = #{value}")

    # In production, record to OpenTelemetry metrics
    if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      :otel_metrics.record(name, value, labels: labels)
    end

    :ok
  end

  @doc """
  Check health of monitoring systems.
  """
  @spec health_check() :: map()
  def health_check do
    %{
      sentry: sentry_health(),
      opentelemetry: otel_health(),
      timestamp: DateTime.utc_now()
    }
  end

  defp sentry_health do
    if System.get_env("SENTRY_DSN") do
      :configured
    else
      :not_configured
    end
  end

  defp otel_health do
    if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      :configured
    else
      :not_configured
    end
  end
end
