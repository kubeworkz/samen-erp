defmodule Samen.Ingest.Provider do
  @moduledoc """
  The provider-specific half of the signed ingestion contract.

  An adapter is deliberately small because the SECURITY posture is shared, not
  reimplemented per connector: `Samen.Ingest.Contract` owns the HMAC, timestamp,
  idempotency-key and schema-version checks; `Samen.Ingest.Event` owns durable
  replay/idempotency; `Samen.Ingest.Worker` owns the bounded retry budget.

  ## Required callbacks

    * `redact_payload/1` — remove or mask PII BEFORE the envelope is stored. The
      returned map is the only payload ever persisted (and the digest used for
      idempotency-conflict detection is computed from it).
    * `handle/2` — perform the provider-specific effect. It receives the verified
      `%Samen.Ingest.Contract.Envelope{}` and options including `:config` (the
      provider's config map), `:repo` and `:provider`.

  Both are required. A provider that has not finished its adapter is refused at
  the ingress with 503 (fail closed) rather than accepting data it cannot safely
  redact or process.

  ## Return contract for `handle/2`

    * `:ok` — handled; the envelope becomes `processed`.
    * `{:error, reason}` — transient failure; retried until the stored budget is
      exhausted, then dead-lettered.
    * `{:discard, reason}` — permanent failure; dead-lettered immediately.

  A raise is treated as a transient failure with the same bounded budget. Error
  summaries are reduced to bounded machine tokens by `Samen.Ingest.Event`, so a
  handler cannot accidentally persist a payload (or PII) in `last_error`.
  """

  alias Samen.Ingest.Contract.Envelope

  @callback redact_payload(payload :: map()) :: map()

  @callback handle(envelope :: Envelope.t(), opts :: keyword()) ::
              :ok | {:error, term()} | {:discard, term()}

  @doc """
  Whether `module` can safely serve as an ingestion adapter: loaded, and both
  required callbacks exported. A false answer is a fail-closed 503 at the ingress.
  """
  @spec ready?(module()) :: boolean()
  def ready?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :redact_payload, 1) and
      function_exported?(module, :handle, 2)
  end

  def ready?(_), do: false
end
