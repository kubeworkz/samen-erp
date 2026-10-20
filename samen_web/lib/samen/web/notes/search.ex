defmodule Samen.Web.Notes.Search do
  @moduledoc """
  Block-level search for WS-Notes (ADR-053 §5/§6 R14/R15; WS-Notes Phase 4 units 4.1/4.2).

  ## What is indexed

  Exactly two registry rows: `Doc.title` and `DocBlock.text`. `text_secure` is a vault-routed
  `pii_attribute` and `SearchIndexGuard.assert_no_pii_column/2` refuses it structurally, so a
  vaulted block can never be registered into the tsvector even by mistake (R14). Registration
  runs through `register_index/2`, which calls that guard for BOTH fields and then writes the
  rows into the host's `SearchIndex`.

  A vaulted block is not merely unregistered: this module also drops any block whose
  `text_secure` is set from the result set, so even a row that somehow carried BOTH columns can
  never surface a match (the plain column of a vaulted block is not content the author chose to
  publish).

  ## Results are BLOCK-level

  A page hit (title matched) and a block hit (text matched) share one shape: the page id + title,
  a bounded snippet from the matched text, and the block id when there is one. The snippet is
  plain text — the renderer escapes it, exactly as the editor does (R12). Titles are non-PII by
  construction; snippets come only from the non-vaulted column.

  ## Archive discipline (R15)

  Search candidates go through the same org-scoped, archive-filtered reads as everything else:
  AshArchival removes archived blocks, and a matched block is joined to its LIVE page — a block
  whose page was archived is dropped rather than reported as a hit on a page that no longer
  exists. `Samen.Web.Notes.Reads.index/2` and `Reads.backlinks/3` apply the same rule to the
  tree and the backlink list.

  ## Fail-closed

  No mount `:search_index` seam, a blank term, or a failed registry read → `[]`. There is no
  match-all default, and search never becomes an unbounded scan (`@limit`).
  """

  require Ash.Query

  alias Samen.Scopes.Primitives.SearchIndexGuard
  alias Samen.Search
  alias Samen.Web.Mount

  @default_limit 20
  @snippet_graphemes 140

  defmodule Hit do
    @moduledoc """
    One block-level search hit: the live page it belongs to, the matched block (nil for a
    title hit), a bounded plaintext snippet, and the engine's rank.
    """
    @enforce_keys [:kind, :doc_id, :doc_title, :rank]
    defstruct [:kind, :doc_id, :doc_title, :block_id, :snippet, :rank]

    @type t :: %__MODULE__{
            kind: :page | :block,
            doc_id: term(),
            doc_title: String.t(),
            block_id: term() | nil,
            snippet: String.t() | nil,
            rank: float()
          }
  end

  @doc """
  Register `Doc.title` and `DocBlock.text` in the host's `SearchIndex` for `scope`'s org.

  Idempotent (an existing row for the same resource+field is left alone) and guard-first: the
  PII refusal runs BEFORE any row is written, so a future edit that names `text_secure` fails
  here rather than registering a vaulted column. Returns `:ok` or
  `{:error, :search_index_not_mounted}` when the mount carries no `:search_index` seam.
  """
  @spec register_index(Mount.t(), Samen.Scope.t()) :: :ok | {:error, term()}
  def register_index(mount, scope) do
    with index when not is_nil(index) <- index_resource(mount) do
      entries = [
        {doc_resource(mount), "title"},
        {block_resource(mount), "text"}
      ]

      Enum.reduce_while(entries, :ok, fn {resource, field}, :ok ->
        SearchIndexGuard.assert_no_pii_column(resource, field)

        case ensure_entry(mount, scope, index, resource, field) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    else
      _ -> {:error, :search_index_not_mounted}
    end
  end

  @doc """
  Search `term` over the registered non-PII fields, returning ranked `Hit`s.

  Options: `:limit` (global cap, default #{@default_limit}). A blank term, an unmounted search
  index, or an engine failure returns `[]` — never a partial-looking success.
  """
  @spec search(Mount.t(), Samen.Scope.t(), term(), keyword()) :: [Hit.t()]
  def search(mount, scope, term, opts \\ [])

  def search(_mount, _scope, term, _opts) when term in [nil, ""], do: []

  def search(mount, scope, term, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    term = String.trim(term)

    with false <- term == "",
         index when not is_nil(index) <- index_resource(mount) do
      doc_mod = doc_resource(mount)
      block_mod = block_resource(mount)

      results =
        Search.query(scope, term,
          resources: [doc_mod, block_mod],
          search_index: index,
          repo: mount.repo,
          limit: limit * 2
        )

      page_hits =
        for %{resource: ^doc_mod, id: id, rank: rank} = result <- results do
          %Hit{
            kind: :page,
            doc_id: id,
            doc_title: title_of(result),
            rank: to_rank(rank)
          }
        end

      block_hits = block_hits(results, block_mod, mount, scope, term)

      (page_hits ++ block_hits)
      |> Enum.sort_by(& &1.rank, :desc)
      |> Enum.take(limit)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # ── block hits ─────────────────────────────────────────────────────────────

  defp block_hits(results, block_mod, mount, scope, term) do
    blocks =
      results
      |> Enum.filter(&(&1.resource == block_mod))
      # R14/R5: a block with a vaulted half is never content the author published to search,
      # even if a plain column also carries a value.
      |> Enum.reject(&(not is_nil(Map.get(&1.record, :text_secure))))

    live = live_docs(mount, scope, Enum.map(blocks, & &1.record.doc_id))

    for block <- blocks,
        doc = Map.get(live, block.record.doc_id),
        not is_nil(doc) do
      %Hit{
        kind: :block,
        doc_id: doc.id,
        doc_title: doc.title || "Untitled",
        block_id: block.id,
        snippet: snippet(Map.get(block.record, :text), term),
        rank: to_rank(block.rank)
      }
    end
  end

  # The LIVE page for each matched block. The read is org-scoped AND archive-filtered, so a
  # block whose page was archived is simply absent from the map and its hit is dropped (R15).
  defp live_docs(_mount, _scope, []), do: %{}

  defp live_docs(mount, scope, doc_ids) do
    ids = doc_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    mount
    |> doc_resource()
    |> Ash.Query.ensure_selected([:id, :title])
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.limit(length(ids))
    |> Ash.read!(scope: scope)
    |> Map.new(&{&1.id, &1})
  rescue
    _ -> %{}
  end

  # ── snippets ───────────────────────────────────────────────────────────────

  defp snippet(text, term) when is_binary(text) and is_binary(term) and text != "" do
    case Regex.run(~r/#{Regex.escape(term)}/iu, text, return: :index) do
      [{index, _length}] ->
        # `index` is a BYTE offset into `text` and the regex only matches at a character
        # boundary; counting the graphemes before it gives a safe `String.slice/3` start.
        before = text |> binary_part(0, index) |> String.length()
        start = max(before - 40, 0)
        window = String.slice(text, start, @snippet_graphemes)

        prefix = if start > 0, do: "…", else: ""
        suffix = if start + @snippet_graphemes < String.length(text), do: "…", else: ""
        prefix <> window <> suffix

      nil ->
        bounded(text)
    end
  end

  defp snippet(_text, _term), do: nil

  defp bounded(text) do
    window = String.slice(text, 0, @snippet_graphemes)

    if String.length(text) > @snippet_graphemes do
      window <> "…"
    else
      window
    end
  end

  defp title_of(%{display: display}) when is_map(display) do
    case Map.get(display, :title) do
      title when is_binary(title) and title != "" -> title
      _ -> "Untitled"
    end
  end

  defp title_of(_), do: "Untitled"

  defp to_rank(rank) when is_float(rank), do: rank
  defp to_rank(rank) when is_integer(rank), do: rank * 1.0
  defp to_rank(_), do: 0.0

  # ── registration internals ─────────────────────────────────────────────────

  defp ensure_entry(_mount, scope, index, resource, field) do
    resource_name = inspect(resource)

    query =
      index
      |> Ash.Query.filter(resource_name == ^resource_name and field_name == ^field)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [_ | _]} ->
        :ok

      _ ->
        # Registration is HOST SETUP, not a tenant action: the `SearchIndex` create policy is
        # `RoleAtLeast :admin`, while a member's page write must not require an org admin to
        # have registered the frame. The guard above is the security check that matters (a
        # vaulted column can never be registered); the row itself carries no tenant content.
        # This is the same posture the hosts' own `mk_search_index/1` seed helpers take.
        index
        |> Ash.Changeset.for_create(:create, %{
          resource_name: resource_name,
          field_name: field,
          vector_column: "#{Samen.Info.abbrev(resource)}_search_vector",
          description: "WS-Notes: #{resource_name}.#{field} (non-PII only)",
          enabled: true,
          ts_config: "english",
          org_id: org_id(scope)
        })
        |> Ash.create(authorize?: false)
        |> case do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end
    end
  end

  defp org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp org_id(actor) when is_map(actor), do: Map.get(actor, :org_id)

  # The host's SearchIndex registry — a mount LABEL seam (`:search_index`) because the Docs
  # namespace has no SearchIndex of its own: the host mounts Primitives beside Docs. Absent ⇒
  # fail closed (no results, registration refused).
  defp index_resource(mount), do: Mount.label(mount, :search_index, nil)

  defp doc_resource(mount), do: Mount.resource(mount, :Doc)
  defp block_resource(mount), do: Mount.resource(mount, :DocBlock)
end
