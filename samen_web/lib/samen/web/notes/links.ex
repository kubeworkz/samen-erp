defmodule Samen.Web.Notes.Links do
  @moduledoc """
  `[[Title]]` parsing and ORG-SCOPED resolution for WS-Notes (ADR-053 §3/§5; WS-Notes Phase 4
  unit 4.3).

  ## One parser, one resolution

  The dialect tokeniser is already the single definition of what a page reference IS
  (`Samen.Web.Notes.Inline.tokenize/1`); this module only extracts the `:page` tokens from it,
  so a link and a rendered `[[Page]]` can never disagree about the grammar. `titles/1` is pure
  and is the ONLY place a title string is read out of stored text.

  Resolution is a `Doc` lookup **through the acting scope** — never a raw read. That is R13: a
  title that exists only in ANOTHER org simply does not resolve, because `OrgScope` filters the
  candidate row out rather than returning a forbidden one (no existence oracle). Archived pages
  do not resolve either (AshArchival filters the read), which is what drops an archived target
  out of the link graph on the next save (R15's backlink half).

  ## What is deliberately NOT parsed

  Only the PLAIN `text` column feeds `titles/1`. A vaulted `text_secure` block is never scanned:
  a link edge is a non-PII row visible on the target page, so turning vaulted content into a
  backlink would leak the fact — and the title — of content the vault exists to keep out of
  every aggregate. Search makes the same choice (only `text` is indexed), so the two agree.
  """

  require Ash.Query

  alias Samen.Web.Mount

  # A DoS / row-transfer bound shared with `Samen.Web.Notes.Reads`; a page that exceeds it is a
  # signal to split, not to stream an unbounded result set into a link sync.
  @block_limit 2_000

  @doc """
  The distinct `[[Title]]` references in `text`, trimmed and bounded — `[]` for anything that is
  not a binary (a `%Samen.Masked{}` block is never parsed).

      iex> titles("See [[Runbook]] and [[Runbook]] and [[ Release ]]")
      ["Runbook", "Release"]
  """
  @spec titles(term()) :: [String.t()]
  def titles(text) when is_binary(text) do
    text
    |> Samen.Web.Notes.Inline.tokenize()
    |> Enum.filter(&(&1.kind == :page))
    |> Enum.map(&String.trim(&1.text))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def titles(_), do: []

  @doc """
  Resolve ONE title inside `scope`.

  `{:ok, doc}` only when a live, same-org page with that exact title exists; otherwise
  `:unresolved`. The read is scoped (`OrgScope`) and archive-filtered (AshArchival), so a
  cross-org or archived title resolves to `:unresolved` — never to a doc from another org.
  """
  @spec resolve(Mount.t(), Samen.Scope.t(), String.t()) :: {:ok, struct()} | :unresolved
  def resolve(mount, scope, title) when is_binary(title) do
    query =
      mount
      |> doc_resource()
      |> Ash.Query.ensure_selected([:id, :title])
      |> Ash.Query.filter(title == ^title)
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, [doc | _]} -> {:ok, doc}
      _ -> :unresolved
    end
  end

  def resolve(_mount, _scope, _title), do: :unresolved

  @doc """
  Resolve many titles at once, returning `%{title => doc}` for the ones that resolve.

  The map is keyed by the TYPED title (the anchor text), so a caller can always tell what the
  author wrote even when the target's current title differs (the stale-title hint).
  """
  @spec resolve_all(Mount.t(), Samen.Scope.t(), [String.t()]) :: %{String.t() => struct()}
  def resolve_all(mount, scope, titles) when is_list(titles) do
    titles
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn title, acc ->
      case resolve(mount, scope, title) do
        {:ok, doc} -> Map.put(acc, title, doc)
        :unresolved -> acc
      end
    end)
  end

  @doc """
  Every `[[Title]]` in the PLAIN text of `doc_id`'s live blocks — the page's link intent.

  Reads only `text` (never `text_secure`), and only live blocks (AshArchival excludes archived
  rows), so a removed block stops contributing links on the next sync.
  """
  @spec page_titles(Mount.t(), Samen.Scope.t(), term()) :: [String.t()]
  def page_titles(mount, scope, doc_id) do
    mount
    |> block_resource()
    |> Ash.Query.ensure_selected([:text])
    |> Ash.Query.filter(doc_id == ^doc_id)
    |> Ash.Query.limit(@block_limit)
    |> Ash.read!(scope: scope)
    |> Enum.flat_map(&titles(Map.get(&1, :text)))
    |> Enum.uniq()
  end

  # `Mount.resource/2` concatenates a SHORT name onto the mount's namespace, so these are the
  # `:Doc`/`:DocBlock` atoms (the aliased modules would concatenate twice).
  defp doc_resource(mount), do: Mount.resource(mount, :Doc)
  defp block_resource(mount), do: Mount.resource(mount, :DocBlock)
end
