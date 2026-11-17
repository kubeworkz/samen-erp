defmodule Samen.Web.Ingest.Ingress do
  @moduledoc """
  The authenticated provider-ingestion endpoint (`POST /ingest/:provider`).

  This is the HTTP half of the signed provider contract. It is provider-generic:
  the adapter + config come from the host's `Samen.Ingest` registry. All security
  is enforced HERE and in `Samen.Ingest.Contract`; an adapter cannot opt out of
  the HMAC, timestamp window, idempotency, schema-version or retry-bound checks.

  ## Lifecycle (fail-closed order)

    1. Resolve the provider adapter; unknown ⇒ 404.
    2. Refuse an adapter that does not implement the full behaviour ⇒ 503 +
       `Retry-After`.
    3. Refuse an unwired repo ⇒ 503 + `Retry-After` (nothing half-processed).
    4. Per-provider flood guard ⇒ 429.
    5. Oversize body guard ⇒ 413 before any crypto.
    6. Pre-crypto per-IP bad-signature budget ⇒ 429.
    7. Verify signature + timestamp + idempotency key, parse envelope, negotiate
       schema version.
    8. Redact the payload (adapter), persist the envelope with its digest, enqueue
       the bounded-retry worker, and acknowledge:
         * `202 accepted` — first delivery
         * `200 duplicate` — same idempotency key/digest or event id/digest
         * `409 idempotency_conflict` / `409 event_conflict` — identifier reused
           with different content (never silently overwritten)
         * `422 unprocessable` — verified but unstorable
    9. Emit one PII-safe audit line; no payload, raw body, secret or raw identifier
       is ever logged.

  ## Response contract (bounded retry guidance for providers)

  | Status | Meaning | Provider action |
  |---|---|---|
  | 202 / 200 | durably accepted / already accepted | do not retry |
  | 400 | malformed envelope or missing/invalid idempotency key | fix, do not retry unchanged |
  | 401 | missing/invalid/stale signature | do not retry unchanged |
  | 409 | identifier reused with different content | investigate, do not retry |
  | 413 | body too large | shrink, do not retry unchanged |
  | 415 | unsupported schema version | upgrade, do not retry unchanged |
  | 429 | rate limited | retry with backoff |
  | 503 | receiver temporarily unavailable | retry with backoff (`Retry-After`) |

  The endpoint needs the exact signed bytes. Mount it in a pipeline whose
  `Plug.Parsers` uses `Samen.Web.Webhook.RawBodyReader`.
  """

  import Plug.Conn

  alias Samen.Ingest
  alias Samen.Ingest.{Contract, Event, Log, Provider, Worker}
  alias Samen.Web.RateLimit
  alias Samen.Web.Webhook.RawBodyReader

  @retry_after_seconds 30

  @doc """
  Run the ingestion lifecycle for `conn`. `opts` may override the registry for
  tests (`:repo`, `:providers`, `:max_body_bytes`, `:tolerance_seconds`);
  production reads `Samen.Ingest` config.
  """
  @spec ingest(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def ingest(conn, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    provider = conn.params["provider"] || conn.path_params["provider"]

    case resolve_provider(provider, opts) do
      :error ->
        respond(conn, 404, "unknown_provider", unresolved_provider(provider), started)

      {:ok, module, config} ->
        cond do
          not Provider.ready?(module) ->
            respond(conn, 503, "provider_not_configured", provider, started, retry: true)

          is_nil(repo(opts)) ->
            respond(conn, 503, "unavailable", provider, started, retry: true)

          true ->
            with :ok <- flood_guard(provider),
                 :ok <- oversize_guard(conn, opts),
                 :ok <- bad_sig_gate(conn) do
              verify_and_store(conn, provider, module, config, started, opts)
            else
              {:error, :rate_limited} ->
                respond(conn, 429, "rate_limited", provider, started)

              {:error, :too_large} ->
                respond(conn, 413, "payload_too_large", provider, started)
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Gates (cheap work before crypto)

  defp flood_guard(provider), do: RateLimit.check(:provider_ingest, :provider, provider)

  defp oversize_guard(conn, opts) do
    max = Keyword.get(opts, :max_body_bytes) || Ingest.max_body_bytes()

    if byte_size(RawBodyReader.raw_body(conn)) > max do
      {:error, :too_large}
    else
      :ok
    end
  end

  defp bad_sig_gate(conn) do
    if RateLimit.over_limit?(:provider_ingest_bad_sig, :ip, remote_ip(conn)) do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Verify + store

  defp verify_and_store(conn, provider, module, config, started, opts) do
    raw = RawBodyReader.raw_body(conn)
    tolerance = Keyword.get(opts, :tolerance_seconds) || Ingest.tolerance_seconds()
    versions = schema_versions(config)

    contract_opts = [
      secret: secret(config),
      supported_schema_versions: versions,
      tolerance_seconds: tolerance
    ]

    case Contract.verify(raw, conn.req_headers, contract_opts) do
      {:ok, envelope} ->
        store(conn, provider, module, config, envelope, raw, started, opts)

      {:error, :not_configured} ->
        respond(conn, 503, "provider_not_configured", provider, started, retry: true)

      {:error, reason} ->
        if auth_failure?(reason) do
          RateLimit.record_failure(:provider_ingest_bad_sig, :ip, remote_ip(conn))
        end

        respond(conn, status_for(reason), code_for(reason), provider, started,
          schema_versions: versions,
          reason: reason_token(reason),
          body_bytes: byte_size(raw)
        )
    end
  end

  defp store(conn, provider, module, config, envelope, raw, started, opts) do
    case safe_redact(module, envelope.payload) do
      {:ok, redacted} ->
        attrs = %{
          provider: provider,
          idempotency_key: envelope.idempotency_key,
          schema_version: envelope.schema_version,
          event_id: envelope.event_id,
          event_type: envelope.event_type,
          occurred_at: envelope.occurred_at,
          payload: redacted,
          payload_digest: Contract.payload_digest(redacted),
          max_attempts: Ingest.clamp_attempts(Map.get(config, :max_attempts))
        }

        persist(conn, provider, envelope, attrs, raw, started, opts)

      {:error, :invalid_redaction} ->
        respond(conn, 500, "adapter_error", provider, started,
          reason: :invalid_redaction,
          body_bytes: byte_size(raw)
        )
    end
  end

  defp persist(conn, provider, envelope, attrs, raw, started, opts) do
    log_fields = [
      provider: provider,
      schema_version: envelope.schema_version,
      event_id: envelope.event_id,
      idempotency_key: envelope.idempotency_key,
      body_bytes: byte_size(raw)
    ]

    case Event.insert_received(repo(opts), attrs) do
      {:ok, :inserted, row} ->
        enqueue(row, opts)
        respond(conn, 202, "accepted", provider, started, log_fields)

      {:ok, :duplicate, _row} ->
        respond(conn, 200, "duplicate", provider, started, log_fields)

      {:error, :idempotency_conflict, _row} ->
        respond(conn, 409, "idempotency_conflict", provider, started, log_fields)

      {:error, :event_conflict, _row} ->
        respond(conn, 409, "event_conflict", provider, started, log_fields)

      {:error, _changeset} ->
        respond(conn, 422, "unprocessable", provider, started, log_fields)
    end
  end

  defp enqueue(row, opts) do
    Worker.enqueue(row, repo: repo(opts))
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Provider config

  # The path segment is attacker-controlled BEFORE authentication: an
  # unauthenticated caller can put an email in `/ingest/<segment>`. The 404
  # audit line therefore never carries it raw; a short fingerprint keeps
  # repeated unresolved hits correlatable without copying the value to logs.
  defp unresolved_provider(nil), do: "unknown"

  defp unresolved_provider(provider) when is_binary(provider) do
    "unresolved-" <> Log.fingerprint(provider)
  end

  defp unresolved_provider(_provider), do: "unknown"

  defp resolve_provider(nil, _opts), do: :error

  defp resolve_provider(provider, opts) do
    providers = Keyword.get(opts, :providers) || Ingest.providers()

    case Map.get(providers, provider) do
      {module, config} when is_atom(module) and is_map(config) -> {:ok, module, config}
      module when is_atom(module) and not is_nil(module) -> {:ok, module, %{}}
      _ -> :error
    end
  end

  defp repo(opts), do: Keyword.get(opts, :repo) || Ingest.repo()

  defp secret(config) do
    Map.get(config, :secret) || Map.get(config, "secret") ||
      Map.get(config, :webhook_secret) || Map.get(config, "webhook_secret")
  end

  defp schema_versions(config) do
    case Map.get(config, :schema_versions) || Map.get(config, "schema_versions") do
      versions when is_list(versions) and versions != [] -> versions
      _ -> Contract.schema_versions()
    end
  end

  defp safe_redact(module, payload) do
    case module.redact_payload(payload) do
      %{} = redacted -> {:ok, redacted}
      _ -> {:error, :invalid_redaction}
    end
  rescue
    _ -> {:error, :invalid_redaction}
  end

  # ---------------------------------------------------------------------------
  # Response mapping

  defp auth_failure?(reason) do
    reason in [:missing_signature, :malformed_signature, :bad_signature, :stale_timestamp]
  end

  defp status_for({:unsupported_schema_version, _version}), do: 415

  defp status_for(reason)
       when reason in [:missing_signature, :malformed_signature, :bad_signature, :stale_timestamp],
       do: 401

  defp status_for(_reason), do: 400

  defp code_for(:missing_signature), do: "missing_signature"
  defp code_for(:malformed_signature), do: "malformed_signature"
  defp code_for(:bad_signature), do: "invalid_signature"
  defp code_for(:stale_timestamp), do: "stale_timestamp"
  defp code_for(:missing_idempotency_key), do: "missing_idempotency_key"
  defp code_for(:invalid_idempotency_key), do: "invalid_idempotency_key"
  defp code_for(:malformed_body), do: "malformed_envelope"
  defp code_for(:missing_schema_version), do: "missing_schema_version"
  defp code_for({:unsupported_schema_version, _version}), do: "unsupported_schema_version"
  defp code_for({:invalid_envelope, _field}), do: "invalid_envelope"
  defp code_for(_reason), do: "invalid_request"

  defp reason_token(reason) when is_atom(reason), do: reason
  defp reason_token({:unsupported_schema_version, _version}), do: :unsupported_schema_version
  defp reason_token({:invalid_envelope, _field}), do: :invalid_envelope
  defp reason_token(_reason), do: :invalid_request

  defp outcome(202), do: :accepted
  defp outcome(200), do: :duplicate
  defp outcome(409), do: :conflict
  defp outcome(413), do: :payload_too_large
  defp outcome(415), do: :unsupported_schema_version
  defp outcome(422), do: :unprocessable
  defp outcome(404), do: :unknown_provider
  defp outcome(429), do: :rate_limited
  defp outcome(401), do: :unauthorized
  defp outcome(400), do: :invalid_request
  defp outcome(500), do: :adapter_error
  defp outcome(503), do: :unavailable
  defp outcome(_), do: :unknown

  defp level(status) when status >= 500, do: :error
  defp level(status) when status >= 400, do: :warning
  defp level(_status), do: :info

  defp respond(conn, status, code, provider, started, extra \\ []) do
    Log.emit(
      level(status),
      outcome(status),
      Keyword.merge(extra,
        provider: provider,
        status: status,
        duration_ms: elapsed(started)
      )
    )

    conn =
      conn
      |> put_resp_content_type("application/json")
      |> maybe_retry_after(status, extra)
      |> maybe_schema_versions(status, extra)

    body =
      if status >= 400 do
        %{"error" => code}
      else
        %{"status" => code}
      end

    conn
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp maybe_retry_after(conn, status, extra) do
    if status == 503 and Keyword.get(extra, :retry, false) do
      put_resp_header(conn, "retry-after", Integer.to_string(@retry_after_seconds))
    else
      conn
    end
  end

  # Only a 415 needs to tell the sender which versions WOULD be accepted; an
  # unauthenticated 401/400 does not get extra response detail.
  defp maybe_schema_versions(conn, 415, extra) do
    case Keyword.get(extra, :schema_versions) do
      versions when is_list(versions) and versions != [] ->
        put_resp_header(conn, "samen-schema-versions", Enum.join(versions, ","))

      _ ->
        conn
    end
  end

  defp maybe_schema_versions(conn, _status, _extra), do: conn

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp remote_ip(%Plug.Conn{remote_ip: ip}) when is_tuple(ip),
    do: :inet.ntoa(ip) |> to_string()

  defp remote_ip(_), do: "unknown"
end
