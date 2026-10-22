defmodule Samen.Web.Notes.Writes do
  @moduledoc """
  The ordered write helpers for WS-Notes (ADR-053 §2 D4/§8 O2; WS-Notes Phase 2 unit 2.2).

  ## One writer, one ordering model

  Every structural change to a page goes through this module: insert, split, merge, move, indent,
  archive/restore. They all share the same two rules:

    * **`position` is an integer ordinal scoped to its PARENT** (ADR-053 §8 O2). M1 only ever
      writes the doc root (`parent_block_id` nil), but every clause is written against
      `(doc_id, parent_block_id)` rather than assuming the root — so the day M2 nests blocks, the
      ordering semantics do not have to be migrated.
    * **Gaps of #{1024}** between siblings, rebalanced IN THE SAME TRANSACTION when a gap closes.
      The rebalance rewrites positions only; it never touches a block's `revision`, because a
      sibling moving is not a change to the block you are typing into (a CAS on that block must
      still succeed).

  ## Revision compare-and-set (R9)

  `update_text/5` and `split/5` accept `:revision` — the revision the client last saw. The write
  is a real compare-and-set: the `Ash.Changeset` carries `revision == expected`, so under
  concurrency exactly one writer matches and the loser gets `{:error, :stale}`. The stale write is
  REFUSED, never applied last-write-wins, and the transaction rolls back (nothing else changes).

  Omitting `:revision` is not "force": the write still CASes against the revision this function
  just read, so a concurrent write surfaces as `:stale` instead of silently losing an edit.

  ## Masked blocks are write-refused

  A write has to READ the text it is changing (split/merge). The read goes through
  `Samen.Api.PiiResolution` on the writer's plane, exactly like `Samen.Web.Notes.Reads`. If the
  value resolves to a `%Samen.Masked{}` (an operator-plane session without a grant), split/merge
  return `{:error, :masked}` rather than writing `••••` into content. There is no hand-unwrapping
  of a vault field anywhere in this module.

  ## Return shapes

      insert_block/4   {:ok, block} | {:error, term}
      update_text/5    {:ok, block} | {:error, :stale | :not_found | term}
      split/5          {:ok, %{left: block, right: block}} | {:error, term}
      merge/3          {:ok, %{block: survivor, removed: id}} | {:ok, :noop} | {:error, term}
      move/4           {:ok, block} | {:ok, :noop} | {:error, term}
      indent/4         {:ok, block} | {:ok, :noop} | {:error, :not_indentable | term}
      archive/3        {:ok, block} | {:error, term}
      restore/3        {:ok, block} | {:error, :not_found | term}
      declassify/4     {:ok, block} | {:error, :no_reason | :forbidden | :not_found | term}

  Every multi-write operation runs inside `repo.transaction/1`; an error rolls the lot back.
  Structural operations also bump the page's `Doc.revision`, which is what the realtime
  `{:page_structure_changed, revision}` envelope carries.
  """

  require Ash.Query

  alias Samen.Scopes.Docs.BlockShape
  alias Samen.Web.Mount
  alias Samen.Web.Notes.{Links, Offset}

  @gap 1024
  # The per-source link set is bounded like every other fan-out in this module.
  @link_limit 200
  @list_types [:bulleted_list_item, :numbered_list_item, :to_do]

  @block_select [
    :id,
    :doc_id,
    :parent_block_id,
    :position,
    :type,
    :text,
    :text_secure,
    :checked,
    :metadata,
    :revision
  ]

  @doc_select [:id, :title, :body, :secure_body, :revision]

  # ── insert ─────────────────────────────────────────────────────────────────

  @doc """
  Insert one block into `doc_id`.

  `attrs` are the block attributes (`:type`, `:text` or `:text_secure`, `:checked`, `:metadata`),
  plus the OPTIONAL ordering hints `:after_block_id` / `:before_block_id` and `:parent_block_id`
  (nil = the doc root, M1's only level). Without a hint the block is appended.

  `:type` may be the atom token or its exact string name (`"paragraph"` — what a `phx-value` sends);
  anything else is refused as `{:error, {:unknown_type, token}}` (R11). The full shape is validated
  by `Samen.Scopes.Docs.BlockShape` before the write, so an out-of-shape `metadata`/`checked` pair is
  refused with `{:error, {:invalid_shape, reason}}` instead of reaching the database.
  """
  @spec insert_block(Mount.t(), Samen.Scope.t(), term(), map()) ::
          {:ok, struct()} | {:error, term()}
  def insert_block(mount, scope, doc_id, attrs) do
    raw_type = Map.get(attrs, :type, :paragraph)
    type = normalize_type(raw_type)
    metadata = Map.get(attrs, :metadata) || %{}
    checked = Map.get(attrs, :checked)
    parent = Map.get(attrs, :parent_block_id)
    after_id = Map.get(attrs, :after_block_id)
    before_id = Map.get(attrs, :before_block_id)

    attrs =
      attrs
      |> Map.drop([:type, :metadata, :checked, :parent_block_id, :after_block_id, :before_block_id])

    with :ok <- validate_shape(type, raw_type, metadata, checked),
         {:ok, _text_attrs} <- validate_text_attrs(attrs),
         {:ok, doc} <- fetch_doc(mount, scope, doc_id) do
      in_tx(mount, fn ->
        with {:ok, siblings} <- siblings(mount, scope, doc_id, parent),
             {:ok, position} <-
               insert_position(mount, scope, doc_id, parent, siblings, after_id, before_id),
             {:ok, block} <-
               create_block(mount, scope, doc_id, parent, position, type, metadata, checked, attrs) do
          with {:ok, _doc} <- bump_doc!(mount, scope, doc),
               {:ok, _links} <- sync_links(mount, scope, doc_id) do
            {:ok, block}
          end
        end
      end)
    end
  end

  # ── text ───────────────────────────────────────────────────────────────────

  @doc """
  Replace a block's text and bump its `revision`.

  Options:

    * `:revision` — the revision the client last saw; a mismatch is `{:error, :stale}` (R9).
    * `:secure` — RAISE the classification: write `text_secure` (the vaulted column, `••••` on a
      masked plane) instead of the plain `text`. The other column is cleared in the same write: a
      block has ONE text.

  ## Classification is sticky — an edit cannot declassify

  The column is chosen by `keep_classification/2`: a block that is ALREADY vaulted keeps its edit in
  `text_secure`, whatever the caller passed (including an explicit `secure: false`), so a block
  never leaves the vault as a side effect of typing. `:secure` can only raise: a plain block may be
  opted INTO the vault (`PageLive`'s sensitive-page toggle would pass it), and nothing in this API
  can move one out.

  That stickiness is what makes the editor safe by construction. `PageLive`'s debounced `block_text`
  handler passes no `:secure` at all — it only knows the text the textarea holds — so before this
  rule, editing a 🔒 block wrote its plaintext into `text` and cleared `text_secure`: one keystroke
  declassified content, the operator plane stopped masking it, and the block's own `secure?` read
  flipped. Clearing a vault column is a DATA-GOVERNANCE decision; it needs a governed action of its
  own (with its own audit and policy), never a side effect of an ordinary edit.

  ## The helper is the CONVENIENCE; the model is the GUARANTEE

  Routing an edit by the row's classification is a UX decision, and a module can only bind its own
  callers. The invariant itself lives in the model: `Samen.Scopes.Docs.BlockVault`, installed on
  `DocBlock`'s `:update` action, REFUSES any governed write that would clear `text_secure` on a
  vaulted row (or give it a plain `text` twin), so a second write path — a seed, another host, a
  helper added after this one — cannot declassify content by typing into it. This module never
  trips that guard: it reads the classification first (`fetch_block/3` selects `text_secure`) and
  writes the column the block already lives in.

  A non-binary value is refused (`{:error, :not_a_string}`) rather than cast.
  """
  @spec update_text(Mount.t(), Samen.Scope.t(), term(), binary(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def update_text(mount, scope, block_id, text, opts \\ [])

  def update_text(mount, scope, block_id, text, opts) when is_binary(text) do
    requested_secure? = Keyword.get(opts, :secure, false) == true
    expected = Keyword.get(opts, :revision)

    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           revision = expected || block.revision,
           secure? = keep_classification(requested_secure?, block),
           attrs = text_attrs(text, secure?) |> Map.put(:revision, revision + 1) do
        # A text edit is NOT a structural change: it does not bump the page revision (the
        # id-only `{:block_changed, id, revision}` envelope carries the block's own).
        with {:ok, updated} <- cas_update(block, scope, attrs, revision),
             {:ok, _links} <- sync_links(mount, scope, block.doc_id) do
          {:ok, updated}
        end
      end
    end)
  end

  def update_text(_mount, _scope, _block_id, _text, _opts), do: {:error, :not_a_string}

  @doc """
  Set (or flip) a `to_do` block's `checked` flag and bump its `revision`.

  `checked` is a model column of ONE type, so a non-`to_do` block is refused
  (`{:error, :not_checkable}`) rather than quietly carrying a flag its shape does not allow — the
  same discipline `BlockShape` applies to `metadata` keys. Options: `:checked` (explicit value;
  omit to flip) and `:revision` (CAS, R9).
  """
  @spec toggle_checked(Mount.t(), Samen.Scope.t(), term(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def toggle_checked(mount, scope, block_id, opts \\ []) do
    expected = Keyword.get(opts, :revision)
    requested = Keyword.get(opts, :checked)

    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           :to_do <- block.type,
           revision = expected || block.revision,
           checked = if(is_boolean(requested), do: requested, else: !block.checked) do
        cas_update(block, scope, %{checked: checked, revision: revision + 1}, revision)
      else
        type when is_atom(type) -> {:error, :not_checkable}
        other -> other
      end
    end)
  end

  # ── split / merge ──────────────────────────────────────────────────────────

  @doc """
  Split a block at a UTF-16 caret `offset` (the hook's `Enter`), inserting the tail as a new
  sibling directly after it.

  The offset is converted by `Samen.Web.Notes.Offset` — the one place that knows a browser counts
  UTF-16 code units while `String.split_at/2` counts graphemes — and clamped, never raised.

  The new block keeps the type only for LIST types (a list item's Enter starts the next item);
  every other type becomes a `paragraph`, per ADR-053 §4. A vaulted block splits into two vaulted
  blocks (the classification follows the content). Options: `:revision` (CAS on the anchor).
  """
  @spec split(Mount.t(), Samen.Scope.t(), term(), integer() | binary(), keyword()) ::
          {:ok, %{left: struct(), right: struct()}} | {:error, term()}
  def split(mount, scope, block_id, offset, opts \\ []) do
    expected = Keyword.get(opts, :revision)
    offset = normalize_offset(offset)

    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           {:ok, text} <- readable_text(mount, scope, block),
           {:ok, doc} <- fetch_doc(mount, scope, block.doc_id) do
        {left, right} = Offset.split(text, offset)
        revision = expected || block.revision
        secure? = not is_nil(block.text_secure)

        with {:ok, updated} <-
               cas_update(block, scope, text_attrs(left, secure?) |> Map.put(:revision, revision + 1), revision),
             {:ok, siblings} <- siblings(mount, scope, block.doc_id, block.parent_block_id),
             {:ok, position} <-
               insert_position(mount, scope, block.doc_id, block.parent_block_id, siblings, block.id, nil),
             {:ok, new_block} <-
               create_block(
                 mount,
                 scope,
                 block.doc_id,
                 block.parent_block_id,
                 position,
                 split_type(block.type),
                 %{},
                 if(split_type(block.type) == :to_do, do: false, else: nil),
                 text_attrs(right, secure?)
               ),
             {:ok, _doc} <- bump_doc!(mount, scope, doc),
             {:ok, _links} <- sync_links(mount, scope, block.doc_id) do
          {:ok, %{left: updated, right: new_block}}
        end
      end
    end)
  end

  @doc """
  Merge a block into its PREVIOUS sibling (the hook's `Backspace` at offset 0), deleting it.

  Merging the first block is `{:ok, :noop}` — there is nothing to merge into. If either side is
  vaulted the survivor stays vaulted: merging a sensitive paragraph with a plain neighbour must
  never downgrade the content to the plain column (where `FreeTextScan` would then refuse it, or
  worse, where it would ship unclassified).
  """
  @spec merge(Mount.t(), Samen.Scope.t(), term()) ::
          {:ok, %{block: struct(), removed: term()}} | {:ok, :noop} | {:error, term()}
  def merge(mount, scope, block_id) do
    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           {:ok, doc} <- fetch_doc(mount, scope, block.doc_id),
           {:ok, siblings} <- siblings(mount, scope, block.doc_id, block.parent_block_id) do
        case Enum.find_index(siblings, &(&1.id == block.id)) do
          nil ->
            {:error, :not_found}

          0 ->
            {:ok, :noop}

          index ->
            previous = Enum.at(siblings, index - 1)

            with {:ok, left} <- readable_text(mount, scope, previous),
                 {:ok, right} <- readable_text(mount, scope, block) do
              # Merging must never DOWNGRADE classification: if either side is vaulted the
              # survivor stays vaulted (a plain target would ship classified text unclassified).
              secure? = not is_nil(previous.text_secure) or not is_nil(block.text_secure)
              merged_attrs =
                text_attrs(left <> right, secure?)
                |> Map.put(:revision, previous.revision + 1)

              with {:ok, survivor} <- cas_update(previous, scope, merged_attrs, previous.revision),
                   {:ok, _removed} <- destroy_block(block, scope),
                   {:ok, _doc} <- bump_doc!(mount, scope, doc),
                   {:ok, _links} <- sync_links(mount, scope, block.doc_id) do
                {:ok, %{block: survivor, removed: block.id}}
              end
            end
        end
      end
    end)
  end

  # ── move / indent ──────────────────────────────────────────────────────────

  @doc """
  Move a block one sibling `:up` or `:down`, swapping positions. At the boundary: `{:ok, :noop}`.
  """
  @spec move(Mount.t(), Samen.Scope.t(), term(), :up | :down) ::
          {:ok, struct()} | {:ok, :noop} | {:error, term()}
  def move(mount, scope, block_id, direction) when direction in [:up, :down] do
    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           {:ok, doc} <- fetch_doc(mount, scope, block.doc_id),
           {:ok, siblings} <- siblings(mount, scope, block.doc_id, block.parent_block_id) do
        index = Enum.find_index(siblings, &(&1.id == block.id))
        target_index = if is_integer(index), do: (if direction == :up, do: index - 1, else: index + 1)
        # `Enum.at/2` wraps a NEGATIVE index around to the END of the list — `:up` on the first
        # block would swap with the last one. Bound the index explicitly instead.
        target = if is_integer(target_index) and target_index >= 0, do: Enum.at(siblings, target_index)

        if is_nil(target) do
          {:ok, :noop}
        else
          with {:ok, moved} <- swap_positions(block, target, scope),
               {:ok, _doc} <- bump_doc!(mount, scope, doc) do
            {:ok, moved}
          end
        end
      end
    end)
  end

  def move(_mount, _scope, _block_id, direction), do: {:error, {:bad_direction, direction}}

  @doc """
  Indent (`:in`) or outdent (`:out`) a LIST block.

  M1 is flat (ADR-053 §8 O2), so there is no parent to move into; ADR-053 §4's declared M1
  behaviour is the stand-in: the block MOVES among its siblings (`:in` swaps it down, `:out` swaps
  it up) and its list type flips between `bulleted_list_item` and `numbered_list_item` (a bullet
  indented becomes the numbered level; a numbered item outdented becomes a bullet). `to_do` moves
  but keeps its type. Any non-list type is `{:error, :not_indentable}` — the hook only reports
  indent for list types; a server-side refusal is the guard that the client cannot widen that.
  """
  @spec indent(Mount.t(), Samen.Scope.t(), term(), :in | :out) ::
          {:ok, struct()} | {:ok, :noop} | {:error, :not_indentable | term()}
  def indent(mount, scope, block_id, direction) when direction in [:in, :out] do
    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           true <- block.type in @list_types,
           {:ok, doc} <- fetch_doc(mount, scope, block.doc_id),
           {:ok, siblings} <- siblings(mount, scope, block.doc_id, block.parent_block_id) do
        index = Enum.find_index(siblings, &(&1.id == block.id))
        target_index = if is_integer(index), do: (if direction == :in, do: index + 1, else: index - 1)
        target = if is_integer(target_index) and target_index >= 0, do: Enum.at(siblings, target_index)
        new_type = indented_type(block.type, direction)

        with {:ok, moved} <- swap_positions(block, target, scope, %{type: new_type}),
             {:ok, _doc} <- bump_doc!(mount, scope, doc) do
          {:ok, moved}
        end
      else
        false -> {:error, :not_indentable}
        other -> other
      end
    end)
  end

  def indent(_mount, _scope, _block_id, direction), do: {:error, {:bad_direction, direction}}

  # ── archive / restore ──────────────────────────────────────────────────────

  @doc "Archive one block (soft delete, ADR-040 §5.9) and bump the page revision."
  @spec archive(Mount.t(), Samen.Scope.t(), term()) :: {:ok, struct()} | {:error, term()}
  def archive(mount, scope, block_id) do
    in_tx(mount, fn ->
      with {:ok, block} <- fetch_block(mount, scope, block_id),
           {:ok, doc} <- fetch_doc(mount, scope, block.doc_id),
           {:ok, archived} <-
             block
             |> Ash.Changeset.for_destroy(:archive, %{}, scope: scope)
             |> destroy(),
           {:ok, _doc} <- bump_doc!(mount, scope, doc),
           {:ok, _links} <- sync_links(mount, scope, doc.id) do
        {:ok, archived}
      end
    end)
  end

  @doc "Restore an archived block and bump the page revision."
  @spec restore(Mount.t(), Samen.Scope.t(), term()) :: {:ok, struct()} | {:error, term()}
  def restore(mount, scope, block_id) do
    in_tx(mount, fn ->
      with {:ok, block} <- fetch_archived_block(mount, scope, block_id),
           {:ok, doc} <- fetch_doc(mount, scope, block.doc_id),
           {:ok, restored} <-
             block
             |> Ash.Changeset.for_update(:restore, %{}, scope: scope)
             |> update(),
           {:ok, _doc} <- bump_doc!(mount, scope, doc),
           {:ok, _links} <- sync_links(mount, scope, doc.id) do
        {:ok, restored}
      end
    end)
  end

  # ── the named door out of the vault (R17) ──────────────────────────────────

  @doc """
  Move one block's text OUT of the vault — the ONLY way content stops being 🔒 (ADR-053 §2 D5,
  R17).

  This helper deliberately does NOT decide who may do it: the `:declassify_text` action in
  `Samen.Scopes.Docs` owns the gate (`RoleAtLeast :admin`, tenant plane only), the reveal (bound
  to the block's own id), the move, the revision bump and the `docs.block.declassified` audit row.
  Routing the caller here just keeps the surface on the same `in_tx` + error-shape discipline as
  every other write (`{:error, :forbidden}` is a refusal by POLICY, `{:error, :no_reason}` is a
  blank reason refused before the transaction opens).

  A non-binary or blank `reason` is `{:error, :no_reason}` — the audit row is the record of WHY a
  classification was reduced, so there is no "just this once" path.

  The page's link graph is re-synced in the same transaction: the text is plain now, so any
  `[[Title]]` inside it becomes a real link edge for the first time.
  """
  @spec declassify(Mount.t(), Samen.Scope.t(), term(), binary()) ::
          {:ok, struct()} | {:error, :no_reason | :forbidden | term()}
  def declassify(mount, scope, block_id, reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, :no_reason}
    else
      in_tx(mount, fn ->
        with {:ok, block} <- fetch_block(mount, scope, block_id),
             {:ok, updated} <-
               block
               |> Ash.Changeset.for_update(:declassify_text, %{reason: reason}, scope: scope)
               |> update(),
             {:ok, _links} <- sync_links(mount, scope, block.doc_id) do
          {:ok, updated}
        else
          {:error, error} -> {:error, declassify_error(error)}
        end
      end)
    end
  end

  def declassify(_mount, _scope, _block_id, _reason), do: {:error, :no_reason}

  # A policy refusal arrives as `Ash.Error.Forbidden` (a single error) or wrapped in
  # `Ash.Error.Invalid`; the surface shows ONE message for "not you", so it is classified here.
  defp declassify_error(%Ash.Error.Forbidden{}), do: :forbidden

  defp declassify_error(error) do
    if forbidden_error?(error), do: :forbidden, else: error
  end

  defp forbidden_error?(error) do
    error
    |> Ash.Error.to_ash_error()
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%Ash.Error.Forbidden{}, &1))
  rescue
    _ -> false
  end

  # ── pages ──────────────────────────────────────────────────────────────────

  @doc """
  Create a page (`Doc`) in the acting org — the index surface's "New page" (Phase 3 unit 3.2).

  The title is trimmed and a blank one becomes `"Untitled"`; the page is created through the
  SAME governed `:create` action the scope ships (`OrgScope` + `RoleAtLeast :member`, ADR-053 §8
  O6), so there is no second write path to a `Doc`. A new page has ZERO blocks, which is what
  makes `Reads`' legacy-body fallback irrelevant for it: an empty page renders the editor's empty
  state, not an empty legacy body.

  Optional `:icon` (the bounded token the model accepts). Returns `{:ok, doc}`.
  """
  @spec create_page(Mount.t(), Samen.Scope.t(), map()) :: {:ok, struct()} | {:error, term()}
  def create_page(mount, scope, attrs \\ %{}) do
    title =
      case Map.get(attrs, :title) do
        title when is_binary(title) ->
          case String.trim(title) do
            "" -> "Untitled"
            trimmed -> trimmed
          end

        _ ->
          "Untitled"
      end

    attrs = Map.new(attrs)

    create_attrs =
      %{org_id: org_id(scope), title: title}
      |> then(fn base ->
        case Map.get(attrs, :icon) do
          nil -> base
          icon -> Map.put(base, :icon, icon)
        end
      end)

    doc_resource(mount)
    |> Ash.Changeset.for_create(:create, create_attrs, scope: scope)
    |> Ash.create()
  end

  @doc """
  Re-resolve this page's link graph (WS-Notes Phase 4 unit 4.3) — called inside the SAME
  transaction as every text/structure write, so a save can never leave the `DocLink` rows
  describing text the page no longer has.

  The reconcile is a SET operation:

    * every `[[Title]]` in the page's PLAIN `text` is resolved org-scoped (`Links.resolve_all/3`)
      — an unresolved title creates nothing (the "create page" affordance persists no link);
    * a resolved title with an existing `(source, target)` row keeps it and refreshes
      `anchor_text` if the author's typed title changed;
    * a row whose target is no longer referenced (or no longer resolves, e.g. the target was
      renamed or archived) is DESTROYED.

  Only `text` is parsed: a vaulted block never creates a link edge (an edge is a visible,
  non-PII row on the target page). Return shapes: `{:ok, links}` / `{:error, term}`; an error
  rolls the caller's transaction back rather than leaving half a link graph.
  """
  @spec sync_links(Mount.t(), Samen.Scope.t(), term()) :: {:ok, [struct()]} | {:error, term()}
  def sync_links(mount, scope, doc_id) do
    titles = Links.page_titles(mount, scope, doc_id)
    resolved = Links.resolve_all(mount, scope, titles)
    wanted = Map.new(resolved, fn {title, doc} -> {doc.id, title} end)

    with {:ok, keep} <- reconcile_links(read_links(mount, scope, doc_id), wanted, scope) do
      create_missing_links(mount, scope, doc_id, wanted, keep)
    end
  rescue
    error -> {:error, error}
  end

  # ── links ─────────────────────────────────────────────────────────────────

  defp read_links(mount, scope, doc_id) do
    mount
    |> link_resource()
    |> Ash.Query.ensure_selected([:id, :source_doc_id, :target_doc_id, :anchor_text])
    |> Ash.Query.filter(source_doc_id == ^doc_id)
    |> Ash.Query.limit(@link_limit)
    |> Ash.read!(scope: scope)
  end

  defp reconcile_links(existing, wanted, scope) do
    Enum.reduce_while(existing, {:ok, MapSet.new()}, fn link, {:ok, keep} ->
      case Map.fetch(wanted, link.target_doc_id) do
        :error ->
          case destroy_link(link, scope) do
            {:ok, _} -> {:cont, {:ok, keep}}
            {:error, error} -> {:halt, {:error, error}}
          end

        {:ok, title} ->
          if link.anchor_text == title do
            {:cont, {:ok, MapSet.put(keep, link.target_doc_id)}}
          else
            case link
                 |> Ash.Changeset.for_update(:update, %{anchor_text: title}, scope: scope)
                 |> update() do
              {:ok, _} -> {:cont, {:ok, MapSet.put(keep, link.target_doc_id)}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end
      end
    end)
  end

  defp create_missing_links(mount, scope, doc_id, wanted, keep) do
    wanted
    |> Enum.reject(fn {target_id, _title} -> MapSet.member?(keep, target_id) end)
    |> Enum.sort_by(fn {_target_id, title} -> title end)
    |> Enum.reduce_while({:ok, []}, fn {target_id, title}, {:ok, acc} ->
      attrs = %{
        org_id: org_id(scope),
        source_doc_id: doc_id,
        target_doc_id: target_id,
        anchor_text: title
      }

      case mount
           |> link_resource()
           |> Ash.Changeset.for_create(:create, attrs, scope: scope)
           |> create() do
        {:ok, link} -> {:cont, {:ok, [link | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp destroy_link(link, scope) do
    link
    |> Ash.Changeset.for_destroy(:destroy, %{}, scope: scope)
    |> destroy()
  end

  # ── positions ──────────────────────────────────────────────────────────────

  # Choose a position between the neighbours named by the hints, appending when there is no hint.
  # When the chosen slot has no room (adjacent ordinals), the parent's siblings are rebalanced to
  # fresh gaps and the choice is retried ONCE (`rebalanced?`), so this cannot loop.
  defp insert_position(mount, scope, doc_id, parent, siblings, after_id, before_id, rebalanced? \\ false) do
    cond do
      not is_nil(after_id) ->
        case Enum.find_index(siblings, &(&1.id == after_id)) do
          nil ->
            {:error, :anchor_not_found}

          index ->
            anchor = Enum.at(siblings, index)
            following = Enum.at(siblings, index + 1)

            cond do
              is_nil(following) ->
                {:ok, anchor.position + @gap}

              following.position - anchor.position > 1 ->
                {:ok, anchor.position + div(following.position - anchor.position, 2)}

              rebalanced? ->
                {:error, :no_position}

              true ->
                with :ok <- rebalance!(mount, scope, siblings),
                     {:ok, fresh} <- siblings(mount, scope, doc_id, parent) do
                  insert_position(mount, scope, doc_id, parent, fresh, after_id, before_id, true)
                end
            end
        end

      not is_nil(before_id) ->
        case Enum.find_index(siblings, &(&1.id == before_id)) do
          nil ->
            {:error, :anchor_not_found}

          index ->
            anchor = Enum.at(siblings, index)
            previous = if index > 0, do: Enum.at(siblings, index - 1)

            cond do
              is_nil(previous) and anchor.position > 1 ->
                {:ok, div(anchor.position, 2)}

              is_nil(previous) and not rebalanced? ->
                with :ok <- rebalance!(mount, scope, siblings),
                     {:ok, fresh} <- siblings(mount, scope, doc_id, parent) do
                  insert_position(mount, scope, doc_id, parent, fresh, after_id, before_id, true)
                end

              not is_nil(previous) and anchor.position - previous.position > 1 ->
                {:ok, previous.position + div(anchor.position - previous.position, 2)}

              rebalanced? ->
                {:error, :no_position}

              true ->
                with :ok <- rebalance!(mount, scope, siblings),
                     {:ok, fresh} <- siblings(mount, scope, doc_id, parent) do
                  insert_position(mount, scope, doc_id, parent, fresh, after_id, before_id, true)
                end
            end
        end

      true ->
        case List.last(siblings) do
          nil -> {:ok, @gap}
          last -> {:ok, last.position + @gap}
        end
    end
  end

  # Rewrite the parent's ordinals to 1024, 2048, … — positions only, never `revision` (a sibling
  # moving must not invalidate a CAS on the block a user is typing into).
  defp rebalance!(_mount, scope, siblings) do
    Enum.reduce_while(Enum.with_index(siblings, 1), :ok, fn {block, index}, :ok ->
      target = index * @gap

      if block.position == target do
        {:cont, :ok}
      else
        case block
             |> Ash.Changeset.for_update(:update, %{position: target}, scope: scope)
             |> update() do
          {:ok, _} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end
    end)
  end

  defp swap_positions(block, target, scope, extra \\ %{})

  defp swap_positions(block, nil, scope, extra) do
    # No neighbour to swap with: still apply an attribute change (indent's type flip) when asked.
    if map_size(extra) == 0 do
      {:ok, block}
    else
      block
      |> Ash.Changeset.for_update(:update, extra, scope: scope)
      |> update()
    end
  end

  defp swap_positions(block, other, scope, extra) do
    # Capture BOTH original positions BEFORE either update overwrites one of them.
    block_position = block.position
    other_position = other.position

    with {:ok, updated} <-
           block
           |> Ash.Changeset.for_update(
             :update,
             Map.merge(extra, %{position: other_position}),
             scope: scope
           )
           |> update(),
         {:ok, _other} <-
           other
           |> Ash.Changeset.for_update(:update, %{position: block_position}, scope: scope)
           |> update() do
      {:ok, updated}
    end
  end

  # ── create / update / destroy primitives ───────────────────────────────────

  defp create_block(mount, scope, doc_id, parent, position, type, metadata, checked, attrs) do
    attrs =
      attrs
      |> Map.merge(%{
        org_id: org_id(scope),
        doc_id: doc_id,
        parent_block_id: parent,
        position: position,
        type: type,
        metadata: metadata,
        checked: checked,
        revision: 1
      })

    mount
    |> block_resource()
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> create()
  end

  # The CAS. `revision == expected` rides the UPDATE's own WHERE clause, so two writers holding
  # the same revision cannot both apply: the loser matches zero rows and Ash returns NotFound,
  # which is the stale signal. Nothing is decided by a read-then-write window.
  defp cas_update(block, scope, attrs, expected) do
    block
    |> Ash.Changeset.for_update(:update, attrs, scope: scope)
    |> Ash.Changeset.filter({:revision, [eq: expected]})
    |> update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> if stale_error?(error), do: {:error, :stale}, else: {:error, error}
    end
  end

  # Ash reports a compare-and-set miss as `Ash.Error.Changes.StaleRecord` ("no row matched the
  # filter"), possibly wrapped in `Ash.Error.Invalid`, possibly as a changeset. Normalise the
  # shape and look for that one error — a single-read-then-write window is never consulted.
  defp stale_error?(error) do
    error
    |> Ash.Error.to_ash_error()
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp destroy_block(block, scope) do
    block
    |> Ash.Changeset.for_destroy(:destroy, %{}, scope: scope)
    |> destroy()
  end

  # Bump the PAGE revision — the structural-change signal. `Doc.revision` is the page-level
  # counter (the block's own `revision` is the per-block CAS token); the surface broadcasts
  # `{:page_structure_changed, revision}` off this value.
  # ── Ash primitive wrappers (one shape, one notification policy) ────────────
  #
  # These run INSIDE `in_tx`, so Ash would warn that notifications cannot be delivered. No
  # resource in this module's path configures a notifier, so ask for them back and drop the
  # (empty) list rather than emitting a warning per write. The shape is normalised too: a
  # changeset call always yields `{:ok, record} | {:error, error}`.
  defp create(changeset) do
    case Ash.create(changeset, return_notifications?: true) do
      {:ok, record, _notifications} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp update(changeset) do
    case Ash.update(changeset, return_notifications?: true) do
      {:ok, record, _notifications} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp destroy(changeset) do
    case Ash.destroy(changeset,
           return_destroyed?: true,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp bump_doc!(_mount, scope, doc) do
    doc
    |> Ash.Changeset.for_update(:update, %{revision: doc.revision + 1}, scope: scope)
    |> update()
  end

  # ── reads used by writes ───────────────────────────────────────────────────

  defp fetch_doc(mount, scope, doc_id) do
    query =
      mount
      |> doc_resource()
      |> Ash.Query.ensure_selected(@doc_select)
      |> Ash.Query.filter(id == ^doc_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [doc | _]} -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_block(mount, scope, block_id) do
    query =
      mount
      |> block_resource()
      |> Ash.Query.ensure_selected(@block_select)
      |> Ash.Query.filter(id == ^block_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [block | _]} -> {:ok, block}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_archived_block(mount, scope, block_id) do
    query =
      mount
      |> block_resource()
      |> Ash.Query.for_read(:archived)
      |> Ash.Query.ensure_selected(@block_select)
      |> Ash.Query.filter(id == ^block_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [block | _]} -> {:ok, block}
      _ -> {:error, :not_found}
    end
  end

  defp siblings(mount, scope, doc_id, parent) do
    query =
      mount
      |> block_resource()
      |> Ash.Query.ensure_selected(@block_select)
      |> Ash.Query.filter(doc_id == ^doc_id)
      |> Ash.Query.sort(position: :asc, id: :asc)

    query =
      if is_nil(parent) do
        Ash.Query.filter(query, is_nil(parent_block_id))
      else
        Ash.Query.filter(query, parent_block_id == ^parent)
      end

    case Ash.read(query, scope: scope) do
      {:ok, siblings} -> {:ok, siblings}
      {:error, error} -> {:error, error}
    end
  end

  # The text a write is about to manipulate, resolved on the WRITER's plane. A masked value is
  # refused: writing `••••` into content would be a corruption, not an edit.
  defp readable_text(mount, scope, block) do
    [resolved] =
      Samen.Api.PiiResolution.resolve(
        [block],
        block_resource(mount),
        actor_of(scope),
        repo: mount.repo
      )

    value =
      if is_nil(resolved.text_secure) do
        Map.get(resolved, :text)
      else
        Map.get(resolved, :text_secure)
      end

    case value do
      nil -> {:ok, ""}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :masked}
    end
  rescue
    _ -> {:error, :masked}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Classification can only go UP. A vaulted block is detected from the row itself (the vault column
  # is non-nil on every read, masked or clear), so the decision does not depend on the caller
  # remembering to pass `:secure` — which is exactly the bug this prevents.
  defp keep_classification(requested_secure?, block),
    do: requested_secure? or vaulted?(block)

  defp vaulted?(block), do: not is_nil(Map.get(block, :text_secure))

  defp text_attrs(text, true), do: %{text_secure: text, text: nil}
  defp text_attrs(text, false), do: %{text: text, text_secure: nil}

  defp validate_text_attrs(attrs) do
    if Map.has_key?(attrs, :text) and Map.has_key?(attrs, :text_secure) do
      {:error, :both_text_and_secure}
    else
      {:ok, attrs}
    end
  end

  defp validate_shape(type, raw_type, metadata, checked) do
    cond do
      not is_atom(type) or type not in BlockShape.types() ->
        {:error, {:unknown_type, raw_type}}

      true ->
        case BlockShape.validate(%{type: type, metadata: metadata, checked: checked}) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_shape, reason}}
        end
    end
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    Enum.find(BlockShape.types(), :unknown, &(Atom.to_string(&1) == type))
  end

  defp normalize_type(_), do: :unknown

  defp normalize_offset(offset) when is_integer(offset), do: max(offset, 0)

  defp normalize_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {value, ""} -> max(value, 0)
      _ -> 0
    end
  end

  defp normalize_offset(_), do: 0

  defp split_type(type) when type in @list_types, do: type
  defp split_type(_type), do: :paragraph

  defp indented_type(:bulleted_list_item, :in), do: :numbered_list_item
  defp indented_type(:numbered_list_item, :out), do: :bulleted_list_item
  defp indented_type(type, _direction), do: type

  # `Mount.resource/2` concatenates a SHORT name onto the mount's namespace, so these are the
  # `:Doc`/`:DocBlock` atoms — not the aliased modules (which would concatenate twice).
  defp block_resource(mount), do: Mount.resource(mount, :DocBlock)
  defp doc_resource(mount), do: Mount.resource(mount, :Doc)
  defp link_resource(mount), do: Mount.resource(mount, :DocLink)

  defp org_id(%Samen.Scope{actor: actor}), do: actor_org(actor)
  defp org_id(actor) when is_map(actor), do: actor_org(actor)
  defp org_id(_), do: nil

  defp actor_org(%{org_id: org_id}), do: org_id
  defp actor_org(_), do: nil

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  # Every multi-write operation is one transaction: an error rolls the lot back. Ecto returns
  # `{:error, reason}` for a rollback, which is the shape the callers already document.
  #
  # A failed compare-and-set ROLLS THE TRANSACTION BACK from inside Ash (its action runs
  # `transaction?: true`, so the StaleRecord becomes a `DBConnection` rollback throw that unwinds
  # to THIS boundary — it never reaches `cas_update`'s own error clause). The rollback is exactly
  # what a stale write should do; it just arrives here as the changeset, so classify it once, at
  # the boundary, into the documented `{:error, :stale}`.
  defp in_tx(mount, fun) do
    case mount.repo.transaction(fn ->
           case fun.() do
             {:ok, value} -> value
             {:error, reason} -> mount.repo.rollback(reason)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  # `Ash.update` returning an error and Ash rolling back are the same event seen from two sides;
  # map both to the documented reason. A non-stale failure passes through untouched.
  defp normalize_error(reason), do: if(stale_error?(reason), do: :stale, else: reason)
end
