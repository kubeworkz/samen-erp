defmodule Samen.Web.ProviderIngestIngressTest do
  @moduledoc """
  The signed provider-ingestion endpoint, end-to-end through the real pipeline.

  Attacker-first, each red path paired with a green control:

    * valid HMAC ⇒ 202 + redacted durable envelope
    * tampered body / wrong secret / missing signature / stale timestamp ⇒ 401,
      NOTHING persisted
    * signature bound to the idempotency key ⇒ changing the key breaks it
    * duplicate idempotency key ⇒ 200 no-op, exactly one row
    * same key with different content ⇒ 409, the original is not overwritten
    * same event id under a fresh key ⇒ 200 no-op
    * unsupported schema version ⇒ 415 with the supported versions advertised
    * malformed/missing-version envelopes ⇒ 400, nothing persisted
    * oversize ⇒ 413 before crypto; unknown provider ⇒ 404
    * half-implemented or badly-redacting adapter ⇒ 503/500, nothing persisted
    * per-provider flood and per-IP bad-signature budgets ⇒ 429
    * the audit line is PII-free
  """

  use Samen.WebTest.DataCase, async: false

  import Plug.Test

  alias Samen.Ingest.Contract
  alias Samen.Ingest.Event
  alias Samen.Ingest.Log
  alias Samen.Web.Ingest.Ingress
  alias Samen.Web.RateLimit
  alias Samen.WebTest.RateLimitFlood

  @secret "pgi_ingress_test_secret_1a2b3c4d5e6f"
  @pii_email "leak-jane@example.com"
  @pii_name "Jane Leaky"

  defmodule RedactingAdapter do
    @moduledoc false
    @behaviour Samen.Ingest.Provider

    @impl true
    def redact_payload(payload), do: Map.drop(payload, ["email", "name"])

    @impl true
    def handle(_envelope, _opts), do: :ok
  end

  defmodule IncompleteAdapter do
    @moduledoc false
    def redact_payload(payload), do: payload
  end

  defmodule BadRedactionAdapter do
    @moduledoc false
    @behaviour Samen.Ingest.Provider

    @impl true
    def redact_payload(_payload), do: :not_a_map

    @impl true
    def handle(_envelope, _opts), do: :ok
  end

  setup do
    RateLimitFlood.pin!(%{
      provider_ingest: {1000, 60_000},
      provider_ingest_bad_sig: {60, 60_000}
    })

    RateLimit.reset()
    on_exit(fn -> Application.delete_env(:samen_core, Samen.Ingest) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp providers do
    %{"acme" => {RedactingAdapter, %{secret: @secret, schema_versions: [1], max_attempts: 3}}}
  end

  defp body(overrides \\ %{}) do
    %{
      "schema_version" => 1,
      "event_id" => "run_#{System.unique_integer([:positive])}",
      "event_type" => "payroll.register",
      "occurred_at" => "2026-09-30T12:00:00Z",
      "payload" => %{
        "total_cents" => 125_000,
        "email" => @pii_email,
        "name" => @pii_name
      }
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp signed(raw, opts \\ []) do
    timestamp = Keyword.get(opts, :ts, System.os_time(:second))
    key = Keyword.get(opts, :key, "idem_#{System.unique_integer([:positive])}")
    secret = Keyword.get(opts, :secret, @secret)

    [
      {"samen-ingest-signature", Contract.sign(raw, timestamp, key, secret)},
      {"idempotency-key", key},
      {"content-type", "application/json"}
    ]
  end

  defp post_ingest(provider, raw, headers, opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    configured = Keyword.get(opts, :providers, providers())

    conn(:post, "/ingest/#{provider}", raw)
    |> Map.put(:path_params, %{"provider" => provider})
    |> Map.put(:params, %{"provider" => provider})
    |> Map.put(:remote_ip, ip)
    |> Map.put(:req_headers, headers)
    |> Plug.Conn.assign(:raw_webhook_body, raw)
    |> Ingress.ingest(
      repo: Repo,
      providers: configured,
      max_body_bytes: Keyword.get(opts, :max_body_bytes, 4096),
      tolerance_seconds: 300
    )
  end

  defp count, do: Repo.aggregate(Event, :count)
  defp event_id(raw), do: Jason.decode!(raw)["event_id"]

  # ---------------------------------------------------------------------------
  # Green control

  test "a valid signed delivery is redacted, persisted and accepted" do
    raw = body()
    conn = post_ingest("acme", raw, signed(raw))

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"status" => "accepted"}
    assert count() == 1

    [row] = Repo.all(Event)
    assert row.provider == "acme"
    assert row.schema_version == 1
    assert row.event_id == event_id(raw)
    assert row.event_type == "payroll.register"
    assert row.status == "received"
    assert row.max_attempts == 3
    assert row.payload == %{"total_cents" => 125_000}
    refute Map.has_key?(row.payload, "email")
    refute Map.has_key?(row.payload, "name")
    assert row.payload_digest == Contract.payload_digest(row.payload)
  end

  # ---------------------------------------------------------------------------
  # Authentication red paths

  describe "signature verification" do
    test "a tampered body is 401 and NOTHING is persisted" do
      raw = body()
      request_headers = signed(raw)
      tampered = String.replace(raw, "125000", "1")

      conn = post_ingest("acme", tampered, request_headers)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_signature"}
      assert count() == 0
    end

    test "a wrong secret is 401 and nothing is persisted" do
      raw = body()
      conn = post_ingest("acme", raw, signed(raw, secret: "whsec_attacker"))

      assert conn.status == 401
      assert count() == 0
    end

    test "a missing signature is 401, fail-closed" do
      raw = body()

      conn =
        post_ingest("acme", raw, [
          {"idempotency-key", "idem_missing_sig"},
          {"content-type", "application/json"}
        ])

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_signature"}
      assert count() == 0
    end

    test "a stale timestamp is 401, anti-replay" do
      raw = body()
      conn = post_ingest("acme", raw, signed(raw, ts: System.os_time(:second) - 3600))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "stale_timestamp"}
      assert count() == 0
    end

    test "changing the idempotency key after signing breaks the HMAC (key is bound)" do
      raw = body()
      key = "idem_bound_key"
      signature = Contract.sign(raw, System.os_time(:second), key, @secret)

      conn =
        post_ingest("acme", raw, [
          {"samen-ingest-signature", signature},
          {"idempotency-key", "idem_different_key"},
          {"content-type", "application/json"}
        ])

      assert conn.status == 401
      assert count() == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Idempotency + replay

  describe "idempotency and replay" do
    test "the same delivery retried is a 200 duplicate with exactly one row" do
      raw = body()
      request_headers = signed(raw, key: "idem_retry_same")

      first = post_ingest("acme", raw, request_headers)
      second = post_ingest("acme", raw, request_headers)

      assert first.status == 202
      assert second.status == 200
      assert Jason.decode!(second.resp_body) == %{"status" => "duplicate"}
      assert count() == 1
    end

    test "the same key with different content is a 409 and does not overwrite" do
      key = "idem_conflict_key"

      raw_one = body(%{"event_id" => "evt_conflict_one"})
      assert post_ingest("acme", raw_one, signed(raw_one, key: key)).status == 202

      raw_two = body(%{"event_id" => "evt_conflict_two", "payload" => %{"total_cents" => 1}})
      conn = post_ingest("acme", raw_two, signed(raw_two, key: key))

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "idempotency_conflict"}
      assert count() == 1

      [row] = Repo.all(Event)
      assert row.event_id == "evt_conflict_one"
      assert row.payload == %{"total_cents" => 125_000}
    end

    test "the same event id under a fresh key is a duplicate (content matches)" do
      raw_one = body(%{"event_id" => "evt_replay_same"})
      raw_two = body(%{"event_id" => "evt_replay_same"})

      first = post_ingest("acme", raw_one, signed(raw_one, key: "idem_replay_one"))
      second = post_ingest("acme", raw_two, signed(raw_two, key: "idem_replay_two"))

      assert first.status == 202
      assert second.status == 200
      assert count() == 1
    end

    test "the same event id with different content is a 409 event conflict" do
      raw_one = body(%{"event_id" => "evt_event_conflict"})
      assert post_ingest("acme", raw_one, signed(raw_one, key: "idem_event_one")).status == 202

      raw_two =
        body(%{
          "event_id" => "evt_event_conflict",
          "payload" => %{"total_cents" => 999}
        })

      conn = post_ingest("acme", raw_two, signed(raw_two, key: "idem_event_two"))

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "event_conflict"}
      assert count() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Schema version + malformed envelopes

  describe "schema version and envelope shape" do
    test "an unsupported schema version is 415 and advertises the supported versions" do
      raw = body(%{"schema_version" => 2})
      conn = post_ingest("acme", raw, signed(raw))

      assert conn.status == 415
      assert Jason.decode!(conn.resp_body) == %{"error" => "unsupported_schema_version"}
      assert Plug.Conn.get_resp_header(conn, "samen-schema-versions") == ["1"]
      assert count() == 0
    end

    test "a missing schema version is 400 and nothing is persisted" do
      raw =
        Jason.encode!(%{
          "event_id" => "evt_no_version",
          "event_type" => "payroll.register",
          "occurred_at" => "2026-09-30T12:00:00Z",
          "payload" => %{}
        })

      conn = post_ingest("acme", raw, signed(raw))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_schema_version"}
      assert count() == 0
    end

    test "malformed JSON with a valid signature is 400 and nothing is persisted" do
      raw = "{not json"
      conn = post_ingest("acme", raw, signed(raw))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "malformed_envelope"}
      assert count() == 0
    end

    test "a missing idempotency key is 400 and nothing is persisted" do
      raw = body()
      signature = Contract.sign(raw, System.os_time(:second), "idem_x", @secret)

      conn =
        post_ingest("acme", raw, [
          {"samen-ingest-signature", signature},
          {"content-type", "application/json"}
        ])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_idempotency_key"}
      assert count() == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Bounds + fail-closed dependencies

  test "an oversized body is 413 before verification, nothing persisted" do
    raw = body(%{"pad" => String.duplicate("x", 5000)})
    conn = post_ingest("acme", raw, signed(raw))

    assert conn.status == 413
    assert Jason.decode!(conn.resp_body) == %{"error" => "payload_too_large"}
    assert count() == 0
  end

  test "an unknown provider is 404, nothing persisted" do
    raw = body()
    conn = post_ingest("nope", raw, signed(raw))

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "unknown_provider"}
    assert count() == 0
  end

  test "a half-implemented adapter is 503 with Retry-After, nothing persisted" do
    raw = body()

    conn =
      post_ingest("acme", raw, signed(raw),
        providers: %{"acme" => {IncompleteAdapter, %{secret: @secret}}}
      )

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => "provider_not_configured"}
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]
    assert count() == 0
  end

  test "an adapter returning a non-map redaction is 500, nothing persisted" do
    raw = body()

    conn =
      post_ingest("acme", raw, signed(raw),
        providers: %{"acme" => {BadRedactionAdapter, %{secret: @secret}}}
      )

    assert conn.status == 500
    assert Jason.decode!(conn.resp_body) == %{"error" => "adapter_error"}
    assert count() == 0
  end

  # ---------------------------------------------------------------------------
  # Rate limits

  describe "rate limits" do
    test "the per-provider flood guard 429s over the limit; only accepted rows persist" do
      RateLimitFlood.pin!(%{
        provider_ingest: {3, 60_000},
        provider_ingest_bad_sig: {60, 60_000}
      })

      RateLimit.reset()

      statuses =
        for _ <- 1..4 do
          raw = body()
          post_ingest("acme", raw, signed(raw)).status
        end

      assert statuses == [202, 202, 202, 429]
      assert count() == 3
    end

    test "the per-IP bad-signature budget 429s before crypto, isolated per IP" do
      RateLimitFlood.pin!(%{
        provider_ingest: {1000, 60_000},
        provider_ingest_bad_sig: {2, 60_000}
      })

      RateLimit.reset()

      raw = body()
      bad = signed(raw, secret: "whsec_attacker")

      assert post_ingest("acme", raw, bad, ip: {10, 0, 0, 1}).status == 401
      assert post_ingest("acme", raw, bad, ip: {10, 0, 0, 1}).status == 401
      assert post_ingest("acme", raw, bad, ip: {10, 0, 0, 1}).status == 429

      # Positive control: a fresh IP is not charged against the attacker's budget.
      assert post_ingest("acme", raw, bad, ip: {10, 0, 0, 2}).status == 401
    end
  end

  # ---------------------------------------------------------------------------
  # PII-safe logging

  test "a rejection emits a PII-free audit line" do
    raw = body()
    bad = signed(raw, secret: "whsec_attacker")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert post_ingest("acme", raw, bad).status == 401
      end)

    assert log =~ "provider_ingest"
    assert log =~ "outcome=unauthorized"
    assert log =~ "provider=acme"

    refute log =~ @pii_email
    refute log =~ @pii_name
    refute log =~ "whsec_attacker"
    refute log =~ event_id(raw)
  end

  test "an unknown provider is fingerprinted in the audit line, never logged raw" do
    # BEFORE authentication the path segment is entirely attacker-controlled:
    # `/ingest/leak-jane@example.com` must not copy that address into logs.
    leaked = "leak-jane@example.com"
    raw = body()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = post_ingest(leaked, raw, signed(raw))
        assert conn.status == 404
        assert Jason.decode!(conn.resp_body) == %{"error" => "unknown_provider"}
      end)

    assert log =~ "outcome=unknown_provider"
    assert log =~ "provider=unresolved-#{Log.fingerprint(leaked)}"
    refute log =~ leaked
    assert count() == 0
  end
end
