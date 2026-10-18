defmodule Samen.Replay.ValuesTest do
  @moduledoc """
  Lane B P1 (ADR-052 §2.2/§2.3) — the capture vocabulary: what a recorded frame may contain, and
  the precise reason every carrier is refused.

  The suite is two-sided on purpose. The ACCEPT side names one example per declared bounded type
  (and asserts the declared type list exactly, so the vocabulary cannot be widened in code and left
  undocumented here), and the REFUSE side pairs every carrier — a plaintext string, a PII shape, a
  bare `vt_` token, an oversized binary, an unbounded key, a deep or wide collection, a
  non-finite float, a `Ref` whose pointer is itself unbounded — with the `classify/1` reason it is
  refused for. A refusal that stops firing is the failure this vocabulary exists to prevent, so the
  assertion names the reason, not just `false`.

  `sanitize/2` — the P2 sanitizer — is asserted FAIL-HONEST (raises `:not_implemented`, ADR-014)
  rather than assumed: a stub that returned `{:ok, assigns}` would be the plaintext store ADR-052
  refuses, and this is the test that would catch it claiming success.
  """
  use ExUnit.Case, async: true

  alias Samen.Masked
  alias Samen.Replay.Values
  alias Samen.Replay.Values.{Placeholder, Redacted, Ref}

  @uuid "9f1c2b3a-4d5e-4f60-8a9b-0c1d2e3f4a5b"
  @abbrev_id "prs_01HZY4K7QW8N2M3P4R5S6T7V"

  describe "the bounded vocabulary (the allowlist)" do
    test "declares exactly these bounded types — a new one must be added here deliberately" do
      assert Values.bounded_types() == [
               :number,
               :boolean,
               :nil,
               :date,
               :time,
               :datetime,
               :decimal,
               :id,
               :token,
               :closed_atom,
               :masked,
               :ref,
               :redacted,
               :placeholder,
               :map,
               :list
             ]
    end

    test "accepts one example of every bounded type" do
      assert Values.bounded?(42)
      assert Values.bounded?(3.5)
      assert Values.bounded?(true)
      assert Values.bounded?(false)
      assert Values.bounded?(nil)
      assert Values.bounded?(~D[2026-10-17])
      assert Values.bounded?(~T[12:30:00])
      assert Values.bounded?(~N[2026-10-17 12:30:00])
      assert Values.bounded?(DateTime.utc_now())
      assert Values.bounded?(Decimal.new("12.50"))
      assert Values.bounded?(:closed_set_member)
      assert Values.bounded?(@uuid)
      assert Values.bounded?(@abbrev_id)
      assert Values.bounded?("broker_board")
      assert Values.bounded?(%Masked{token: "vt_0123456789", label: :driver_name})
      assert Values.bounded?(Values.ref(Driftwood.Freight.Driver, @abbrev_id, :full_name))
      assert Values.bounded?(Values.redacted(:string, 42))
      assert Values.bounded?(Values.redacted(:free_text, 900))
      assert Values.bounded?(Values.dropped(3))
      assert Values.bounded?(Values.placeholder(:shredded))
      assert Values.bounded?(Values.placeholder(:gone))
      assert Values.bounded?(Values.placeholder(:denied))
      assert Values.bounded?(%{count: 3, nested: [1, %{"token" => "broker"}]})
    end

    test "the three capture terms and the closed kind sets are declared" do
      assert Values.capture_terms() == [Ref, Redacted, Placeholder]
      assert Values.redacted_kinds() == [:string, :free_text, :dropped]
      assert Values.placeholder_kinds() == [:shredded, :gone, :denied]
      assert Values.bounds()[:binary] == 128
    end
  end

  describe "refusals — each carrier is refused for a NAMED reason" do
    test "a plaintext string" do
      assert {:refused, :raw_string, _} = Values.classify("Note!")
      assert {:refused, :raw_string, _} = Values.classify("Jane")
      assert {:refused, :raw_string, _} = Values.classify(%{tab: "Amount"})
    end

    test "a PII-shaped string — email, phone, SSN, or a person's name" do
      assert {:refused, :pii_shaped, _} = Values.classify("jane@example.com")
      assert {:refused, :pii_shaped, _} = Values.classify("+1-800-555-1234")
      assert {:refused, :pii_shaped, _} = Values.classify("123-45-6789")
      assert {:refused, :pii_shaped, _} = Values.classify("Jane Q Public")
      refute Values.bounded?("jane@example.com")
    end

    test "a bare vault token — a `vt_` value may only travel inside a `%Samen.Masked{}`" do
      assert {:refused, :bare_vault_token, _} = Values.classify("vt_0123456789abcdef")
      assert {:refused, :bare_vault_token, _} = Values.classify(%{driver: "vt_0123456789"})
    end

    test "an oversized binary and an unbounded key" do
      assert {:refused, :binary_too_long, _} = Values.classify(String.duplicate("a", 200))
      assert {:refused, :binary_too_long, _} = Values.classify(%{note: String.duplicate("a", 200)})
      assert {:refused, :unbounded_key, [""]} = Values.classify(%{"" => 1})
      assert {:refused, :unbounded_key, ["Not A Key"]} = Values.classify(%{"Not A Key" => 1})
    end

    test "a BEAM float is always finite — checked, not assumed" do
      # This is why the vocabulary needs no `:not_finite` refusal: the VM cannot hold one. Asserting
      # the fact keeps the claim honest — a large-but-finite float is accepted, and the IEEE-754
      # infinity encoding is REFUSED BY THE VM ITSELF rather than by a branch here.
      assert Values.bounded?(3.5)
      assert Values.bounded?(1.0e300)

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_term(<<131, 70, 127, 240, 0, 0, 0, 0, 0, 0>>)
      end
    end

    test "a collection past the declared bound, or nested past the declared depth" do
      assert {:refused, :collection_too_large, _} = Values.classify(List.duplicate(1, 65))
      assert {:refused, :collection_too_large, _} =
               Values.classify(Map.new(1..65, fn i -> {"k#{i}", i} end))

      assert {:refused, :too_deep, _} = Values.classify(%{a: %{b: %{c: %{d: %{e: 1}}}}})
    end

    test "an atom is bounded — but not when its NAME carries text" do
      assert {:refused, :pii_shaped, _} = Values.classify(:"Jane Q Public")
      assert {:refused, :pii_shaped, _} = Values.classify(:"jane@example.com")
      # A PII-shaped KEY is refused as a key (the map path checks the key before the value).
      assert {:refused, :unbounded_key, ["Jane Q Public"]} = Values.classify(%{"Jane Q Public" => 1})

      long_atom = String.to_atom(String.duplicate("k", 80))
      assert {:refused, :atom_too_long, _} = Values.classify(long_atom)
      assert {:refused, :unbounded_key, [^long_atom]} = Values.classify(%{long_atom => 1})
    end

    test "a term the vocabulary does not know" do
      assert {:refused, :unknown_term, _} = Values.classify(self())
      assert {:refused, :unknown_term, _} = Values.classify(make_ref())
    end
  end

  describe "refusals — the capture terms validate their own shape" do
    test "a Ref must point at a bounded record" do
      assert Values.bounded?(Values.ref(Samen.Replay.Values, @abbrev_id, :full_name, "full_name"))

      # The label is display metadata from the resource, not free text — a text label is refused.
      assert {:refused, :ref_label_not_bounded, _} =
               Values.classify(%Ref{
                 resource: Mod,
                 pk: @abbrev_id,
                 attribute: :name,
                 label: "Driver Name"
               })

      assert {:refused, :ref_pk_not_bounded, _} =
               Values.classify(%Ref{resource: Mod, pk: "Driver 42", attribute: :name})

      assert {:refused, :ref_label_not_bounded, _} =
               Values.classify(%Ref{
                 resource: Mod,
                 pk: @abbrev_id,
                 attribute: :name,
                 label: "Jane Q Public"
               })

      assert {:refused, :ref_attribute_not_an_atom, _} =
               Values.classify(%Ref{resource: Mod, pk: @abbrev_id, attribute: "name"})
    end

    test "a Redacted must use a registered kind, and a Placeholder too" do
      assert {:refused, :unregistered_redacted_kind, _} =
               Values.classify(%Redacted{kind: :whatever, length: 3})

      assert {:refused, :bad_redacted_length, _} = Values.classify(%Redacted{kind: :string, length: -1})

      assert {:refused, :unregistered_placeholder_kind, _} =
               Values.classify(%Placeholder{kind: :maybe})
    end

    test "a Masked may carry the `vt_` token — and must carry nothing else" do
      assert {:refused, :masked_token_not_a_token, _} =
               Values.classify(%Masked{token: "driver_42", label: :name})

      assert {:refused, :masked_label_not_an_atom, _} =
               Values.classify(%Masked{token: "vt_0123456789", label: "name"})
    end
  end

  describe "sanitize/2 is fail-honest at P1 (ADR-014)" do
    test "raises :not_implemented rather than returning an unsanitised assign map" do
      error =
        assert_raise ArgumentError, fn ->
          Values.sanitize(%{driver: "Jane Q Public", email: "jane@example.com"}, view: __MODULE__)
        end

      assert error.message =~ ":not_implemented"
      assert error.message =~ "ADR-052"
    end
  end
end
