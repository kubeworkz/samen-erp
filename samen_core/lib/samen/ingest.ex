defmodule Samen.Ingest do
  @moduledoc """
  The provider-agnostic ingestion seam (signed provider ingestion contract).

  Every external payroll/provider connector goes through ONE contract instead of a
  host-side function call. The contract is deliberately narrow and shared:

    * a provider-authenticated HTTP endpoint (`POST /ingest/:provider`, mounted by
      `Samen.Web.Router.samen_ingest_routes/1`),
    * HMAC-SHA256 over the exact raw body, the timestamp AND the idempotency key
      (`Samen.Ingest.Contract`),
    * timestamp freshness + durable `{provider, event_id}` and
      `{provider, idempotency_key}` uniqueness (`Samen.Ingest.Event`),
    * an explicit `schema_version` inside the signed body,
    * a bounded retry budget stored on the envelope (`Samen.Ingest.Worker`),
    * a PII-safe audit line that carries only fingerprinted identifiers
      (`Samen.Ingest.Log`).

  ## Configuration

  ONE registry is read by both the web ingress and the worker, so a provider is
  configured in exactly one place:

      config :samen_core, Samen.Ingest,
        repo: MyApp.Repo,
        max_body_bytes: 1_048_576,
        tolerance_seconds: 300,
        providers: %{
          "acme_payroll" => {MyApp.Payroll.IngestAdapter,
           %{
             secret: System.fetch_env!("ACME_PAYROLL_INGEST_SECRET"),
             schema_versions: [1],
             max_attempts: 8
           }}
        }

  `providers` values may also be a bare adapter module (no config map) when the
  adapter needs none. A provider with no configured adapter is unknown (404); an
  adapter that does not implement the full `Samen.Ingest.Provider` behaviour is
  refused with 503 — the endpoint never half-onboards a connector.

  The per-provider retry budget is bounded by this module: at least 1, at most
  #{20} attempts. A misconfigured `max_attempts: 1_000` is clamped rather than
  allowing an unbounded retry loop.
  """

  @default_max_body_bytes 1_048_576
  @default_tolerance_seconds 300
  @default_max_attempts 8
  @hard_max_attempts 20

  @doc "The default number of processing attempts for one envelope."
  @spec default_max_attempts() :: pos_integer()
  def default_max_attempts, do: @default_max_attempts

  @doc "The hard ceiling on a provider's retry budget."
  @spec hard_max_attempts() :: pos_integer()
  def hard_max_attempts, do: @hard_max_attempts

  @doc """
  Clamp a provider's configured retry budget into `1..#{@hard_max_attempts}`.
  `nil`/invalid values fall back to the default (8).
  """
  @spec clamp_attempts(term()) :: pos_integer()
  def clamp_attempts(n) when is_integer(n) and n > 0, do: min(n, @hard_max_attempts)
  def clamp_attempts(_), do: @default_max_attempts

  @doc "The configured repo for durable envelopes (nil when unwired)."
  @spec repo() :: module() | nil
  def repo, do: config(:repo)

  @doc "The provider registry (`%{name => {adapter, config}}` or `%{name => adapter}`)."
  @spec providers() :: map()
  def providers do
    case config(:providers) do
      %{} = providers -> providers
      list when is_list(list) -> Map.new(list)
      _ -> %{}
    end
  end

  @doc "Resolve one provider to `{:ok, adapter, config}`, or `:error` when unknown."
  @spec provider(String.t()) :: {:ok, module(), map()} | :error
  def provider(name) when is_binary(name) do
    case Map.get(providers(), name) do
      {module, config} when is_atom(module) and is_map(config) -> {:ok, module, config}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, %{}}
      _ -> :error
    end
  end

  def provider(_), do: :error

  @doc "The maximum accepted raw body size in bytes (default 1 MiB)."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    case config(:max_body_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_body_bytes
    end
  end

  @doc "The signature timestamp tolerance in seconds (default 300)."
  @spec tolerance_seconds() :: non_neg_integer()
  def tolerance_seconds do
    case config(:tolerance_seconds) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_tolerance_seconds
    end
  end

  defp config(key) do
    case Application.get_env(:samen_core, __MODULE__, []) do
      %{} = map -> Map.get(map, key)
      kw when is_list(kw) -> Keyword.get(kw, key)
      _ -> nil
    end
  end
end
