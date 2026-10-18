defmodule Samen.Replay.FrameSchema do
  @moduledoc """
  The **declared frame schema** for masked session replay (ADR-052 §2.2/§2.4, Lane B P1) — the
  single source of truth `mix samen.verify.replay_schema` reads and `validate/1` enforces.

  ## A frame is a declared kind with a closed payload

  | Frame kind | What it is | Payload keys |
  |---|---|---|
  | `:mount` | the assign map at mount, sanitized | any **bounded** key (`Values.bounded_key?/1`) |
  | `:params` | `handle_params` params, shape only | any bounded key |
  | `:render` | the assigns that changed | any bounded key |
  | `:event` | an event name + per-param shape | `:event`, `:params` — closed |
  | `:info` | a message **tag** only | `:tag`, `:count` — closed |

  Every frame also carries the envelope `#{inspect([:kind, :index, :occurred_at, :payload])}`. No DOM,
  no HTML, no screenshots, no client JS channel: those are out of scope for v1 entirely.

  ## Four refusal rules, in order

    1. **Unknown kind** → `{:error, {:unknown_kind, kind}}`. There is no open kind list.
    2. **Undeclared key** → `{:error, {:undeclared_key, kind, key}}` (a closed policy), or
       `{:error, {:unbounded_key, key}}` when the key itself is not a bounded key.
    3. **Unbounded value** → `{:error, {:unbounded_value, key, why}}`, where `why` is the vocabulary's
       own reason (`:raw_string`, `:pii_shaped`, `:bare_vault_token`, …). A **bare binary** is only
       kept when it is id/token-shaped; anything else needs its key on the **keep-list**
       (`#{inspect([:page_title, :tab, :sort, :page])}`), and then the value still has to pass
       `Samen.PiiValueShape` — so a keep-list key cannot smuggle an email, and never a `vt_` token.
    4. **Oversized payload** → `{:error, {:payload_too_large, bytes, max}}`, measured on the
       **canonical encoding** (`canonical/1` — the terms flattened to JSON-ready maps, which is also
       the only shape a stored `jsonb` frame can take). `max_payload_bytes/0` is bounded by
       `hard_payload_ceiling/0`, so a frame cannot be unbounded by declaration.

  ## Why the byte cap is measured, not assumed

  `canonical/1` + `Jason.encode!/1` means the check is about the bytes that would actually be
  stored, and it doubles as a proof that the payload IS encodable: a `NaN`/`Infinity` float, an
  unbounded atom, or a struct with no canonical form fails here rather than at the storage boundary
  in P2.

  ## P1 status

  Nothing calls `validate/1` yet — P2 (capture) is where a recorded frame is checked before it is
  written, and where `Samen.Replay.Values.sanitize/2` stops raising. This module is the contract P2
  must satisfy, and `mix samen.verify.replay_schema` asserts it behaviourally: it drives
  `validate/1` with tampered frames and fails if any refusal has stopped firing.
  """

  alias Samen.Masked
  alias Samen.PiiValueShape
  alias Samen.Replay.Values
  alias Samen.Replay.Values.{Placeholder, Redacted, Ref}

  @frame_kinds [:mount, :params, :render, :event, :info]

  @envelope_keys [:kind, :index, :occurred_at, :payload]

  # A closed list per kind, or `:bounded_keys` for the assign-shaped kinds (their key set is a
  # view's assigns, which cannot be enumerated here — but each key must still be bounded).
  @payload_keys %{
    mount: :bounded_keys,
    params: :bounded_keys,
    render: :bounded_keys,
    event: [:event, :params],
    info: [:tag, :count]
  }

  # A bare, non-token-shaped string is kept ONLY for these keys — and its value still has to pass
  # `Samen.PiiValueShape`, so a keep-list entry cannot smuggle an email (ADR-052 §2.3 rule 3).
  @keep_list [:page_title, :tab, :sort, :page]

  @max_payload_bytes 16 * 1024
  @hard_payload_ceiling 64 * 1024
  @max_keep_list_value 128

  # Non-vacuity floors: a schema that shrinks below these is not a schema any more.
  @min_kinds 5
  @min_bounded_types 3
  @min_keep_list 2

  @doc "The declared frame kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @frame_kinds

  @doc "The envelope keys every frame carries."
  @spec envelope_keys() :: [atom()]
  def envelope_keys, do: @envelope_keys

  @doc """
  The payload key policy for `kind`: a closed list of keys, `:bounded_keys` for the assign-shaped
  kinds, or `:unknown_kind`.
  """
  @spec payload_keys(atom()) :: [atom()] | :bounded_keys | :unknown_kind
  def payload_keys(kind), do: Map.get(@payload_keys, kind, :unknown_kind)

  @doc "The whole kind → policy map (the verifier walks this)."
  @spec payload_key_policy() :: %{atom() => [atom()] | :bounded_keys}
  def payload_key_policy, do: @payload_keys

  @doc "The view-declared keep-list: the only keys a bare text value may occupy."
  @spec keep_list() :: [atom()]
  def keep_list, do: @keep_list

  @doc "Max bytes of a canonical frame payload."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc "The ceiling `max_payload_bytes/0` may never exceed (a frame cannot be unbounded by declaration)."
  @spec hard_payload_ceiling() :: pos_integer()
  def hard_payload_ceiling, do: @hard_payload_ceiling

  @doc "The declared schema as plain data — what the verifier and its tests read."
  @spec snapshot() :: map()
  def snapshot do
    %{
      kinds: @frame_kinds,
      envelope_keys: @envelope_keys,
      payload_keys: @payload_keys,
      keep_list: @keep_list,
      max_payload_bytes: @max_payload_bytes,
      hard_payload_ceiling: @hard_payload_ceiling,
      min_kinds: @min_kinds,
      min_bounded_types: @min_bounded_types,
      min_keep_list: @min_keep_list
    }
  end

  @doc """
  Validate a frame. Returns `{:ok, frame}` (narrowed to the envelope keys) or
  `{:error, reason}` — never a partially-accepted frame, and never a repair.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{} = frame) do
    with {:ok, kind} <- fetch_kind(frame),
         :ok <- check_envelope(frame),
         {:ok, payload} <- fetch_payload(frame),
         :ok <- check_payload(kind, payload),
         :ok <- check_size(payload) do
      {:ok, Map.take(frame, @envelope_keys)}
    end
  end

  def validate(other), do: {:error, {:not_a_frame, other}}

  defp fetch_kind(frame) do
    case Map.get(frame, :kind) do
      kind when kind in @frame_kinds -> {:ok, kind}
      nil -> {:error, {:missing_kind, frame}}
      other -> {:error, {:unknown_kind, other}}
    end
  end

  defp check_envelope(frame) do
    with :ok <- check_index(Map.get(frame, :index)),
         :ok <- check_occurred_at(Map.get(frame, :occurred_at)) do
      :ok
    end
  end

  defp check_index(index) when is_integer(index) and index >= 0, do: :ok
  defp check_index(other), do: {:error, {:bad_index, other}}

  defp check_occurred_at(%DateTime{}), do: :ok
  defp check_occurred_at(%NaiveDateTime{}), do: :ok
  defp check_occurred_at(other), do: {:error, {:bad_occurred_at, other}}

  defp fetch_payload(frame) do
    case Map.get(frame, :payload) do
      payload when is_map(payload) and not is_struct(payload) -> {:ok, payload}
      other -> {:error, {:payload_not_a_map, other}}
    end
  end

  defp check_payload(kind, payload) do
    Enum.reduce_while(payload, :ok, fn {key, value}, :ok ->
      case check_member(kind, key, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_member(kind, key, value) do
    cond do
      not Values.bounded_key?(key) -> {:error, {:unbounded_key, key}}
      not key_allowed?(kind, key) -> {:error, {:undeclared_key, kind, key}}
      true -> check_value(key, value)
    end
  end

  defp key_allowed?(kind, key) do
    case payload_keys(kind) do
      :bounded_keys -> true
      keys -> key in keys
    end
  end

  # A bare binary: id/token-shaped values pass the vocabulary directly; a *text* binary needs its
  # key on the keep-list, and is still refused on a `vt_` token or a PII shape.
  defp check_value(key, value) when is_binary(value) do
    case Values.classify(value) do
      :ok -> :ok
      {:refused, why, _path} -> check_keep_listed(key, value, why)
    end
  end

  defp check_value(key, value) do
    case Values.classify(value) do
      :ok -> :ok
      {:refused, why, _path} -> {:error, {:unbounded_value, key, why}}
    end
  end

  defp check_keep_listed(key, value, why) do
    cond do
      key not in @keep_list -> {:error, {:unbounded_value, key, why}}
      why == :bare_vault_token -> {:error, {:bare_vault_token, key}}
      byte_size(value) > @max_keep_list_value -> {:error, {:keep_list_value_too_long, key}}
      true -> check_keep_list_shape(key, value)
    end
  end

  defp check_keep_list_shape(key, value) do
    case PiiValueShape.classify_value(value) do
      {true, shape} -> {:error, {:keep_list_value_pii_shaped, key, shape}}
      {false, nil} -> :ok
    end
  end

  defp check_size(payload) do
    bytes = payload |> canonical() |> Jason.encode!() |> byte_size()

    if bytes <= @max_payload_bytes do
      :ok
    else
      {:error, {:payload_too_large, bytes, @max_payload_bytes}}
    end
  end

  @doc """
  The canonical, JSON-ready form of a payload — the vocabulary terms flattened to tagged maps (so a
  stored `jsonb` frame round-trips), dates to ISO-8601, atoms to strings, `Masked` to its own tagged
  carrier. This is what `check_size/1` measures and what P2's codec should store.
  """
  @spec canonical(term()) :: term()
  def canonical(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, member} -> {canonical_key(key), canonical(member)} end)
  end

  def canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  def canonical(%Ref{resource: resource, pk: pk, attribute: attribute, label: label}) do
    %{
      "$ref" => %{
        "resource" => inspect(resource),
        "pk" => pk,
        "attribute" => to_string(attribute),
        "label" => canonical(label)
      }
    }
  end

  def canonical(%Redacted{kind: kind, length: length}),
    do: %{"$redacted" => to_string(kind), "length" => length}

  def canonical(%Placeholder{kind: kind}), do: %{"$placeholder" => to_string(kind)}

  def canonical(%Masked{token: token, label: label}),
    do: %{"$masked" => token, "label" => to_string(label)}

  def canonical(%Date{} = date), do: Date.to_iso8601(date)
  def canonical(%Time{} = time), do: Time.to_iso8601(time)
  def canonical(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  def canonical(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def canonical(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  def canonical(nil), do: nil
  def canonical(true), do: true
  def canonical(false), do: false
  def canonical(value) when is_atom(value), do: to_string(value)
  def canonical(value), do: value

  defp canonical_key(key) when is_atom(key), do: to_string(key)
  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key), do: inspect(key)

  @doc """
  The schema's own violations — what `mix samen.verify.replay_schema` exits non-zero on.

  Two halves, deliberately: the **declaration** checks read `snapshot/1` (so a tampered declaration
  can be fed in and each check proven refutable), and the **behavioural** checks drive the real
  `validate/1`/`Values.sanitize/2` with tampered frames (so a neutered refusal flips the gate even
  when the declarations still look right — which is exactly what sabotage 350 does).
  """
  @spec violations(keyword()) :: [map()]
  def violations(opts \\ []) do
    schema =
      opts
      |> Keyword.get(:snapshot, snapshot())
      |> inject_kind(Keyword.get(opts, :inject_kind))

    declaration_violations(schema) ++ vocabulary_violations(Keyword.get(opts, :values_refusals, [])) ++
      behaviour_violations()
  end

  # Test seam (red-path exit-code proof, mirroring `samen.verify.sink_schema`'s injected field):
  # a frame kind declared with NO payload key policy, appended to the snapshot the DECLARATION
  # checks read — so the subprocess red path exercises the real `:kind_coverage` check (and the
  # whole violations → halt → exit-1 pipeline) instead of asserting only that the task can fail.
  # Absent in every non-test invocation.
  defp inject_kind(schema, nil), do: schema

  defp inject_kind(schema, kind) when is_atom(kind) do
    Map.update(schema, :kinds, [kind], &(&1 ++ [kind]))
  end

  defp declaration_violations(schema) do
    %{
      kinds: kinds,
      payload_keys: payload_keys,
      keep_list: keep_list,
      envelope_keys: envelope_keys,
      max_payload_bytes: max_bytes,
      hard_payload_ceiling: ceiling,
      min_kinds: min_kinds
    } = normalize_schema(schema)

    []
    |> add_violation(length(kinds) < min_kinds, :non_vacuity, "declares only #{length(kinds)} frame kind(s)")
    |> add_violation(
      Enum.any?(kinds, &(Map.get(payload_keys, &1) == nil)),
      :kind_coverage,
      "a declared frame kind has NO payload key policy (#{inspect(kinds -- Map.keys(payload_keys))})"
    )
    |> add_violation(
      Enum.any?(Map.keys(payload_keys), &(&1 not in kinds)),
      :kind_coverage,
      "a payload key policy names a kind that is not declared (#{inspect(Map.keys(payload_keys) -- kinds)})"
    )
    |> add_violation(
      Enum.any?(payload_keys, fn {_kind, policy} -> policy == [] end),
      :closed_keys,
      "a frame kind declares an EMPTY payload key set (an empty closed set admits nothing and hides a mistake)"
    )
    |> add_violation(
      Enum.any?(payload_keys, fn {_kind, policy} -> policy != :bounded_keys and not Enum.all?(policy, &Values.bounded_key?/1) end),
      :closed_keys,
      "a closed payload key set contains a key that is not a bounded key"
    )
    |> add_violation(
      Enum.any?(kinds ++ envelope_keys, &carrier_shaped?/1),
      :no_carriers,
      "a declared kind or envelope key is `vt_`-prefixed, PII-shaped, or over the key bound"
    )
    |> add_violation(length(keep_list) < @min_keep_list, :keep_list, "the keep-list has fewer than #{@min_keep_list} entries")
    |> add_violation(
      not Enum.all?(keep_list, &Values.bounded_key?/1),
      :keep_list,
      "a keep-list entry is not a bounded key"
    )
    |> add_violation(
      not (is_integer(max_bytes) and max_bytes > 0),
      :size_bound,
      "max_payload_bytes/0 is not a positive integer (#{inspect(max_bytes)})"
    )
    |> add_violation(
      not (is_integer(ceiling) and ceiling > 0 and max_bytes <= ceiling),
      :size_bound,
      "max_payload_bytes (#{inspect(max_bytes)}) exceeds hard_payload_ceiling (#{inspect(ceiling)})"
    )
  end

  defp normalize_schema(schema) do
    %{
      kinds: Map.get(schema, :kinds, []),
      payload_keys: Map.get(schema, :payload_keys, %{}),
      keep_list: Map.get(schema, :keep_list, []),
      envelope_keys: Map.get(schema, :envelope_keys, []),
      max_payload_bytes: Map.get(schema, :max_payload_bytes, 0),
      hard_payload_ceiling: Map.get(schema, :hard_payload_ceiling, 0),
      min_kinds: Map.get(schema, :min_kinds, @min_kinds)
    }
  end

  defp vocabulary_violations(injected_refusals) do
    types = Values.bounded_types()

    []
    |> add_violation(length(types) < @min_bounded_types, :vocabulary, "the vocabulary declares fewer than #{@min_bounded_types} bounded types")
    |> add_violation(
      Enum.any?(Values.forbidden_carriers(), &(&1 in types)),
      :vocabulary,
      "the bounded-type vocabulary contains a forbidden text carrier (#{inspect(Enum.filter(Values.forbidden_carriers(), &(&1 in types)))})"
    )
    |> add_violation(
      Enum.any?(types, &carrier_shaped?/1),
      :vocabulary,
      "a bounded type name is carrier-shaped"
    )
    |> add_violation(
      Enum.any?([:ref, :redacted, :placeholder], &(&1 not in types)),
      :vocabulary,
      "a capture term is missing from the bounded-type vocabulary"
    )
    |> add_violation(
      Enum.empty?(Values.redacted_kinds()) or Enum.empty?(Values.placeholder_kinds()),
      :vocabulary,
      "a closed kind set (redacted/placeholder) is empty"
    )
    |> add_violation(
      Enum.any?(Values.redacted_kinds() ++ Values.placeholder_kinds(), &carrier_shaped?/1),
      :vocabulary,
      "a closed redacted/placeholder kind is carrier-shaped"
    )
    # The injected refusals let a test prove THIS check fires without mutating the vocabulary.
    |> Kernel.++(injected_refusals)
  end

  # Behavioural half: drive the real refusals. A check that only reads declarations cannot notice a
  # `validate/1` that stopped refusing — which is the failure this whole ADR exists to prevent.
  defp behaviour_violations do
    now = DateTime.utc_now()

    []
    |> add_violation(
      not refused?(frame(:mount, %{title: "jane@example.com", ref: "prs_01HZY4K7"})),
      :refusal_live,
      "a frame payload carrying a plaintext string is NOT refused (the vocabulary's allowlist is not being applied)"
    )
    |> add_violation(
      not refused?(frame(:mount, %{token: "vt_0123abcd"})),
      :refusal_live,
      "a frame payload carrying a BARE `vt_` vault token is NOT refused (a token may only travel inside a `%Samen.Masked{}`)"
    )
    |> add_violation(
      not refused?(%{kind: :not_a_kind, index: 0, occurred_at: now, payload: %{}}),
      :refusal_live,
      "an UNKNOWN frame kind is NOT refused"
    )
    |> add_violation(
      not refused?(frame(:info, %{tag: :ok, sneaky: 1})),
      :refusal_live,
      "a key outside a CLOSED payload key set is NOT refused"
    )
    |> add_violation(
      not refused?(frame(:mount, oversized_payload())),
      :refusal_live,
      "an OVERSIZED frame payload is NOT refused"
    )
    |> add_violation(
      not keep_list_pii_refused?(),
      :keep_list_shape,
      "a keep-listed key ACCEPTS a PII-shaped value (the keep-list is a smuggling path)"
    )
    |> add_violation(
      Values.bounded?(%{email: "jane@example.com"}),
      :anti_tautology,
      "the vocabulary ACCEPTS a plaintext string — the probes above would be vacuous"
    )
    |> add_violation(
      not sanitize_is_fail_honest?(),
      :fail_honest,
      "Samen.Replay.Values.sanitize/2 returned an acceptable-looking value for a PII-bearing probe " <>
        "instead of refusing (ADR-014: never `{:ok, _}` for work not done)"
    )
  end

  defp refused?(%{} = probe), do: match?({:error, _}, validate(probe))

  # Every LEAF here is bounded (a token-shaped 120-byte binary); the frame is refused purely because
  # 64 × 64 of them exceed `max_payload_bytes/0` — i.e. the size refusal is load-bearing on its own.
  defp oversized_payload do
    token = String.duplicate("a", 120)
    leaf = List.duplicate(token, 64)
    Map.new(1..64, fn i -> {"key_#{i}", leaf} end)
  end

  # Each keep-listed key is driven with an email-shaped value: the shape check must refuse it.
  defp keep_list_pii_refused? do
    Enum.all?(@keep_list, fn key ->
      refused?(frame(:mount, %{key => "jane@example.com"}))
    end)
  end

  # `sanitize/2` must be fail-honest at P1 (raise) — and once P2 implements it, its OUTPUT must still
  # be inside the vocabulary. Either way it can never hand back a PII-bearing assign map.
  defp sanitize_is_fail_honest? do
    probe = %{email: "jane@example.com", name: "Jane Q Public", note: "call the client back"}

    try do
      probe |> apply_sanitize() |> Values.bounded?()
    rescue
      _ -> true
    end
  end

  # `apply/3` on purpose: `Values.sanitize/2` is specified `no_return()` (the P1 fail-honest stub),
  # so a direct call would be folded to `none()` by the type checker. This probe must keep working
  # after P2 implements the walk — at which point the piped result must be inside the vocabulary.
  defp apply_sanitize(probe), do: apply(Values, :sanitize, [probe, []])

  defp frame(kind, payload) do
    %{kind: kind, index: 0, occurred_at: DateTime.utc_now(), payload: payload}
  end

  defp carrier_shaped?(term) when is_atom(term), do: term |> Atom.to_string() |> carrier_shaped?()

  defp carrier_shaped?(term) when is_binary(term) do
    Values.vault_token?(term) or Values.pii_shaped?(term) or not Values.bounded_key?(term)
  end

  defp carrier_shaped?(_), do: false

  defp add_violation(violations, false, _kind, _message), do: violations

  defp add_violation(violations, true, kind, message) do
    violations ++ [%{kind: kind, rule: kind, message: "replay schema: #{message}"}]
  end
end
