defmodule Samen.Scopes.Docs.BlockShape do
  @moduledoc """
  The **closed shape** of a `Docs.DocBlock` row (ADR-053 §2 D2 / §3; WS-Notes Phase 1 unit 1.2).

  A block is a typed row, and the type decides which OTHER attributes it may carry. That mapping is
  a closed allowlist — `metadata` is not a free-form bag:

  | `type` | `metadata` keys | `checked` |
  |---|---|---|
  | `paragraph` · `heading_1` · `heading_2` · `heading_3` · `quote` · `divider` | — | no |
  | `bulleted_list_item` · `numbered_list_item` | — | no |
  | `to_do` | — | **yes** |
  | `code` | `language` | no |
  | `callout` | `icon` | no |
  | `page_link` | `target_doc_id` (a uuid string) | no |

  ## Why a shape, not a schema-less map

  The alternative — "`metadata` is a map, let callers put what they like in it" — is exactly how a
  block type grows undocumented attributes that no renderer knows about, and how a future PII value
  ends up in a field nobody classified. The same closed-allowlist discipline the replay frame schema
  (ADR-052 §4) applies to recorded assigns, applied one level down to authored content: **an
  attribute the shape does not name cannot be written.**

  Unknown keys are REFUSED (not dropped) so a caller learns immediately rather than silently losing
  data; an unknown TYPE is refused for the same reason.

  ## How it is enforced

  Two entry points, one implementation:

    * `validate/1` — pure, used by tests and by any caller that wants to check before writing;
    * `change/3` — an `Ash.Changeset` change installed by
      `Samen.Scopes.Docs.Blueprint.define_doc_block/6`, so the refusal happens on the governed
      write path (Ash action), never only in a UI. It is a `before_action` change, so the
      actions that carry it declare `require_atomic? false`.
  """
  use Ash.Resource.Change

  # Bounded type vocabulary. Order is the order the slash menu will offer (M1).
  @types [
    :paragraph,
    :heading_1,
    :heading_2,
    :heading_3,
    :bulleted_list_item,
    :numbered_list_item,
    :to_do,
    :quote,
    :code,
    :divider,
    :callout,
    :page_link
  ]

  # type => allowed metadata keys ([]) means "no metadata at all".
  @metadata_keys %{
    paragraph: [],
    heading_1: [],
    heading_2: [],
    heading_3: [],
    bulleted_list_item: [],
    numbered_list_item: [],
    to_do: [],
    quote: [],
    code: ["language"],
    divider: [],
    callout: ["icon"],
    page_link: ["target_doc_id"]
  }

  # A bounded value length: a language tag, an emoji, a uuid. Anything longer is not one of those.
  @max_value_length 64

  @doc "The bounded type vocabulary, in menu order."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "The metadata keys `type` may carry (never a free-form map)."
  @spec metadata_keys(atom()) :: [String.t()]
  def metadata_keys(type) when is_atom(type), do: Map.get(@metadata_keys, type, [])

  @doc "Whether `type` may carry the `checked` flag (`to_do` only)."
  @spec checked?(atom()) :: boolean()
  def checked?(type), do: type == :to_do

  @doc """
  Validate a block's shape.

  Accepts a map with `:type` (atom), `:metadata` (map or nil) and `:checked` (boolean or nil).
  Returns `:ok` or `{:error, reason}` where `reason` is a human-readable string naming the field —
  the caller turns it into a changeset error / a refusal, never a silent drop.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{} = attrs) do
    type = Map.get(attrs, :type)

    cond do
      type not in @types ->
        {:error, "unknown block type #{inspect(type)} (allowed: #{Enum.map_join(@types, ", ", &inspect/1)})"}

      not valid_metadata?(type, Map.get(attrs, :metadata)) ->
        {:error,
         "block type #{inspect(type)} may only carry metadata keys #{inspect(metadata_keys(type))}, " <>
           "each a string of at most #{@max_value_length} chars"}

      not valid_checked?(type, Map.get(attrs, :checked)) ->
        {:error, "`checked` is only valid on a :to_do block (got #{inspect(type)})"}

      true ->
        :ok
    end
  end

  @doc """
  `Ash.Changeset` change — the governed-write enforcement of `validate/1`.

  Installed by the blueprint on `DocBlock`, so a raw `Ash.create`/`Ash.update` that would write an
  out-of-shape block is refused at the action, not only in a UI or a test.
  """
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  @impl true
  def change(changeset, _opts, _context) do
    attrs = %{
      type: Ash.Changeset.get_attribute(changeset, :type),
      metadata: Ash.Changeset.get_attribute(changeset, :metadata),
      checked: Ash.Changeset.get_attribute(changeset, :checked)
    }

    case validate(attrs) do
      :ok -> changeset
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :type, message: message)
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  # No metadata at all is fine for every type; when present it must be a string-keyed map whose
  # keys are ALLOWED for this type and whose values are bounded strings. Missing keys are fine.
  defp valid_metadata?(_type, nil), do: true

  defp valid_metadata?(type, %{} = metadata) do
    allowed = metadata_keys(type)

    Enum.all?(metadata, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        key in allowed and String.length(value) <= @max_value_length

      _other ->
        false
    end)
  end

  defp valid_metadata?(_type, _other), do: false

  defp valid_checked?(_type, nil), do: true
  defp valid_checked?(:to_do, value) when is_boolean(value), do: true
  defp valid_checked?(_type, _other), do: false
end
