defmodule Samen.Ingest.Contract do
  @moduledoc """
  The ONE signed provider-ingestion contract (provider-generic).

  This module is the security boundary every connector shares. Provider-specific
  adapters never implement cryptography, timestamp checks, replay protection or
  schema negotiation themselves; they plug in behind this contract with
  `Samen.Ingest.Provider`.

  ## Envelope (the signed body)

      {
        "schema_version": 1,
        "event_id": "run-2026-09",
        "event_type": "payroll.register",
        "occurred_at": "2026-09-30T12:00:00Z",
        "payload": { ... }
      }

  `schema_version`, `event_id`, `event_type` and `occurred_at` are required.
  `payload` is optional and defaults to `%{}`; when present it MUST be a JSON
  object. Unknown top-level fields are ignored so a v1 sender can add fields
  without breaking receivers (a breaking shape change requires a new
  `schema_version`).

  ## Signature (the authenticated endpoint)

  Two headers are required:

      Samen-Ingest-Signature: t=<unix-seconds>,v1=<hex-hmac-sha256>
      Idempotency-Key: <1..255 printable ASCII characters>

  The HMAC input binds the version, timestamp, idempotency key and exact raw
  body together:

      "v1\\n" <> timestamp <> "\\n" <> idempotency_key <> "\\n" <> raw_body

  Binding the key is deliberate: a captured request cannot be replayed under a
  DIFFERENT idempotency key, because the signature would no longer match. The
  timestamp is checked against a tolerance window (default 300s) with a small
  future skew allowance (60s); a valid HMAC outside the window is still refused.

  ## Failure classes

  `verify/3` never raises on malformed input. It returns:

    * `{:error, :not_configured}` — no secret wired (fail closed)
    * `{:error, :missing_signature | :malformed_signature | :bad_signature}`
    * `{:error, :stale_timestamp}` — outside the tolerance window
    * `{:error, :missing_idempotency_key | :invalid_idempotency_key}`
    * `{:error, :malformed_body}` — not a JSON object
    * `{:error, :missing_schema_version}`
    * `{:error, {:unsupported_schema_version, version}}`
    * `{:error, {:invalid_envelope, field}}`

  The HTTP ingress maps these to stable response codes; the adapter only ever
  receives a fully verified `%Samen.Ingest.Contract.Envelope{}`.
  """

  defmodule Envelope do
    @moduledoc """
    A verified provider envelope. Constructed only by `Samen.Ingest.Contract.verify/3`
    (or by the retry worker rehydrating a stored envelope), never from client input
    directly.
    """

    @enforce_keys [
      :schema_version,
      :event_id,
      :event_type,
      :occurred_at,
      :payload,
      :idempotency_key
    ]

    defstruct [
      :schema_version,
      :event_id,
      :event_type,
      :occurred_at,
      :payload,
      :idempotency_key
    ]

    @type t :: %__MODULE__{
            schema_version: pos_integer(),
            event_id: String.t(),
            event_type: String.t(),
            occurred_at: DateTime.t(),
            payload: map(),
            idempotency_key: String.t()
          }
  end

  @schema_versions [1]
  @default_tolerance_seconds 300
  @default_future_skew_seconds 60

  @signature_header "samen-ingest-signature"
  @idempotency_header "idempotency-key"

  @idempotency_pattern ~r/^[\x21-\x7E]+$/
  @event_id_pattern ~r/^[\x21-\x7E]+$/
  @event_type_pattern ~r/^[a-z0-9][a-z0-9_.-]*$/

  @max_idempotency_key_bytes 255
  @max_event_id_bytes 200
  @max_event_type_bytes 120

  @doc "The signature scheme's supported schema versions."
  @spec schema_versions() :: [pos_integer()]
  def schema_versions, do: @schema_versions

  @doc """
  Build the `Samen-Ingest-Signature` header value for a delivery.

  Used by senders (and by tests) to sign the EXACT raw body they will send:

      header = Samen.Ingest.Contract.sign(raw_body, timestamp, idempotency_key, secret)
  """
  @spec sign(String.t(), integer(), String.t(), String.t()) :: String.t()
  def sign(raw_body, timestamp, idempotency_key, secret)
      when is_binary(raw_body) and is_integer(timestamp) and is_binary(idempotency_key) and
             is_binary(secret) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, signing_input(raw_body, timestamp, idempotency_key))
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  @doc """
  Verify one inbound delivery and parse its envelope.

  Options:

    * `:secret` — REQUIRED. The per-provider HMAC secret.
    * `:supported_schema_versions` — default `[1]`.
    * `:tolerance_seconds` — default 300.
    * `:future_skew_seconds` — default 60.
    * `:now` — integer Unix seconds (tests); defaults to the system clock.

  Verification order is intentionally: signature header → idempotency key →
  timestamp → HMAC → JSON parse → schema/envelope validation. No JSON is decoded
  before the HMAC passes.
  """
  @spec verify(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Envelope.t()} | {:error, term()}
  def verify(raw_body, headers, opts \\ [])
      when is_binary(raw_body) and is_list(headers) do
    with {:ok, secret} <- secret(opts),
         {:ok, signature} <- required_header(headers, @signature_header, :missing_signature),
         {:ok, timestamp, received} <- parse_signature(signature),
         {:ok, idempotency_key} <- idempotency_key(headers),
         :ok <- check_timestamp(timestamp, opts),
         :ok <- check_hmac(raw_body, timestamp, idempotency_key, received, secret),
         {:ok, body} <- decode_body(raw_body),
         {:ok, envelope} <- build_envelope(body, idempotency_key, opts) do
      {:ok, envelope}
    end
  end

  @doc """
  A deterministic fingerprint of a (redacted) payload, used as the idempotency
  conflict arbiter. The same logical payload always produces the same digest;
  a different payload under the same idempotency key is a conflict.
  """
  @spec payload_digest(map()) :: String.t()
  def payload_digest(payload) when is_map(payload) do
    payload
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Headers + signature

  defp secret(opts) do
    case Keyword.get(opts, :secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :not_configured}
    end
  end

  defp required_header(headers, name, missing) do
    case header(headers, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, missing}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp parse_signature(header) do
    fields =
      header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp = field(fields, "t")
    signature = field(fields, "v1")

    with timestamp when is_binary(timestamp) <- timestamp,
         signature when is_binary(signature) <- signature,
         {timestamp, ""} <- Integer.parse(timestamp) do
      {:ok, timestamp, signature}
    else
      _ -> {:error, :malformed_signature}
    end
  end

  defp field(fields, name) do
    Enum.find_value(fields, fn
      [^name, value] -> value
      _ -> nil
    end)
  end

  defp idempotency_key(headers) do
    case header(headers, @idempotency_header) do
      nil ->
        {:error, :missing_idempotency_key}

      key ->
        key = String.trim(key)

        if key != "" and byte_size(key) <= @max_idempotency_key_bytes and
             Regex.match?(@idempotency_pattern, key) do
          {:ok, key}
        else
          {:error, :invalid_idempotency_key}
        end
    end
  end

  defp check_timestamp(timestamp, opts) do
    now = Keyword.get(opts, :now) || System.os_time(:second)
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)
    future_skew = Keyword.get(opts, :future_skew_seconds, @default_future_skew_seconds)
    age = now - timestamp

    if age >= -future_skew and age <= tolerance do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp check_hmac(raw_body, timestamp, idempotency_key, received, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, signing_input(raw_body, timestamp, idempotency_key))

    case Base.decode16(received, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == byte_size(expected) ->
        if secure_compare(expected, bytes), do: :ok, else: {:error, :bad_signature}

      _ ->
        {:error, :bad_signature}
    end
  end

  defp signing_input(raw_body, timestamp, idempotency_key) do
    "v1\n#{timestamp}\n#{idempotency_key}\n#{raw_body}"
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  # ---------------------------------------------------------------------------
  # Body + envelope

  defp decode_body(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = body} -> {:ok, body}
      _ -> {:error, :malformed_body}
    end
  end

  defp build_envelope(body, idempotency_key, opts) do
    with {:ok, schema_version} <- schema_version(body, opts),
         {:ok, event_id} <-
           token_field(body, "event_id", @event_id_pattern, @max_event_id_bytes),
         {:ok, event_type} <-
           token_field(body, "event_type", @event_type_pattern, @max_event_type_bytes),
         {:ok, occurred_at} <- occurred_at(body),
         {:ok, payload} <- payload(body) do
      {:ok,
       %Envelope{
         schema_version: schema_version,
         event_id: event_id,
         event_type: event_type,
         occurred_at: occurred_at,
         payload: payload,
         idempotency_key: idempotency_key
       }}
    end
  end

  defp schema_version(body, opts) do
    supported = Keyword.get(opts, :supported_schema_versions, @schema_versions)

    case Map.fetch(body, "schema_version") do
      :error ->
        {:error, :missing_schema_version}

      {:ok, version} when is_integer(version) and version > 0 ->
        if version in supported do
          {:ok, version}
        else
          {:error, {:unsupported_schema_version, version}}
        end

      {:ok, _} ->
        {:error, {:invalid_envelope, :schema_version}}
    end
  end

  defp token_field(body, key, pattern, max_bytes) do
    case Map.get(body, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value != "" and byte_size(value) <= max_bytes and Regex.match?(pattern, value) do
          {:ok, value}
        else
          {:error, {:invalid_envelope, String.to_atom(key)}}
        end

      _ ->
        {:error, {:invalid_envelope, String.to_atom(key)}}
    end
  end

  defp occurred_at(body) do
    case Map.get(body, "occurred_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
          _ -> {:error, {:invalid_envelope, :occurred_at}}
        end

      _ ->
        {:error, {:invalid_envelope, :occurred_at}}
    end
  end

  defp payload(body) do
    case Map.get(body, "payload") do
      nil -> {:ok, %{}}
      %{} = payload -> {:ok, payload}
      _ -> {:error, {:invalid_envelope, :payload}}
    end
  end

  # A deterministic, collision-resistant canonical form: maps become sorted
  # key/value lists and lists are canonicalized element-wise. `term_to_binary/1`
  # of that shape is stable across runs and nodes.
  defp canonical(%{} = map) do
    {:map,
     map
     |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
     |> Enum.sort()}
  end

  defp canonical(list) when is_list(list), do: {:list, Enum.map(list, &canonical/1)}
  defp canonical(value), do: value
end
