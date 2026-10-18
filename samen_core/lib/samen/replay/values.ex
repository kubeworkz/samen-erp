defmodule Samen.Replay.Values do
  @moduledoc """
  The **masked-replay capture vocabulary** (ADR-052 §2.2/§2.3, Lane B P1) — the closed world a
  recorded frame may contain, and the three terms that explain every stored value.

  ## Why a vocabulary instead of a sanitizer

  A sanitizer at the storage boundary is a **blocklist**: it has to guess every future shape a value
  can take, and it fails open on the shape nobody imagined. This module is the opposite edge — an
  **allowlist**. Nothing reaches a stored frame unless it is one of:

  | Term | Means | Rendered as |
  |---|---|---|
  | `%Samen.Replay.Ref{resource, pk, attribute, label}` | a vault-routed attribute of an Ash record: the **pointer** replaces the value at capture | resolved at view time on the **viewer's** plane |
  | `%Samen.Replay.Redacted{kind, length}` | a value deliberately not kept (`:string`, `:free_text`) | shape only: `"•••• (42 chars)"` |
  | `%Samen.Replay.Placeholder{kind}` | a reference that cannot be resolved **now** | an explicit gap, never a blank |

  Everything else is a **bounded type**: a number, a boolean, a date/time, a `Decimal`, an opaque
  id, a token, an atom from a closed set, a `%Samen.Masked{}` (a token carrier, never plaintext), or
  a map/list that recurses — each under the hard bounds `bounds/0` declares.

  ## What is NOT bounded — and the honest limit

  A **bare string is not a bounded value.** That is the point: a string is exactly the shape a name,
  an email or a note takes, so it can only enter a frame as `%Redacted{kind: :string, length: n}`
  (shape only) or as a binary in a bounded *position* that passes a shape check — id-shaped
  (`id_shaped?/1`) or token-shaped (`token_shaped?/1`) and **not** PII-shaped
  (`Samen.PiiValueShape.pii_shaped_id?/1`). A `vt_`-prefixed binary is refused outright: a vault
  token travels only inside a `%Samen.Masked{}`, where it is a declared carrier rather than a value
  that merely looks like one.

  The shape check is a **heuristic, not a proof** — the same honest limit `Samen.PiiValueShape`
  states about itself. The load-bearing guarantee is structural: a value can only be stored because
  it matched this vocabulary, and it can only be *read* by resolving each `Ref` on the viewer's
  plane.

  ## Fail-honest at P1

  `sanitize/2` — the function that will turn a live assign map into this vocabulary — is a **stub
  that raises** (`:not_implemented`, ADR-014). It never returns `{:ok, _}` for work it has not done:
  a sanitizer that claimed success while passing values through would be exactly the plaintext store
  ADR-052 refuses. P2 implements it; this module is the vocabulary P2 must fill.
  """

  alias Samen.Masked
  alias Samen.PiiValueShape

  defmodule Ref do
    @moduledoc """
    A **pointer** to a vault-routed attribute of an Ash record (ADR-052 §2.2): `resource` is the
    Ash module, `pk` the record's opaque primary key, `attribute` the field name, and `label` an
    optional bounded display name. The value itself is never captured — it is resolved at view time,
    on the viewer's plane, through the one vault chokepoint.
    """

    @enforce_keys [:resource, :pk, :attribute]
    defstruct [:resource, :pk, :attribute, :label]

    @type t :: %__MODULE__{
            resource: module(),
            pk: String.t(),
            attribute: atom(),
            label: binary() | atom() | nil
          }
  end

  defmodule Redacted do
    @moduledoc """
    A value we deliberately do **not** keep (ADR-052 §2.2). `kind` is drawn from the closed
    `redacted_kinds/0` set; `length` carries the shape (how many characters were dropped) without
    the characters. `:dropped` is the fail-closed default for anything outside the vocabulary — a
    value is never stringified "just in case".
    """

    @enforce_keys [:kind]
    defstruct [:kind, :length]

    @type t :: %__MODULE__{kind: atom(), length: non_neg_integer() | nil}
  end

  defmodule Placeholder do
    @moduledoc """
    A reference that cannot be resolved **now** (ADR-052 §2.5): `:shredded` (the subject's key is
    destroyed — erasure reaches replays with zero replay-specific deletion), `:gone` (the row was
    deleted) or `:denied` (anything else failing, fail-closed). An explicit gap, never a blank.
    """

    @enforce_keys [:kind]
    defstruct [:kind]

    @type t :: %__MODULE__{kind: atom()}
  end

  @bounded_types [
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

  # The carriers a value would have to occupy to leak text. Named so a diagnostic can say WHY a
  # value was refused, and so the verifier can assert they never appear in the vocabulary.
  @forbidden_carriers [:string, :binary, :text, :charlist, :any, :term, :html, :raw]

  @redacted_kinds [:string, :free_text, :dropped]
  @placeholder_kinds [:shredded, :gone, :denied]

  # The ONE bound a token may take — the same shape `Samen.Analytics.Replay` already enforces for a
  # surface token (lowercase ascii, underscore-joined, ≤64 chars). A module-derived token always
  # satisfies it; a path, a URL, a label or a name never does.
  @token_regex ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  # An abbrev-prefixed opaque id (`org_01J…`, `prj_…`): three lowercase letters, `_`, then the
  # Crockford/ULID-ish alphabet the foundry's abbreviations use.
  @abbrev_id_regex ~r/\A[a-z]{3}_[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{4,40}\z/

  @vt_prefix "vt_"
  @max_binary 128
  @max_atom_chars 64
  @max_collection 64
  @max_depth 4

  @doc "The bounded types a frame payload value may take."
  @spec bounded_types() :: [atom()]
  def bounded_types, do: @bounded_types

  @doc "Type atoms that name a text carrier — never permitted, listed for precise diagnostics."
  @spec forbidden_carriers() :: [atom()]
  def forbidden_carriers, do: @forbidden_carriers

  @doc "Is `type` a bounded (permitted-in-a-frame) type?"
  @spec bounded_type?(atom()) :: boolean()
  def bounded_type?(type), do: type in @bounded_types

  @doc "The closed set of `Redacted.kind` values."
  @spec redacted_kinds() :: [atom()]
  def redacted_kinds, do: @redacted_kinds

  @doc "The closed set of `Placeholder.kind` values."
  @spec placeholder_kinds() :: [atom()]
  def placeholder_kinds, do: @placeholder_kinds

  @doc "The capture terms — the three structs that explain every stored value."
  @spec capture_terms() :: [module()]
  def capture_terms, do: [Ref, Redacted, Placeholder]

  @doc """
  The hard bounds a value takes: `%{binary:, atom_chars:, collection:, depth:}`. Declared (and
  therefore checkable) rather than implied, so a frame cannot grow without a limit.
  """
  @spec bounds() :: %{atom() => pos_integer()}
  def bounds do
    %{
      binary: @max_binary,
      atom_chars: @max_atom_chars,
      collection: @max_collection,
      depth: @max_depth
    }
  end

  @doc "Is `value` a bounded token shape (lowercase ascii, underscore-joined, ≤64 chars)?"
  @spec token_shaped?(term()) :: boolean()
  def token_shaped?(value) when is_binary(value), do: Regex.match?(@token_regex, value)
  def token_shaped?(_), do: false

  @doc "Is `value` an opaque id shape (a UUID, or an abbrev-prefixed id)?"
  @spec id_shaped?(term()) :: boolean()
  def id_shaped?(value) when is_binary(value) do
    Regex.match?(@uuid_regex, value) or Regex.match?(@abbrev_id_regex, value)
  end

  def id_shaped?(_), do: false

  @doc "A vault FK token (`vt_*`) — permitted ONLY inside a `%Samen.Masked{}`, never bare."
  @spec vault_token?(term()) :: boolean()
  def vault_token?(value) when is_binary(value), do: String.starts_with?(value, @vt_prefix)
  def vault_token?(_), do: false

  @doc """
  Does the value have a PII *literal* shape (email / SSN / phone / space-separated name)? A bare
  binary that does is refused, however well it matches a token shape.
  """
  @spec pii_shaped?(term()) :: boolean()
  def pii_shaped?(value) when is_binary(value), do: PiiValueShape.pii_shaped_id?(value)
  def pii_shaped?(_), do: false

  @doc """
  May `key` appear in a frame payload? An atom (the assign-key shape) or a bounded token-shaped
  binary, within the character bound. A key is text, so it is checked like one.
  """
  @spec bounded_key?(term()) :: boolean()
  def bounded_key?(key) when is_atom(key) do
    name = Atom.to_string(key)

    String.length(name) <= @max_atom_chars and not vault_token?(name) and not pii_shaped?(name)
  end

  def bounded_key?(key) when is_binary(key) do
    byte_size(key) <= @max_atom_chars and token_shaped?(key) and not vault_token?(key) and
      not pii_shaped?(key)
  end

  def bounded_key?(_), do: false

  @doc """
  Is `value` inside the capture vocabulary? Recursive over maps and lists, with `bounds/0` applied
  at every level.
  """
  @spec bounded?(term()) :: boolean()
  def bounded?(value), do: classify(value) == :ok

  @doc """
  The *reason* a value is (or is not) bounded — `:ok`, or `{:refused, why, path}` where `path` is the
  payload path to the offending member. This is what the frame schema validates payloads with;
  `bounded?/1` is its boolean face.
  """
  @spec classify(term()) :: :ok | {:refused, atom(), [term()]}
  def classify(value), do: classify(value, [])

  defp classify(value, path) when is_map(value) and not is_struct(value) do
    cond do
      length(path) >= @max_depth -> {:refused, :too_deep, path}
      map_size(value) > @max_collection -> {:refused, :collection_too_large, path}
      true -> classify_entries(Map.to_list(value), path)
    end
  end

  defp classify(value, path) when is_list(value) do
    cond do
      length(path) >= @max_depth -> {:refused, :too_deep, path}
      length(value) > @max_collection -> {:refused, :collection_too_large, path}
      true -> classify_indexed(value, path)
    end
  end

  defp classify(value, path) when is_binary(value) do
    cond do
      byte_size(value) > @max_binary -> {:refused, :binary_too_long, path}
      vault_token?(value) -> {:refused, :bare_vault_token, path}
      pii_shaped?(value) -> {:refused, :pii_shaped, path}
      id_shaped?(value) -> :ok
      token_shaped?(value) -> :ok
      true -> {:refused, :raw_string, path}
    end
  end

  defp classify(value, _path) when is_integer(value), do: :ok

  # A BEAM float is always finite — the VM has no infinity/NaN float term at all (its external term
  # format refuses to decode one, and overflowing arithmetic raises), so there is no branch here to
  # write and no claim to make. A number that reaches a frame is JSON-encodable by construction.
  defp classify(value, _path) when is_float(value), do: :ok

  defp classify(value, _path) when is_boolean(value), do: :ok
  defp classify(nil, _path), do: :ok

  # An atom is bounded by construction (it lives in the atom table, not in a value string) — but an
  # atom's NAME is still text, and `String.to_atom("Jane Q Public")` is a name-shaped leak that a
  # bare length check would wave through. Same posture as `Samen.WideEvent`'s `:opaque_id` runtime
  # guard: refuse a PII-shaped atom however it got there.
  defp classify(value, path) when is_atom(value) do
    name = Atom.to_string(value)

    cond do
      String.length(name) > @max_atom_chars -> {:refused, :atom_too_long, path}
      pii_shaped?(name) -> {:refused, :pii_shaped, path}
      true -> :ok
    end
  end

  defp classify(%Date{}, _path), do: :ok
  defp classify(%Time{}, _path), do: :ok
  defp classify(%NaiveDateTime{}, _path), do: :ok
  defp classify(%DateTime{}, _path), do: :ok
  defp classify(%Decimal{}, _path), do: :ok

  defp classify(%Masked{token: token, label: label}, path) when is_binary(token) do
    cond do
      not vault_token?(token) -> {:refused, :masked_token_not_a_token, path}
      not is_atom(label) -> {:refused, :masked_label_not_an_atom, path}
      byte_size(token) > @max_binary -> {:refused, :binary_too_long, path}
      true -> :ok
    end
  end

  defp classify(%Ref{resource: resource, pk: pk, attribute: attribute, label: label}, path) do
    cond do
      not is_atom(resource) -> {:refused, :ref_resource_not_a_module, path}
      not is_atom(attribute) -> {:refused, :ref_attribute_not_an_atom, path}
      not bounded?(pk) -> {:refused, :ref_pk_not_bounded, path}
      label != nil and not bounded?(label) -> {:refused, :ref_label_not_bounded, path}
      true -> :ok
    end
  end

  defp classify(%Redacted{kind: kind, length: length}, path) do
    cond do
      kind not in @redacted_kinds -> {:refused, :unregistered_redacted_kind, path}
      length == nil -> :ok
      is_integer(length) and length >= 0 -> :ok
      true -> {:refused, :bad_redacted_length, path}
    end
  end

  defp classify(%Placeholder{kind: kind}, path) do
    if kind in @placeholder_kinds, do: :ok, else: {:refused, :unregistered_placeholder_kind, path}
  end

  defp classify(_value, path), do: {:refused, :unknown_term, path}

  defp classify_entries(entries, path) do
    Enum.reduce_while(entries, :ok, fn {key, value}, :ok ->
      key_path = path ++ [key]

      if bounded_key?(key) do
        case classify(value, key_path) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end
      else
        {:halt, {:refused, :unbounded_key, key_path}}
      end
    end)
  end

  # A map key is text and must be bounded; a LIST index is not text at all, so it is allowed as
  # itself. Keeping the two walks apart is what stops `[1, 2, 3]` being refused for "unbounded key
  # 0" — and `Enum.with_index/1` yields `{element, index}`, so a list entry cannot be destructured
  # as a map entry.
  defp classify_indexed(values, path) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case classify(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  @doc "Build a `Ref` — the pointer that replaces a vault-routed attribute at capture."
  @spec ref(module(), binary(), atom(), binary() | atom() | nil) :: Ref.t()
  def ref(resource, pk, attribute, label \\ nil),
    do: %Ref{resource: resource, pk: pk, attribute: attribute, label: label}

  @doc "Build a `Redacted` — a value deliberately not kept, carrying its shape only."
  @spec redacted(atom(), non_neg_integer() | nil) :: Redacted.t()
  def redacted(kind, length \\ nil), do: %Redacted{kind: kind, length: length}

  @doc "The fail-closed default for anything outside the vocabulary."
  @spec dropped(non_neg_integer() | nil) :: Redacted.t()
  def dropped(length \\ nil), do: %Redacted{kind: :dropped, length: length}

  @doc "Build a `Placeholder` — an explicit gap (`:shredded` / `:gone` / `:denied`)."
  @spec placeholder(atom()) :: Placeholder.t()
  def placeholder(kind), do: %Placeholder{kind: kind}

  @doc """
  Turn a live assign map into the capture vocabulary. **NOT IMPLEMENTED — P2.**

  It raises rather than returning `{:ok, _}` (ADR-014's fail-honest contract): a sanitizer that
  claimed success while passing values through would be the largest plaintext store in the system,
  which is exactly what ADR-052 refuses. `mix samen.verify.replay_schema` asserts the vocabulary this
  must fill; P2 implements the walk.
  """
  @spec sanitize(term(), keyword()) :: no_return()
  def sanitize(_value, _opts \\ []) do
    raise ArgumentError,
          "Samen.Replay.Values.sanitize/2 is :not_implemented (Lane B P1) — refusal, never a " <>
            "pass-through: an unsanitised assign map is exactly the plaintext store ADR-052 " <>
            "refuses. The vocabulary (bounded_types/0, classify/1) is implemented and verified."
  end
end
