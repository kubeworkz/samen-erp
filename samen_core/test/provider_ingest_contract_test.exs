defmodule Samen.ProviderIngestContractTest do
  @moduledoc """
  The signed provider-ingestion contract — vendor-free red paths.

  Pins the properties every provider connector inherits:

    * HMAC over the exact raw body + timestamp + idempotency key (`Contract`)
    * stale/future timestamp rejection and replay-safe header parsing
    * explicit schema version negotiation
    * durable `{provider, idempotency_key}` and `{provider, event_id}` uniqueness
    * a BOUNDED retry budget that dead-letters at the configured attempt
    * a PII-safe audit line built from allowlisted, fingerprinted fields
  """

  use ExUnit.Case, async: false

  alias Samen.Ingest
  alias Samen.Ingest.{Contract, Event, Log, Worker}
  alias SamenCore.TestRepo

  @secret "pgi_ingest_test_secret_9f8e7d6c5b4a"
  @key "idem_test_key_1"
  @pii_email "leak-jane@example.com"
  @pii_name "Jane Leaky"

  defmodule SuccessAdapter do
    @moduledoc false
    @behaviour Samen.Ingest.Provider
    @impl true
    def redact_payload(payload), do: payload
    @impl true
    def handle(_envelope, _opts), do: :ok
  end

  defmodule FailAdapter do
    @moduledoc false
    @behaviour Samen.Ingest.Provider
    @impl true
    def redact_payload(payload), do: payload
    @impl true
    def handle(_envelope, _opts), do: {:error, :boom}
  end

  defmodule DiscardAdapter do
    @moduledoc false
    @behaviour Samen.Ingest.Provider
    @impl true
    def redact_payload(payload), do: payload
    @impl true
    def handle(_envelope, _opts), do: {:discard, :permanently_bad}
  end

  defmodule RaiseAdapter do
    @moduledoc false
    @behaviour Samen.Ingest.Provider
    @impl true
    def redact_payload(payload), do: payload
    @impl true
    def handle(_envelope, _opts), do: raise("handler boom")
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Contract

  defp body(overrides \\ %{}) do
    %{
      "schema_version" => 1,
      "event_id" => "run_#{System.unique_integer([:positive])}",
      "event_type" => "payroll.register",
      "occurred_at" => "2026-09-30T12:00:00Z",
      "payload" => %{"total_cents" => 125_000, "email" => @pii_email, "name" => @pii_name}
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp headers(raw, opts \\ []) do
    timestamp = Keyword.get(opts, :ts, System.os_time(:second))
    key = Keyword.get(opts, :key, @key)
    secret = Keyword.get(opts, :secret, @secret)

    [
      {"samen-ingest-signature", Contract.sign(raw, timestamp, key, secret)},
      {"idempotency-key", key}
    ]
  end

  defp verify(raw, request_headers, opts \\ []) do
    Contract.verify(raw, request_headers, Keyword.merge([secret: @secret], opts))
  end

  describe "signed envelope" do
    test "a correctly signed v1 envelope verifies (green control)" do
      raw = body()

      assert {:ok, envelope} = verify(raw, headers(raw))
      assert envelope.schema_version == 1
      assert envelope.idempotency_key == @key
      assert envelope.event_type == "payroll.register"
      assert envelope.payload["total_cents"] == 125_000
      assert DateTime.compare(envelope.occurred_at, ~U[2026-09-30 12:00:00Z]) == :eq
    end

    test "a tampered body is refused (bad signature)" do
      raw = body()
      request_headers = headers(raw)
      tampered = String.replace(raw, "125000", "1")

      assert {:error, :bad_signature} = verify(tampered, request_headers)
    end

    test "a wrong secret is refused" do
      raw = body()

      assert {:error, :bad_signature} = verify(raw, headers(raw, secret: "whsec_attacker"))
    end

    test "a missing signature header fails closed" do
      raw = body()

      assert {:error, :missing_signature} = verify(raw, [{"idempotency-key", @key}])
    end

    test "a malformed signature header is refused" do
      raw = body()

      assert {:error, :malformed_signature} =
               verify(raw, [
                 {"samen-ingest-signature", "not-a-signature"},
                 {"idempotency-key", @key}
               ])
    end

    test "stale and future timestamps are refused EVEN with a valid HMAC" do
      raw = body()

      assert {:error, :stale_timestamp} =
               verify(raw, headers(raw, ts: System.os_time(:second) - 3600))

      assert {:error, :stale_timestamp} =
               verify(raw, headers(raw, ts: System.os_time(:second) + 360))
    end

    test "a missing or malformed idempotency key is refused" do
      raw = body()
      signature = Contract.sign(raw, System.os_time(:second), @key, @secret)

      assert {:error, :missing_idempotency_key} =
               verify(raw, [{"samen-ingest-signature", signature}])

      bad_key = "bad key with spaces"
      bad_signature = Contract.sign(raw, System.os_time(:second), bad_key, @secret)

      assert {:error, :invalid_idempotency_key} =
               verify(raw, [
                 {"samen-ingest-signature", bad_signature},
                 {"idempotency-key", bad_key}
               ])
    end

    test "the signature is BOUND to the idempotency key (anti-replay under a new key)" do
      raw = body()
      signature = Contract.sign(raw, System.os_time(:second), @key, @secret)

      assert {:error, :bad_signature} =
               verify(raw, [
                 {"samen-ingest-signature", signature},
                 {"idempotency-key", "a_different_key"}
               ])
    end

    test "malformed JSON and non-object bodies are refused after a valid HMAC" do
      assert {:error, :malformed_body} = verify("{not json", headers("{not json"))

      array = Jason.encode!([1, 2, 3])
      assert {:error, :malformed_body} = verify(array, headers(array))
    end

    test "a missing schema version is refused and an unsupported one is typed" do
      missing =
        Jason.encode!(%{
          "event_id" => "evt_1",
          "event_type" => "payroll.register",
          "occurred_at" => "2026-09-30T12:00:00Z",
          "payload" => %{}
        })

      assert {:error, :missing_schema_version} = verify(missing, headers(missing))

      unsupported = body(%{"schema_version" => 2})

      assert {:error, {:unsupported_schema_version, 2}} =
               verify(unsupported, headers(unsupported))
    end

    test "invalid envelope fields fail closed with a typed field" do
      raw = body(%{"event_id" => "has space"})
      assert {:error, {:invalid_envelope, :event_id}} = verify(raw, headers(raw))

      raw = body(%{"event_type" => "Payroll.Register"})
      assert {:error, {:invalid_envelope, :event_type}} = verify(raw, headers(raw))

      raw = body(%{"occurred_at" => "not-a-date"})
      assert {:error, {:invalid_envelope, :occurred_at}} = verify(raw, headers(raw))

      raw = body(%{"payload" => [1, 2]})
      assert {:error, {:invalid_envelope, :payload}} = verify(raw, headers(raw))
    end

    test "no configured secret is a fail-closed not_configured, never an accept" do
      raw = body()

      assert {:error, :not_configured} = Contract.verify(raw, headers(raw), [])
    end

    test "the payload digest is order-independent and content-sensitive" do
      left = %{"b" => [1, %{"z" => 2, "a" => 3}], "a" => 1}
      right = %{"a" => 1, "b" => [1, %{"a" => 3, "z" => 2}]}

      assert Contract.payload_digest(left) == Contract.payload_digest(right)
      refute Contract.payload_digest(%{"a" => 1}) == Contract.payload_digest(%{"a" => 2})
      assert Contract.payload_digest(%{"a" => 1}) =~ ~r/^[0-9a-f]{64}$/
    end
  end

  # ---------------------------------------------------------------------------
  # Durable idempotency + replay store

  defp event_attrs(overrides \\ %{}) do
    %{
      provider: "acme",
      idempotency_key: "idem_#{System.unique_integer([:positive])}",
      schema_version: 1,
      event_id: "evt_#{System.unique_integer([:positive])}",
      event_type: "payroll.register",
      occurred_at: DateTime.utc_now(),
      payload: %{"total_cents" => 100},
      payload_digest: "digest_a",
      max_attempts: 3
    }
    |> Map.merge(Map.new(overrides))
  end

  defp count, do: TestRepo.aggregate(Event, :count)

  defp job(event) do
    %Oban.Job{
      args: %{"event_id" => event.id, "repo" => to_string(TestRepo)},
      attempt: 1,
      max_attempts: event.max_attempts
    }
  end

  describe "durable idempotency + replay store" do
    test "a first delivery inserts; an exact retry is a duplicate with no second row" do
      attrs = event_attrs()

      assert {:ok, :inserted, first} = Event.insert_received(TestRepo, attrs)
      assert {:ok, :duplicate, same} = Event.insert_received(TestRepo, attrs)

      assert same.id == first.id
      assert count() == 1
      assert first.status == "received"
      assert first.attempt_count == 0
      assert first.max_attempts == 3
    end

    test "the same idempotency key with DIFFERENT content is a conflict, not an overwrite" do
      assert {:ok, :inserted, first} =
               Event.insert_received(
                 TestRepo,
                 event_attrs(idempotency_key: "same_key", event_id: "evt_a", payload_digest: "d1")
               )

      assert {:error, :idempotency_conflict, existing} =
               Event.insert_received(
                 TestRepo,
                 event_attrs(idempotency_key: "same_key", event_id: "evt_b", payload_digest: "d2")
               )

      assert existing.id == first.id
      assert Event.get(TestRepo, first.id).payload_digest == "d1"
      assert count() == 1
    end

    test "the same event id under a fresh key is a replay when the content matches" do
      assert {:ok, :inserted, first} =
               Event.insert_received(
                 TestRepo,
                 event_attrs(idempotency_key: "key_a", event_id: "evt_same", payload_digest: "d1")
               )

      assert {:ok, :duplicate, existing} =
               Event.insert_received(
                 TestRepo,
                 event_attrs(idempotency_key: "key_b", event_id: "evt_same", payload_digest: "d1")
               )

      assert existing.id == first.id
      assert count() == 1
    end

    test "the same event id with DIFFERENT content is an event conflict" do
      assert {:ok, :inserted, first} =
               Event.insert_received(
                 TestRepo,
                 event_attrs(idempotency_key: "key_a", event_id: "evt_same", payload_digest: "d1")
               )

      assert {:error, :event_conflict, existing} =
               Event.insert_received(
                 TestRepo,
                 event_attrs(idempotency_key: "key_b", event_id: "evt_same", payload_digest: "d2")
               )

      assert existing.id == first.id
      assert count() == 1
    end

    test "a dead letter stores only a bounded token, never a payload echo" do
      {:ok, :inserted, row} =
        Event.insert_received(
          TestRepo,
          event_attrs(payload: %{"email" => @pii_email, "name" => @pii_name})
        )

      {:ok, dead} = Event.mark_dead(TestRepo, row, "handler failed for #{@pii_email}")

      assert dead.status == "dead"
      assert dead.last_error == "error"
      refute dead.last_error =~ @pii_email
      refute dead.last_error =~ @pii_name
    end

    test "an operator replay resets the envelope and grants a fresh bounded budget" do
      {:ok, :inserted, row} = Event.insert_received(TestRepo, event_attrs())
      {:ok, processing} = Event.mark_processing(TestRepo, row)
      assert processing.attempt_count == 1

      {:ok, dead} = Event.mark_dead(TestRepo, processing, :boom)
      {:ok, replayed} = Event.reset_for_replay(TestRepo, dead)

      assert replayed.status == "received"
      assert replayed.attempt_count == 0
      assert replayed.last_error == nil
      assert replayed.processed_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Bounded retry worker

  describe "bounded retry worker" do
    setup do
      Application.put_env(:samen_core, Samen.Ingest,
        providers: %{"acme" => {SuccessAdapter, %{secret: "test"}}}
      )

      on_exit(fn -> Application.delete_env(:samen_core, Samen.Ingest) end)
      :ok
    end

    test "a successful handler marks the envelope processed" do
      {:ok, :inserted, event} = Event.insert_received(TestRepo, event_attrs())

      assert :ok = Worker.perform(job(event))

      processed = Event.get(TestRepo, event.id)
      assert processed.status == "processed"
      assert processed.attempt_count == 1
      assert %DateTime{} = processed.processed_at
    end

    test "a failing handler retries only to the stored budget, then dead-letters" do
      Application.put_env(:samen_core, Samen.Ingest,
        providers: %{"acme" => {FailAdapter, %{secret: "test"}}}
      )

      {:ok, :inserted, event} = Event.insert_received(TestRepo, event_attrs(max_attempts: 2))

      assert {:error, :boom} = Worker.perform(job(event))
      assert Event.get(TestRepo, event.id).status == "processing"
      assert Event.get(TestRepo, event.id).attempt_count == 1

      assert {:discard, :boom} = Worker.perform(job(event))

      dead = Event.get(TestRepo, event.id)
      assert dead.status == "dead"
      assert dead.attempt_count == 2
      assert dead.last_error == "boom"

      # A third run must not exceed the bound or re-open the terminal envelope.
      assert :ok = Worker.perform(job(event))
      assert Event.get(TestRepo, event.id).attempt_count == 2
    end

    test "a permanent discard dead-letters immediately" do
      Application.put_env(:samen_core, Samen.Ingest,
        providers: %{"acme" => {DiscardAdapter, %{secret: "test"}}}
      )

      {:ok, :inserted, event} = Event.insert_received(TestRepo, event_attrs())

      assert {:discard, :permanently_bad} = Worker.perform(job(event))

      dead = Event.get(TestRepo, event.id)
      assert dead.status == "dead"
      assert dead.attempt_count == 1
    end

    test "a raising handler is a bounded retry and its message never reaches last_error" do
      Application.put_env(:samen_core, Samen.Ingest,
        providers: %{"acme" => {RaiseAdapter, %{secret: "test"}}}
      )

      {:ok, :inserted, event} =
        Event.insert_received(TestRepo, event_attrs(max_attempts: 1))

      assert {:discard, {:handler_raised, RuntimeError}} = Worker.perform(job(event))

      dead = Event.get(TestRepo, event.id)
      assert dead.status == "dead"
      refute dead.last_error =~ @pii_email
      assert dead.last_error == "error"
    end

    test "a provider removed from config dead-letters loudly instead of dropping the row" do
      Application.put_env(:samen_core, Samen.Ingest, providers: %{})

      {:ok, :inserted, event} = Event.insert_received(TestRepo, event_attrs())

      assert {:discard, :provider_not_configured} = Worker.perform(job(event))

      dead = Event.get(TestRepo, event.id)
      assert dead.status == "dead"
      assert dead.last_error == "provider_not_configured"
    end

    test "the enqueued job carries token-only args" do
      changeset = Worker.new(%{"event_id" => "ing_123"})
      args = Ecto.Changeset.get_field(changeset, :args)

      assert args == %{"event_id" => "ing_123"}
      refute Map.has_key?(args, "payload")
      refute Map.has_key?(args, "secret")
    end

    test "the retry budget is clamped to the hard ceiling" do
      assert Ingest.clamp_attempts(1_000) == Ingest.hard_max_attempts()
      assert Ingest.clamp_attempts(0) == Ingest.default_max_attempts()
      assert Ingest.clamp_attempts(nil) == Ingest.default_max_attempts()
      assert Ingest.clamp_attempts(3) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # PII-safe logging

  describe "PII-safe audit line" do
    test "only allowlisted fields are rendered and identifiers are fingerprinted" do
      line =
        Log.format(:accepted,
          provider: "acme_payroll",
          status: 202,
          schema_version: 1,
          event_id: "run-2026-09",
          idempotency_key: "idem_secret_value",
          body_bytes: 512,
          duration_ms: 4,
          payload: %{"email" => @pii_email, "name" => @pii_name},
          secret: "shh"
        )

      assert line =~ "outcome=accepted"
      assert line =~ "provider=acme_payroll"
      assert line =~ "status=202"
      assert line =~ "schema_version=1"
      assert line =~ "event_ref=#{Log.fingerprint("run-2026-09")}"
      assert line =~ "idempotency_ref=#{Log.fingerprint("idem_secret_value")}"

      refute line =~ "run-2026-09"
      refute line =~ "idem_secret_value"
      refute line =~ @pii_email
      refute line =~ @pii_name
      refute line =~ "shh"
      refute line =~ "reason="
    end

    test "a non-token reason (payload-shaped) is dropped instead of echoed" do
      line = Log.format(:invalid_request, provider: "acme", reason: %{"email" => @pii_email})

      refute line =~ @pii_email
      refute line =~ "reason="
      assert line =~ "provider=acme"
    end

    test "emit writes the same PII-free line at warning level" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Log.emit(:warning, :unauthorized,
            provider: "acme",
            status: 401,
            event_id: "run-1",
            idempotency_key: "idem-1"
          )
        end)

      assert log =~ "provider_ingest"
      assert log =~ "outcome=unauthorized"
      assert log =~ "event_ref="
      refute log =~ "run-1"
      refute log =~ "idem-1"
    end
  end
end
