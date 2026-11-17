defmodule Samen.Ingest.Log do
  @moduledoc """
  PII-safe audit lines for the provider-ingestion contract.

  The audit line is built from an ALLOWLIST of bounded, non-PII fields. Free-form
  maps, payloads, headers, raw bodies and secrets are dropped. Identifiers are
  never written in the clear: `event_id` and `idempotency_key` are reduced to a
  deterministic 12-hex fingerprint so operators can correlate a delivery without
  the log becoming a secondary copy of provider data.

  Emitted shape (order is stable):

      provider_ingest outcome=accepted provider=acme_payroll status=202 \\
        schema_version=1 event_ref=2f9a1c0b77de idempotency_ref=91b0c4e8aa02 \\
        duration_ms=4 body_bytes=512

  No `event_type`, payload, header, email, name, token, secret or raw id is ever
  part of this line. `format/2` is public so the PII-free shape is testable
  without depending on the configured Logger level.
  """

  require Logger

  @token ~r/^[A-Za-z0-9_.:@-]{1,120}$/
  @fingerprint_bytes 12

  @allowed [
    :provider,
    :status,
    :schema_version,
    :duration_ms,
    :body_bytes,
    :attempt,
    :max_attempts,
    :reason,
    :event_id,
    :idempotency_key
  ]

  @doc """
  Emit one audit line at `level`. `fields` is an allowlisted keyword/map; unknown
  keys are discarded, and only fingerprinted identifiers are rendered.
  """
  @spec emit(Logger.level(), atom() | String.t(), keyword() | map()) :: :ok
  def emit(level, outcome, fields \\ []) do
    Logger.log(level, format(outcome, fields))
  end

  @doc "Build the PII-safe audit line without emitting it."
  @spec format(atom() | String.t(), keyword() | map()) :: String.t()
  def format(outcome, fields \\ []) do
    fields =
      fields
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(Enum.map(@allowed, &to_string/1))

    [
      "provider_ingest",
      "outcome=#{token(outcome) || "unknown"}",
      maybe("provider", token(fields["provider"])),
      maybe("status", integer(fields["status"])),
      maybe("schema_version", integer(fields["schema_version"])),
      maybe("event_ref", ref(fields["event_id"])),
      maybe("idempotency_ref", ref(fields["idempotency_key"])),
      maybe("duration_ms", integer(fields["duration_ms"])),
      maybe("body_bytes", integer(fields["body_bytes"])),
      maybe("attempt", integer(fields["attempt"])),
      maybe("max_attempts", integer(fields["max_attempts"])),
      maybe("reason", token(fields["reason"]))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  A stable 12-hex fingerprint of an identifier. `nil` renders as `"none"`.
  Non-binary scalar values are stringified first; maps/lists are never rendered.
  """
  @spec fingerprint(term()) :: String.t()
  def fingerprint(nil), do: "none"

  def fingerprint(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @fingerprint_bytes)
  end

  def fingerprint(value) when is_atom(value) or is_integer(value),
    do: fingerprint(to_string(value))

  def fingerprint(_), do: "none"

  defp ref(nil), do: nil
  defp ref(value), do: fingerprint(value)

  defp maybe(_key, nil), do: nil
  defp maybe(key, value), do: "#{key}=#{value}"

  defp integer(value) when is_integer(value), do: Integer.to_string(value)
  defp integer(_), do: nil

  defp token(nil), do: nil
  defp token(value) when is_atom(value), do: token(Atom.to_string(value))

  defp token(value) when is_binary(value) do
    if Regex.match?(@token, value), do: value, else: "invalid"
  end

  defp token(_), do: nil
end
