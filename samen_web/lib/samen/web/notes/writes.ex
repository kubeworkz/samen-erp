defmodule Samen.Web.Notes.Writes do
  @moduledoc """
  The ordered write helpers for WS-Notes (ADR-053 §2 D4/§8 O2; WS-Notes Phase 2 unit 2.2).

  ## One writer, one ordering model

  Every structural change to a page goes through this module: the page's own create and delete
  (soft), and the block operations insert, split, merge, move, indent, archive/restore. They all
  share the same two rules:

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

  ## The page tree's cascade (Phase 3 unit 3.13)

  A page is a NODE, so every write that changes its liveness changes its subtree's: deleting a page
  retires its subpages, restoring it brings them back, purging it destroys them. The first two are
  the MODEL's (`Samen.Scopes.Docs.CascadeArchive` / `CascadeRestore`, attached to `Doc`), which is
  what makes them true for a delete issued from anywhere; the third is this seam's, because a purge
  also destroys the CONTENT the model deliberately leaves alone (blocks) and that is the seam's job
  already. `Samen.Scopes.Docs.Tree` is the one definition of "the subtree" both halves read.

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
      create_page/3    {:ok, doc} | {:error, term}
      archive_page/3   {:ok, doc} | {:error, :not_found | term}
      restore_page/3   {:ok, doc} | {:error, :not_found | :parent_in_trash | term}
      purge_page/3     {:ok, doc} | {:error, :not_found | :forbidden | :too_many_blocks |
                                             :live_descendants | term}
      empty_trash/2    {:ok, [doc]} | {:error, :forbidden | :too_many_blocks | term}
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

  alias Samen.Scopes.Docs.{BlockShape, Tree}
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

  # `:archived_at` is selected because the trash reads (`:archived`) and the purge's archive-first
  # guard (`Samen.Scopes.Docs.PagePurge`) both decide off it; `:parent_doc_id` because the restore's
  # orphan guard asks whether the page's parent is live before it brings a child back.
  @doc_select [:id, :title, :body, :secure_body, :parent_doc_id, :revision, :archived_at]

  # A page's block set is a single-parent fan-out, so the purge reads its ids in one bounded pass
  # (the `@link_limit` posture). Unlike every other fan-out here this one may not truncate quietly:
  # a hard delete that stopped at the cap would leave authored content — and its vault tokens — in
  # rows nothing can reach, so hitting the bound REFUSES the purge instead (`:too_many_blocks`).
  @purge_block_limit 5_000

  # The bulk empty acts on the SAME bounded set the trash view renders (`Samen.Web.Notes.Reads.trash/2`
  # is `@index_limit` = 200, newest-deleted first): one click empties what the user can see, and the
  # reload shows anything older still in the trash. Bounding it keeps one governed write from
  # becoming an unbounded table sweep.
  @purge_trash_limit 200

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
      |> Map.drop([
        :type,
        :metadata,
        :checked,
        :parent_block_id,
        :after_block_id,
        :before_block_id
      ])

    with :ok <- validate_shape(type, raw_type, metadata, checked),
         {:ok, _text_attrs} <- validate_text_attrs(attrs),
         {:ok, doc} <- fetch_doc(mount, scope, doc_id) do
      in_tx(mount, fn ->
        with {:ok, siblings} <- siblings(mount, scope, doc_id, parent),
             {:ok, position} <-
               insert_position(mount, scope, doc_id, parent, siblings, after_id, before_id),
             {:ok, block} <-
               create_block(
                 mount,
                 scope,
                 doc_id,
                 parent,
                 position,
                 type,
                 metadata,
                 checked,
                 attrs
               ) do
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
               cas_update(
                 block,
                 scope,
                 text_attrs(left, secure?) |> Map.put(:revision, revision + 1),
                 revision
               ),
             {:ok, siblings} <- siblings(mount, scope, block.doc_id, block.parent_block_id),
             {:ok, position} <-
               insert_position(
                 mount,
                 scope,
                 block.doc_id,
                 block.parent_block_id,
                 siblings,
                 block.id,
                 nil
               ),
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

        target_index =
          if is_integer(index), do: if(direction == :up, do: index - 1, else: index + 1)

        # `Enum.at/2` wraps a NEGATIVE index around to the END of the list — `:up` on the first
        # block would swap with the last one. Bound the index explicitly instead.
        target =
          if is_integer(target_index) and target_index >= 0, do: Enum.at(siblings, target_index)

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

        target_index =
          if is_integer(index), do: if(direction == :in, do: index + 1, else: index - 1)

        target =
          if is_integer(target_index) and target_index >= 0, do: Enum.at(siblings, target_index)

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
  Delete a PAGE from the tree — a SOFT delete, and the page-level sibling of `archive/3`.

  The page's SUBTREE goes with it (WS-Notes Phase 3 unit 3.13): `Doc`'s model attaches
  `Samen.Scopes.Docs.CascadeArchive`, so every subpage is retired at the same instant, each through
  its own `:archive` action (its own `record_archived` row, naming the same actor). That is the
  MODEL's guarantee, not this helper's — a delete issued from anywhere gets it. It is the invariant
  the trash depends on: a live page never outlives its ancestor, so the tree has no rows pointing at
  a parent no read can see.

  Three things happen in ONE transaction:

    * the page is soft-destroyed through the governed `:archive` action (`OrgScope` +
      `RoleAtLeast :member`, ADR-053 §8 O6), which stamps `archived_at` and writes the
      `record_archived` governance audit row — "who deleted this page" is an audited event,
      not a UI detail;
    * every `DocLink` edge touching the page is DESTROYED, both directions (`destroy_page_links/3`).
      A `DocLink` is a pure edge row and is not archivable (ADR-053 §3.1); the ADR names exactly
      this case — "a deleted page's links are destroyed with it";
    * the page's BLOCKS are deliberately left LIVE. A page's blocks are not archived with it
      (ADR-053 §3.1; WS-Notes build-plan finding 4): the tree, the search index and the backlink
      list each join through an archive-filtered PAGE read, so an archived page's blocks are
      unreachable through every surface without rewriting them — and restoring the page brings its
      content back intact. The same is true of a cascaded subpage's blocks: `CascadeArchive` retires
      rows, not content, and the purge is where content dies.

  Returns `{:ok, archived_doc}`. `{:error, :not_found}` covers both "no such page" and "another
  org's page": `OrgScope` filters the row out of the read rather than refusing it (`Reads`'
  posture — R1, never an existence oracle).
  """
  @spec archive_page(Mount.t(), Samen.Scope.t(), term()) :: {:ok, struct()} | {:error, term()}
  def archive_page(mount, scope, doc_id) do
    in_tx(mount, fn ->
      with {:ok, doc} <- fetch_doc(mount, scope, doc_id),
           {:ok, _links} <- destroy_page_links(mount, scope, doc_id),
           {:ok, archived} <-
             doc
             |> Ash.Changeset.for_destroy(:archive, %{}, scope: scope)
             |> destroy() do
        {:ok, archived}
      end
    end)
  end

  @doc """
  Put a deleted page back — the Undo behind both delete surfaces.

  The restore runs the model's `:restore` action, which clears `archived_at` and writes the
  `record_restored` governance audit row (the counterpart of the `record_archived` the delete
  wrote). It is IDEMPOTENT where that matters: a page that is already LIVE is `{:ok, doc}` with no
  write and no audit row, so an Undo clicked twice — or clicked from a stale `?deleted=` URL —
  settles instead of erroring on the user.

  The page's SUBTREE comes back with it (WS-Notes Phase 3 unit 3.13): `Doc`'s model attaches
  `Samen.Scopes.Docs.CascadeRestore`, which restores exactly the pages archived at the page's own
  instant — the ones that went down with it. A subpage somebody deleted on its own, at its own
  instant, STAYS in the trash: Undo restores what the action removed, not every deletion nearby.

  A page whose PARENT is still in the trash cannot be restored (`{:error, :parent_in_trash}`):
  bringing one child back would put a live page under an ancestor no read can see — the orphan the
  delete cascade exists to prevent. The question is asked here AND enforced by the model
  (`CascadeRestore`'s `before_action`), so a restore written by a caller this seam does not know
  still cannot create one.

  The page's OUTGOING `[[Title]]` edges are re-derived in the same transaction (`sync_links/3`),
  because `archive_page/3` destroyed them and the source text that spells them survived. Incoming
  edges are not re-derived: they belong to OTHER pages' text, and come back the next time one of
  those pages saves. (A cascaded subpage's edges were never destroyed by the archive — the cascade
  retires page rows — so there is nothing to re-derive for them.)

  `{:error, :not_found}` means neither the live read nor the trash read knows the id — a page in
  another org, or one that never existed (R1: this is not an existence oracle).
  """
  @spec restore_page(Mount.t(), Samen.Scope.t(), term()) ::
          {:ok, struct()} | {:error, :not_found | :parent_in_trash | term()}
  def restore_page(mount, scope, doc_id) do
    in_tx(mount, fn ->
      case fetch_doc(mount, scope, doc_id) do
        # Already live: nothing to undo, and no second audit row to write.
        {:ok, doc} ->
          {:ok, doc}

        {:error, :not_found} ->
          with {:ok, doc} <- fetch_archived_doc(mount, scope, doc_id),
               :ok <- parent_live(mount, doc),
               {:ok, restored} <-
                 doc
                 |> Ash.Changeset.for_update(:restore, %{}, scope: scope)
                 |> update(),
               {:ok, _links} <- sync_links(mount, scope, doc_id) do
            {:ok, restored}
          end
      end
    end)
  end

  # The orphan guard, asked of the LIVE read: a parent that is in the trash (or gone) is not a place
  # a page can come back to. Early, so the surface gets an atom it can render — the model asks the
  # same question again and is what actually refuses (`CascadeRestore`).
  defp parent_live(_mount, %{parent_doc_id: nil}), do: :ok

  defp parent_live(mount, %{parent_doc_id: parent_id}) do
    if Tree.parent_live?(doc_resource(mount), parent_id),
      do: :ok,
      else: {:error, :parent_in_trash}
  end

  @doc """
  Delete a trashed page **permanently** — the trash's "delete forever" (Phase 3 unit 3.11).

  ## Why this is not `archive_page/3`

  A soft delete is recoverable and audited; this is neither. So it is a SEPARATE governed action,
  `Doc.:purge` (`Samen.Scopes.Docs.PagePurge`), not a flag on the existing ones, and it carries
  four invariants the soft path does not need:

    * **trash-only** — the page is read through the `:archived` read (`fetch_archived_doc/3`), so a
      LIVE page is `{:error, :not_found}` here (as is a page in another org, and one already
      purged). The model refuses a live page too, even when called directly: `{:error, :not_found}`
      is this seam's answer, never an existence oracle (R1);
    * **content goes WITH the page** — `Doc`'s blocks are deliberately NOT archived with it
      (ADR-053 §3.1), so a hard delete of the page alone would leave the authored text (and its
      vault tokens) in rows no read can reach. Every block is hard-destroyed in the same
      transaction, BEFORE the page, so a failure can never leave a page whose content outlived it;
      the block set is bounded (`@purge_block_limit`) and a page past the bound is REFUSED whole
      rather than deleted down to a leftover tail;
    * **links, both directions, again** — `archive_page/3` already destroyed them; re-running that
      reconcile closes the window where an archived page was re-linked while it sat in the trash;
    * **the SUBTREE goes too** (WS-Notes Phase 3 unit 3.13) — the trash cascade means a trashed page's
      children are in the trash with it; destroying the parent alone would leave them in the trash
      under a parent that no longer exists, and restoring one of them later would be an orphan by
      the back door. So `Tree.subtree/2` collects every descendant and each is purged the same way,
      DEEPEST FIRST, with its own blocks and its own `record_purged` row. A descendant that is still
      LIVE refuses the whole purge (`{:error, :live_descendants}`): a hard delete of a live page is
      not something the trash may do on the way past.

  ## The audit

  `record_purged` (`Samen.Scopes.Docs.PagePurge`, in the action's transaction) — the terminal
  counterpart of the `record_archived` the soft delete wrote. Nothing is written for the refused
  cases.

  ## Return shapes

  `{:ok, purged_doc}` (the page named — its subtree is destroyed with it); `{:error, :not_found}`
  (not in the trash / foreign / already gone); `{:error, :forbidden}` (the caller is not an admin of
  this org — the model's policy decides, and the surface only decides whether to OFFER the control);
  `{:error, :too_many_blocks}`; `{:error, :live_descendants}` (a subpage is still live, so the
  subtree cannot be destroyed whole).
  """
  @spec purge_page(Mount.t(), Samen.Scope.t(), term()) ::
          {:ok, struct()}
          | {:error, :not_found | :forbidden | :too_many_blocks | :live_descendants | term()}
  def purge_page(mount, scope, doc_id) do
    mount
    |> in_tx(fn ->
      with {:ok, doc} <- fetch_archived_doc(mount, scope, doc_id),
           {:ok, [purged | _]} <- purge_one(mount, scope, doc) do
        {:ok, purged}
      end
    end)
    |> classify_purge()
  end

  @doc """
  Empty the WHOLE trash — the trash's "Empty the trash" (Phase 3 unit 3.12).

  The same governed write as `purge_page/3`, applied to every page the trash holds: the pages are
  read through the `:archived` read (`trashed_docs/2`, newest-deleted first, bounded at
  `@purge_trash_limit` — the SAME 200 the view renders), and each is purged by `purge_one/3`
  INSIDE ONE `in_tx`. So:

    * **all or nothing** — a refusal anywhere (a member reaches this scope, a page past
      `@purge_block_limit`) rolls the whole transaction back and leaves the trash exactly as it
      was. There is no "emptied 3 of 7", which is the state a bulk delete must never leave behind;
    * **one audit row PER PAGE** — the batch does not get a summary row: `Doc.:purge` writes
      `record_purged` for each page in its own action, so the trail can still say WHICH pages were
      destroyed (and by whom) rather than that "some pages were removed";
    * **one page's reasons are unchanged** — the per-page guard (trash-only, admin-only,
      archive-first) and the cascade (links, blocks, then the page) are `purge_page/3`'s, because
      both paths reach them through the same `purge_one/3`.
    * **an empty trash is `{:ok, []}`** — a no-op, not an error, and no audit row: an idempotent
      click (or a stale tab) cannot invent a delete that never happened;
    * **the subtree goes with each page** — `purge_one/3` takes the trashed pages under the page it
      was given, and the loop SKIPS the ids that cascade already removed instead of asking for a
      row that is gone (which would be `:not_found` and would roll the whole empty back).

  The bound is a work bound, not a promise of emptiness: a trash older than 200 pages is emptied
  over successive calls, and the view's reload shows the remainder rather than the surface claiming
  a trash it did not empty.

  Returns `{:ok, purged_docs}` — EVERY page destroyed, so a parent's cascaded subtree is in the
  list too (each exactly once; the loop skips ids a parent's purge already took), newest-deleted
  first; `{:error, :forbidden}` (not an admin — the model's policy decides, per page);
  `{:error, :too_many_blocks}` (a page in the trash is past the block bound);
  `{:error, :live_descendants}` (a page in the trash still has a live subpage, so its subtree
  cannot be destroyed whole — nothing was destroyed).
  """
  @spec empty_trash(Mount.t(), Samen.Scope.t()) ::
          {:ok, [struct()]}
          | {:error, :forbidden | :too_many_blocks | :live_descendants | term()}
  def empty_trash(mount, scope) do
    mount
    |> in_tx(fn ->
      with {:ok, docs} <- trashed_docs(mount, scope) do
        # A parent's purge takes its whole subtree with it, so the list this loop is walking can name
        # rows that are already gone by the time it reaches them: `done` is what keeps the second
        # pass from asking for a page the first one destroyed (which would be `:not_found` and would
        # roll the whole empty back for no reason).
        docs
        |> Enum.reduce_while({:ok, [], MapSet.new()}, fn doc, {:ok, acc, done} ->
          if MapSet.member?(done, doc.id) do
            {:cont, {:ok, acc, done}}
          else
            case purge_one(mount, scope, doc) do
              {:ok, purged} ->
                {:cont, {:ok, acc ++ purged, Enum.reduce(purged, done, &MapSet.put(&2, &1.id))}}

              {:error, error} ->
                {:halt, {:error, error}}
            end
          end
        end)
        |> case do
          {:ok, purged, _done} -> {:ok, purged}
          {:error, error} -> {:error, error}
        end
      end
    end)
    |> classify_purge()
  end

  # ONE page's terminal delete AND everything under it, inside the CALLER's transaction — the caller
  # decides the scope of that transaction (one page, or the whole trash). Children before the page
  # they hang from, and blocks before the page they belong to, so a failure can never leave a page
  # whose content (or whose subtree) outlived it. Returns the destroyed pages, ROOT FIRST.
  defp purge_one(mount, scope, doc) do
    with {:ok, %{live: live, archived: archived}} <- Tree.subtree(doc_resource(mount), doc.id),
         :ok <- refuse_live_descendants(live),
         {:ok, descendants} <- purge_each(mount, scope, Enum.reverse(archived)),
         {:ok, [purged]} <- purge_each(mount, scope, [doc]) do
      {:ok, [purged | Enum.reverse(descendants)]}
    end
  end

  # A live page is not this seam's to destroy, even as part of a subtree: it has not been deleted,
  # so nothing sanctioned a hard delete of it. The trash shows the page and the user deletes the
  # live child first (which lands it in the trash, where emptying can reach it).
  defp refuse_live_descendants([]), do: :ok
  defp refuse_live_descendants(_live), do: {:error, :live_descendants}

  defp purge_each(mount, scope, docs) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, acc} ->
      case purge_row(mount, scope, doc) do
        {:ok, purged} -> {:cont, {:ok, [purged | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, purged} -> {:ok, Enum.reverse(purged)}
      {:error, error} -> {:error, error}
    end
  end

  # One page's rows: both link directions, then its blocks, then the page itself.
  defp purge_row(mount, scope, doc) do
    with {:ok, _links} <- destroy_page_links(mount, scope, doc.id),
         :ok <- purge_blocks(mount, scope, doc.id),
         {:ok, purged} <-
           doc
           |> Ash.Changeset.for_destroy(:purge, %{}, scope: scope)
           |> destroy() do
      {:ok, purged}
    end
  end

  # The pages the bulk empty acts on: the SAME `:archived` read the trash view lists, newest-deleted
  # first and bounded, so the write and the list cannot disagree about what "the trash" is. Nothing
  # about a page's CONTENT is selected — a purge reads ids (and the revision the structural
  # broadcast carries), never a body.
  defp trashed_docs(mount, scope) do
    query =
      mount
      |> doc_resource()
      |> Ash.Query.for_read(:archived)
      |> Ash.Query.ensure_selected([:id, :revision, :archived_at])
      |> Ash.Query.sort(archived_at: :desc)
      |> Ash.Query.limit(@purge_trash_limit)

    case Ash.read(query, scope: scope) do
      {:ok, docs} -> {:ok, docs}
      {:error, error} -> {:error, error}
    end
  end

  defp classify_purge({:error, error}), do: {:error, purge_error(error)}
  defp classify_purge(ok), do: ok

  # A policy refusal arrives as `Ash.Error.Forbidden` (a single error) or wrapped in
  # `Ash.Error.Invalid`; the surface shows ONE message for "not you", so it is classified here —
  # the same shape `declassify/4` uses.
  defp purge_error(:not_found), do: :not_found
  defp purge_error(:too_many_blocks), do: :too_many_blocks
  defp purge_error(:live_descendants), do: :live_descendants
  defp purge_error(%Ash.Error.Forbidden{}), do: :forbidden
  defp purge_error(error), do: if(forbidden_error?(error), do: :forbidden, else: error)

  # The ids of the page's blocks, then one hard destroy each — `:destroy_permanently`, because an
  # ARCHIVED block is still a block holding content, and the point of a purge is that the content is
  # gone. Only `id` is selected: this path reads no text at all, vaulted or plain.
  defp purge_blocks(mount, scope, doc_id) do
    rows =
      mount
      |> block_resource()
      |> Ash.Query.ensure_selected([:id, :org_id])
      |> Ash.Query.filter(doc_id == ^doc_id)
      |> Ash.Query.limit(@purge_block_limit)
      |> Ash.read!(scope: scope)

    if length(rows) >= @purge_block_limit do
      {:error, :too_many_blocks}
    else
      Enum.reduce_while(rows, :ok, fn block, :ok ->
        case block
             |> Ash.Changeset.for_destroy(:destroy_permanently, %{}, scope: scope)
             |> destroy() do
          {:ok, _} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
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

  # Deleting a page takes BOTH directions of its edge set with it (ADR-053 §3.1): the page's own
  # `[[Title]]`s (source) and the pages that linked here (target). A `DocLink` row asserts "this
  # page links to that LIVE page"; once the target is archived the row is stale by construction
  # (every read seam already renders the text as unresolved), so destroying it keeps the edge
  # table honest instead of leaving rows pointing at a page the workspace no longer has. Nothing
  # is lost that a restore cannot re-derive: the link INTENT lives in the source block's text, and
  # the next save of that page re-creates the edge.
  #
  # Each direction is bounded by @link_limit like every other fan-out in this module.
  defp destroy_page_links(mount, scope, doc_id) do
    base =
      mount
      |> link_resource()
      |> Ash.Query.ensure_selected([:id, :source_doc_id, :target_doc_id, :anchor_text])
      |> Ash.Query.limit(@link_limit)

    with {:ok, outgoing} <- read_page_links(base, :source, doc_id, scope),
         {:ok, incoming} <- read_page_links(base, :target, doc_id, scope) do
      (outgoing ++ incoming)
      |> Enum.uniq_by(& &1.id)
      |> Enum.reduce_while({:ok, []}, fn link, {:ok, acc} ->
        case destroy_link(link, scope) do
          {:ok, destroyed} -> {:cont, {:ok, [destroyed | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp read_page_links(base, :source, doc_id, scope) do
    base
    |> Ash.Query.filter(source_doc_id == ^doc_id)
    |> read_link_rows(scope)
  end

  defp read_page_links(base, :target, doc_id, scope) do
    base
    |> Ash.Query.filter(target_doc_id == ^doc_id)
    |> read_link_rows(scope)
  end

  defp read_link_rows(query, scope) do
    case Ash.read(query, scope: scope) do
      {:ok, links} -> {:ok, links}
      {:error, error} -> {:error, error}
    end
  end

  # ── positions ──────────────────────────────────────────────────────────────

  # Choose a position between the neighbours named by the hints, appending when there is no hint.
  # When the chosen slot has no room (adjacent ordinals), the parent's siblings are rebalanced to
  # fresh gaps and the choice is retried ONCE (`rebalanced?`), so this cannot loop.
  defp insert_position(
         mount,
         scope,
         doc_id,
         parent,
         siblings,
         after_id,
         before_id,
         rebalanced? \\ false
       ) do
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

  # A deleted page is readable only through the `:archived` read — the ordinary read is
  # archive-filtered, which is exactly why "it is gone" and "it can be undone" are both true.
  defp fetch_archived_doc(mount, scope, doc_id) do
    query =
      mount
      |> doc_resource()
      |> Ash.Query.for_read(:archived)
      |> Ash.Query.ensure_selected(@doc_select)
      |> Ash.Query.filter(id == ^doc_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [doc | _]} -> {:ok, doc}
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
