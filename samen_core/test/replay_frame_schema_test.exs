defmodule Samen.Replay.FrameSchemaTest do
  @moduledoc """
  Lane B P1 (ADR-052 §2.2/§2.4) — the declared frame schema: what a recorded frame may contain,
  the named reason every other shape is refused, and the declaration checks the verifier owns.

  Three-sided on purpose:

    * **accept** — a frame per kind, carrying every vocabulary term (a `Ref`, a `Redacted`, a
      `Placeholder`, a `Masked`, a nested map/list) is admitted, and the validated frame is narrowed
      to the envelope (no stray key survives validation);
    * **refuse** — a plaintext string, a bare `vt_` token, an unknown kind, a key outside a closed
      set, an unbounded key, an oversized payload, a malformed envelope: each asserts the *named*
      reason, because a refusal that stops firing is the failure this schema exists to prevent;
    * **keep-list** — a bare text value is kept ONLY for a keep-listed key, is still refused on a
      PII shape / a `vt_` token / over the length bound, and is refused outright on any other key.
      The positive control (`page_title: "Driver roster"`) proves the refusals are not vacuous.

  The declaration half is proven **refutable**: `violations/1` is fed a tampered snapshot for each
  rule and must produce that rule — a check that can only ever return `[]` is not a check.
  """
  use ExUnit.Case, async: true

  alias Samen.Masked
  alias Samen.Replay.FrameSchema
  alias Samen.Replay.Values

  @abbrev_id "prs_01HZY4K7QW8N2M3P4R5S6T7V"

  defp frame(kind, payload) do
    %{kind: kind, index: 0, occurred_at: DateTime.utc_now(), payload: payload}
  end

  describe "the declared schema" do
    test "declares these frame kinds, each with a payload key policy" do
      assert FrameSchema.kinds() == [:mount, :params, :render, :event, :info]
      assert FrameSchema.envelope_keys() == [:kind, :index, :occurred_at, :payload]

      for kind <- FrameSchema.kinds() do
        refute FrameSchema.payload_keys(kind) == :unknown_kind
      end

      assert FrameSchema.payload_keys(:not_a_kind) == :unknown_kind
      assert FrameSchema.payload_key_policy() == %{
               mount: :bounded_keys,
               params: :bounded_keys,
               render: :bounded_keys,
               event: [:event, :params],
               info: [:tag, :count]
             }
    end

    test "every declared key, kind and keep-list entry is a bounded key" do
      assert FrameSchema.keep_list() == [:page_title, :tab, :sort, :page]
      assert Enum.all?(FrameSchema.kinds(), &Values.bounded_key?/1)
      assert Enum.all?(FrameSchema.envelope_keys(), &Values.bounded_key?/1)
      assert Enum.all?(FrameSchema.keep_list(), &Values.bounded_key?/1)
    end

    test "the byte cap is bounded by its own hard ceiling — a frame cannot be unbounded by declaration" do
      assert FrameSchema.max_payload_bytes() == 16 * 1024
      assert FrameSchema.hard_payload_ceiling() == 64 * 1024
      assert FrameSchema.max_payload_bytes() <= FrameSchema.hard_payload_ceiling()
    end
  end

  describe "accepts — one frame per kind, every vocabulary term" do
    test "a mount frame carrying the whole capture vocabulary" do
      payload = %{
        count: 3,
        ratio: 0.5,
        active: true,
        closed_at: ~N[2026-10-17 12:30:00],
        day: ~D[2026-10-17],
        money: Decimal.new("12.50"),
        view: :broker_board,
        id: @abbrev_id,
        driver: Values.ref(Driftwood.Freight.Driver, @abbrev_id, :full_name, "full_name"),
        note: Values.redacted(:free_text, 900),
        unknown: Values.dropped(3),
        subject: Values.placeholder(:shredded),
        masked: %Masked{token: "vt_0123456789", label: :driver_name},
        nested: %{rows: [1, %{"token" => "broker"}]}
      }

      assert {:ok, validated} = FrameSchema.validate(frame(:mount, payload))
      assert Map.keys(validated) |> Enum.sort() == [:index, :kind, :occurred_at, :payload]
      assert validated.payload == payload
    end

    test "each of the other kinds under its own key policy" do
      assert {:ok, _} = FrameSchema.validate(frame(:params, %{id: @abbrev_id}))
      assert {:ok, _} = FrameSchema.validate(frame(:render, %{count: 2}))
      assert {:ok, _} = FrameSchema.validate(frame(:event, %{event: "save_driver", params: %{id: @abbrev_id}}))
      assert {:ok, _} = FrameSchema.validate(frame(:info, %{tag: :refresh, count: 1}))
      assert {:ok, _} = FrameSchema.validate(frame(:info, %{}))
    end

    test "a kept text value on a keep-listed key (the positive control for the keep-list)" do
      assert {:ok, _} = FrameSchema.validate(frame(:mount, %{page_title: "Driver roster"}))
      assert {:ok, _} = FrameSchema.validate(frame(:params, %{tab: "freight"}))
    end

    test "validation NARROWS the frame to the envelope — a stray top-level key does not survive" do
      assert {:ok, validated} = FrameSchema.validate(Map.put(frame(:mount, %{count: 1}), :debug, "x"))
      refute Map.has_key?(validated, :debug)
    end

    test "the canonical form is JSON-encodable — the shape a stored jsonb frame takes" do
      payload = %{
        driver: Values.ref(Driftwood.Freight.Driver, @abbrev_id, :full_name),
        note: Values.redacted(:string, 42),
        subject: Values.placeholder(:gone),
        masked: %Masked{token: "vt_0123456789", label: :driver_name},
        day: ~D[2026-10-17]
      }

      encoded = payload |> FrameSchema.canonical() |> Jason.encode!()
      decoded = Jason.decode!(encoded)

      assert decoded["driver"]["$ref"]["pk"] == @abbrev_id
      assert decoded["note"] == %{"$redacted" => "string", "length" => 42}
      assert decoded["subject"] == %{"$placeholder" => "gone"}
      assert decoded["masked"] == %{"$masked" => "vt_0123456789", "label" => "driver_name"}
      assert decoded["day"] == "2026-10-17"
    end
  end

  describe "refuses — each shape for a NAMED reason" do
    test "a plaintext string anywhere in the payload" do
      # Neither is PII-shaped, neither is token-shaped: they are simply text a frame may not hold.
      assert {:error, {:unbounded_value, :title, :raw_string}} =
               FrameSchema.validate(frame(:mount, %{title: "Dashboard"}))

      assert {:error, {:unbounded_value, :note, :raw_string}} =
               FrameSchema.validate(frame(:mount, %{note: "Amount"}))
    end

    test "a PII-shaped value, and a bare `vt_` token" do
      assert {:error, {:unbounded_value, :email, :pii_shaped}} =
               FrameSchema.validate(frame(:mount, %{email: "jane@example.com"}))

      assert {:error, {:unbounded_value, :token, :bare_vault_token}} =
               FrameSchema.validate(frame(:mount, %{token: "vt_0123abcd"}))
    end

    test "an unknown or missing frame kind — there is no open kind list" do
      assert {:error, {:unknown_kind, :screenshot}} =
               FrameSchema.validate(%{frame(:mount, %{}) | kind: :screenshot})

      assert {:error, {:missing_kind, _}} =
               FrameSchema.validate(%{frame(:mount, %{}) | kind: nil})
    end

    test "a key outside a CLOSED payload key set" do
      assert {:error, {:undeclared_key, :info, :sneaky}} =
               FrameSchema.validate(frame(:info, %{tag: :ok, sneaky: 1}))

      assert {:error, {:undeclared_key, :event, :tag}} =
               FrameSchema.validate(frame(:event, %{event: "save_driver", tag: :ok}))
    end

    test "an unbounded key — empty, spaced, or over the character bound" do
      assert {:error, {:unbounded_key, ""}} = FrameSchema.validate(frame(:mount, %{"" => 1}))

      assert {:error, {:unbounded_key, "Not A Key"}} =
               FrameSchema.validate(frame(:mount, %{"Not A Key" => 1}))
    end

    test "an oversized payload — every leaf inside the vocabulary" do
      # A token is bounded at 64 chars (`Values.bounds/0`), so the widest leaf the vocabulary
      # permits is used: 64 × 64 of them are then too many bytes for the cap on their own.
      token = String.duplicate("a", 60)
      payload = Map.new(1..64, fn i -> {"key_#{i}", List.duplicate(token, 64)} end)

      # Non-vacuity: every leaf is a bounded token, so the size refusal is load-bearing alone.
      assert Values.bounded?(payload)

      assert {:error, {:payload_too_large, bytes, 16_384}} = FrameSchema.validate(frame(:mount, payload))
      assert bytes > 16_384
    end

    test "a malformed envelope or payload" do
      assert {:error, {:bad_index, -1}} = FrameSchema.validate(%{frame(:mount, %{}) | index: -1})
      assert {:error, {:bad_index, "0"}} = FrameSchema.validate(%{frame(:mount, %{}) | index: "0"})
      assert {:error, {:bad_occurred_at, "now"}} =
               FrameSchema.validate(%{frame(:mount, %{}) | occurred_at: "now"})

      assert {:error, {:payload_not_a_map, ["driver"]}} =
               FrameSchema.validate(%{frame(:mount, %{}) | payload: ["driver"]})

      assert {:error, {:not_a_frame, "frame"}} = FrameSchema.validate("frame")
    end
  end

  describe "the keep-list is a narrow hole, not a smuggling path" do
    test "a keep-listed key refuses a PII shape, a `vt_` token, and an over-long value" do
      assert {:error, {:keep_list_value_pii_shaped, :page_title, :email}} =
               FrameSchema.validate(frame(:mount, %{page_title: "jane@example.com"}))

      assert {:error, {:keep_list_value_pii_shaped, :page_title, :phone}} =
               FrameSchema.validate(frame(:mount, %{page_title: "+1-800-555-1234"}))

      assert {:error, {:bare_vault_token, :page_title}} =
               FrameSchema.validate(frame(:mount, %{page_title: "vt_0123abcd"}))

      assert {:error, {:keep_list_value_too_long, :page_title}} =
               FrameSchema.validate(frame(:mount, %{page_title: String.duplicate("a", 200)}))
    end

    test "the same text on a NON-keep-listed key is refused as a raw string" do
      assert {:error, {:unbounded_value, :note, :raw_string}} =
               FrameSchema.validate(frame(:mount, %{note: "Dashboard"}))
    end
  end

  describe "violations/1 — the declaration checks are refutable" do
    test "the real schema is clean (the gate's green side)" do
      assert FrameSchema.violations() == []
    end

    test "a frame kind with no payload key policy (the `inject_kind` seam the exit-code test uses)" do
      assert [%{rule: :kind_coverage, message: message} | _] =
               FrameSchema.violations(inject_kind: :ghost)

      assert message =~ ":ghost"
    end

    test "a payload key policy for an UNDECLARED kind" do
      tampered = Map.update!(FrameSchema.snapshot(), :payload_keys, &Map.put(&1, :ghost, [:tag]))

      assert Enum.any?(FrameSchema.violations(snapshot: tampered), &(&1.rule == :kind_coverage))
    end

    test "an EMPTY closed payload key set" do
      tampered =
        Map.update!(FrameSchema.snapshot(), :payload_keys, &Map.put(&1, :info, []))

      assert Enum.any?(FrameSchema.violations(snapshot: tampered), &(&1.rule == :closed_keys))
    end

    test "a closed payload key set containing an unbounded key" do
      tampered =
        Map.update!(FrameSchema.snapshot(), :payload_keys, &Map.put(&1, :info, [:tag, "Not A Key"]))

      assert Enum.any?(FrameSchema.violations(snapshot: tampered), &(&1.rule == :closed_keys))
    end

    test "a keep-list that shrank, or that carries an unbounded key" do
      shrunk = Map.update!(FrameSchema.snapshot(), :keep_list, fn _ -> [:page_title] end)

      assert Enum.any?(FrameSchema.violations(snapshot: shrunk), &(&1.rule == :keep_list))

      unbounded =
        Map.update!(FrameSchema.snapshot(), :keep_list, fn keep -> keep ++ [""] end)

      assert Enum.any?(FrameSchema.violations(snapshot: unbounded), &(&1.rule == :keep_list))
    end

    test "a byte cap above its hard ceiling, or a non-positive one" do
      above =
        Map.update!(FrameSchema.snapshot(), :max_payload_bytes, fn _ -> 65 * 1024 end)

      assert Enum.any?(FrameSchema.violations(snapshot: above), &(&1.rule == :size_bound))

      zero = Map.put(FrameSchema.snapshot(), :max_payload_bytes, 0)
      assert Enum.any?(FrameSchema.violations(snapshot: zero), &(&1.rule == :size_bound))
    end

    test "a schema that shrank below the non-vacuity floor" do
      shrunk =
        FrameSchema.snapshot()
        |> Map.put(:kinds, [:mount])
        |> Map.put(:payload_keys, %{mount: :bounded_keys})

      assert Enum.any?(FrameSchema.violations(snapshot: shrunk), &(&1.rule == :non_vacuity))
    end

    test "a carrier-shaped kind or envelope key" do
      tampered =
        Map.put(FrameSchema.snapshot(), :envelope_keys, [:kind, :index, :occurred_at, :payload, :vt_token])

      assert Enum.any?(FrameSchema.violations(snapshot: tampered), &(&1.rule == :no_carriers))
    end
  end
end
