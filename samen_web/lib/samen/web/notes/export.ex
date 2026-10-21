defmodule Samen.Web.Notes.Export do
  @moduledoc """
  WS-Notes Phase 2 unit 2.4 — a page rendered as Markdown or CSV (ADR-053 §5 D5, §6 **R6**).

  ## R6: an export is a RENDERING of the read seam, not a serializer over rows

  The failure R6 names — "the export path reads the field directly" — is the classic
  mask-by-omission leak (ADR-028): a serializer reads the stored row and writes its columns, so a
  vaulted `vt_*` token, or a plaintext the plane should have masked, leaves the system through a
  download the UI would never have shown.

  This module is built so that failure is not expressible here. Both renderers take their content
  from `Samen.Web.Notes.Reads.page/3` — the ONE read seam, which resolves every block's visible
  text through `Samen.Api.PiiResolution` on the acting plane and hands back a `%Samen.Masked{}`
  when the plane may not see the value. `load/3` is the only place that touches storage, and it
  names no column at all: there is no `text`, no `text_secure`, no `Ash.read` in this file. The
  export therefore shows EXACTLY what the editor shows on the same plane:

    * tenant plane (own org) → the clear text of its own page;
    * operator plane without a grant → `••••`, never the plaintext, never a vault token;
    * a masked value is stringified (`%Samen.Masked{}`'s `String.Chars` impl), never unwrapped.

  ## Markdown

  A `# Title` heading followed by one chunk per block, in `(position, id)` order — the order the
  editor renders. Block `heading_1..3` map to `##`..`####` (the page title owns `#`), list items to
  `-` / `1.`, `to_do` to `- [x]`, `quote` to `>`, `code` to a fenced block with its declared
  language, `divider` to `---`, `callout` to a `> [!NOTE]` aside, and `page_link` back to the
  `[[Page]]` form the inline dialect links from — so an exported page round-trips INTO Pages.

  A page with zero blocks exports its legacy `body`/`secure_body` (ADR-053 §8 O3): `Reads` already
  made that decision, on the same plane, and this module renders whatever it decided.

  Stored text is TEXT here too (R12's export half): `&`, `<` and `>` in block text are escaped, so
  a paragraph containing `<script>` downloads as those characters instead of becoming a live tag
  in whatever Markdown viewer opens the file. Nothing is stripped — the export still says exactly
  what the page says — and a fenced `code` block keeps its bytes, since a fence is already a
  literal context. The mask is applied by `Reads` BEFORE this step, so `••••` is never escaped
  into (or out of) anything.

  ## CSV

  One row per block: `position,type,text,checked`. Serialization goes through
  `Samen.Web.Csv.serialize/1`, so quoting, embedded newlines and the CSV formula-injection
  neutralization (a cell beginning `=`, `+`, `-`, `@`, TAB or CR) are the SAME code path the
  framework's catalog-driven CSV export uses — a second, subtly different escaper is exactly how
  one of them drifts.

  ## Clipboard

  `copy_text/3` is the third export the ADR names, and the one with the shortest path out of the
  app: the editor's "Copy page" pushes its result to the CLIENT, which hands it to
  `navigator.clipboard.writeText/1`. Same `load/3`, same plane decision, no syntax (no `#`, no
  bullets, no fences) and deliberately NO HTML escaping — a clipboard is text, so `&`/`<`/`>` stay
  literal rather than pasting `&lt;` into the reader's document. The push goes to the requesting
  socket only: it is a reply to the person who clicked, not a broadcast (contrast R8, where
  PubSub envelopes carry ids so text never rides the topic).

  ## Bounded

  Nothing here iterates a table: one page is one `Reads.page/3` call, whose block fan-out is
  bounded (`Reads`' `@block_limit`). There is no "export the whole workspace" mode; that would be a
  different surface with its own bound, not a flag on this one.
  """

  alias Samen.Web.Csv
  alias Samen.Web.Notes.Reads

  @csv_header ["position", "type", "text", "checked"]

  @typedoc "The downloaded artifact: the body bytes and a header-safe filename."
  @type artifact :: %{body: String.t(), filename: String.t()}

  @doc """
  Render `doc_id` as Markdown for `scope` on the mount's plane.

  `{:ok, %{body: markdown, filename: "some-title.md"}}`, or `{:error, :not_found}` for an unknown
  page — including another org's page, which `Reads` filters out rather than reporting as
  forbidden (R1: no existence oracle).
  """
  @spec markdown(Samen.Web.Mount.t(), Samen.Scope.t(), term()) ::
          {:ok, artifact()} | {:error, :not_found}
  def markdown(mount, scope, doc_id) do
    with {:ok, page} <- load(mount, scope, doc_id) do
      {:ok, %{body: markdown_body(page), filename: filename(page.doc, "md")}}
    end
  end

  @doc """
  Render `doc_id` as CSV for `scope` on the mount's plane — the block rows of one page.

  Same contract as `markdown/3` (including the not-found behaviour and the per-plane masking,
  which is inherited from the same read).
  """
  @spec csv(Samen.Web.Mount.t(), Samen.Scope.t(), term()) ::
          {:ok, artifact()} | {:error, :not_found}
  def csv(mount, scope, doc_id) do
    with {:ok, page} <- load(mount, scope, doc_id) do
      {:ok, %{body: csv_body(page), filename: filename(page.doc, "csv")}}
    end
  end

  @doc """
  Render `doc_id` as PLAIN TEXT for the clipboard — `PageLive`'s "Copy page" (R6's clipboard
  half: ADR-053 §5 D5 names Markdown, CSV **and** clipboard-copy as exports that resolve through
  the same seam).

  `{:ok, %{body: text}}` or `{:error, :not_found}`, exactly like `markdown/3` — and, because it
  goes through the SAME `load/3`, exactly the same plane decision: the tenant's own page copies in
  the CLEAR, and an operator-plane copy is the mask, never the plaintext and never a `vt_*` token.
  The clipboard is the leak this proves: `navigator.clipboard.writeText/1` is a one-line
  exfiltration path, so the bytes it is handed are the bytes the plane allowed.

  Plain text is not Markdown: no heading `#`, no list bullets, no fenced code, and NO HTML
  escaping (`&`/`<`/`>` stay literal, because a clipboard is text and escaping it would paste
  `&lt;` into the reader's document). A `to_do` keeps its state as `[x]`/`[ ]`, a divider becomes a
  rule glyph, and every other block contributes its text as-is — including a `code` block's bytes.
  """
  @spec copy_text(Samen.Web.Mount.t(), Samen.Scope.t(), term()) ::
          {:ok, %{body: String.t()}} | {:error, :not_found}
  def copy_text(mount, scope, doc_id) do
    with {:ok, page} <- load(mount, scope, doc_id) do
      {:ok, %{body: plain_body(page)}}
    end
  end

  @doc """
  The attachment filename for `doc` with extension `ext` — a slug of the title, or `page.<ext>`.

  Bounded to `[a-z0-9-]` and 60 characters on purpose: this string goes into a
  `content-disposition` header, so a title can never inject a header line, a quote, or a path
  separator. A non-ASCII title slugs to nothing and falls back to `page`.
  """
  @spec filename(map(), String.t()) :: String.t()
  def filename(doc, ext) do
    "#{slug(title(doc))}.#{ext}"
  end

  # ── the ONE read (R6) ───────────────────────────────────────────────────────

  # Export reads through `Reads` — never the fields. That is the whole of R6's mechanism: the
  # plane resolution happened in one place, and this module cannot disagree with it because it
  # never sees a raw column.
  defp load(mount, scope, doc_id), do: Reads.page(mount, scope, doc_id)

  # ── clipboard (plain text) ─────────────────────────────────────────────────

  # Same title, same words, no syntax. Built from the blocks `Reads` already plane-resolved, so a
  # masked value stringifies to `••••` here exactly as it does in Markdown (and a blank line
  # separates blocks, which is what a paste into a text field should look like).
  defp plain_body(page) do
    case [title(page.doc) | plain_chunks(page.blocks, page.legacy)]
         |> Enum.reject(&(&1 == ""))
         |> Enum.join("\n\n") do
      "" -> ""
      text -> text <> "\n"
    end
  end

  defp plain_chunks([], nil), do: []

  # Zero blocks: the legacy body IS the page (ADR-053 §8 O3), plane-resolved by `Reads`.
  defp plain_chunks([], legacy), do: [text(legacy.text)]

  defp plain_chunks(blocks, _legacy) do
    blocks
    |> Enum.map(&plain_chunk/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp plain_chunk(%{type: :divider}), do: "———"

  defp plain_chunk(%{type: :to_do} = block),
    do: "[#{checkbox(block.checked)}] " <> text(block.text)

  defp plain_chunk(block), do: text(Map.get(block, :text))

  # ── markdown ────────────────────────────────────────────────────────────────

  defp markdown_body(page) do
    chunks = ["# #{md_text(title(page.doc))}"] ++ block_chunks(page.blocks, page.legacy)
    Enum.join(chunks, "\n\n") <> "\n"
  end

  defp block_chunks([], nil), do: []

  # Zero blocks: the legacy body IS the page (ADR-053 §8 O3) — already plane-resolved by `Reads`.
  defp block_chunks([], legacy), do: [quote_lines(md_text(legacy.text))]

  defp block_chunks(blocks, _legacy) do
    {chunks, _n} =
      Enum.map_reduce(blocks, 0, fn
        # Numbering counts a CONSECUTIVE run of numbered items, and resets on any other block —
        # the same thing a reader expects from the rendered list.
        %{type: :numbered_list_item} = block, n -> {"#{n + 1}. #{md_text(block.text)}", n + 1}
        block, _n -> {block_chunk(block), 0}
      end)

    Enum.reject(chunks, &(&1 == ""))
  end

  defp block_chunk(%{type: :paragraph} = block), do: md_text(block.text)
  # The page title owns `#`; block headings shift one level down so the export has ONE H1.
  defp block_chunk(%{type: :heading_1} = block), do: "## " <> md_text(block.text)
  defp block_chunk(%{type: :heading_2} = block), do: "### " <> md_text(block.text)
  defp block_chunk(%{type: :heading_3} = block), do: "#### " <> md_text(block.text)
  defp block_chunk(%{type: :bulleted_list_item} = block), do: "- " <> md_text(block.text)

  defp block_chunk(%{type: :to_do} = block),
    do: "- [#{checkbox(block.checked)}] " <> md_text(block.text)

  defp block_chunk(%{type: :quote} = block), do: quote_lines(md_text(block.text))
  defp block_chunk(%{type: :divider}), do: "---"

  defp block_chunk(%{type: :callout} = block) do
    case md_text(block.text) do
      "" -> "> [!NOTE]"
      body -> "> [!NOTE]\n" <> quote_lines(body)
    end
  end

  # A fenced block is already a LITERAL context in every Markdown renderer, so its bytes are
  # carried through unescaped — escaping here would corrupt the code it is exporting.
  defp block_chunk(%{type: :code} = block) do
    fence = "```"
    "#{fence}#{language(block)}\n#{text(block.text)}\n#{fence}"
  end

  # A page link exports in the form the inline dialect links FROM, so the Markdown re-imports into
  # Pages as the same relationship rather than as an opaque uuid.
  defp block_chunk(%{type: :page_link} = block) do
    case md_text(block.text) do
      "" -> ""
      label -> "[[" <> label <> "]]"
    end
  end

  # Not reachable through the model (`BlockShape` is a closed vocabulary), but a row written
  # before the vocabulary closed still exports its text instead of vanishing from the page.
  defp block_chunk(block), do: md_text(Map.get(block, :text))

  defp quote_lines(value) do
    case String.split(value, "\n") do
      [""] -> ">"
      lines -> Enum.map_join(lines, "\n", fn "" -> ">" ; line -> "> " <> line end)
    end
  end

  defp checkbox(true), do: "x"
  defp checkbox(_), do: " "

  defp language(%{metadata: %{"language" => language}}) when is_binary(language), do: language
  defp language(_), do: ""

  # ── csv ─────────────────────────────────────────────────────────────────────

  defp csv_body(page) do
    rows =
      case page.blocks do
        [] -> legacy_rows(page.legacy)
        blocks -> Enum.map(blocks, &csv_row/1)
      end

    Csv.serialize([@csv_header | rows])
  end

  defp csv_row(block) do
    [integer(block.position), type_token(block.type), text(block.text), checkbox_cell(block.checked)]
  end

  defp legacy_rows(nil), do: []
  defp legacy_rows(legacy), do: [["1", "paragraph", text(legacy.text), ""]]

  defp integer(value) when is_integer(value), do: Integer.to_string(value)
  defp integer(_), do: ""

  defp type_token(type) when is_atom(type) and not is_nil(type), do: Atom.to_string(type)
  defp type_token(type) when is_binary(type), do: type
  defp type_token(_), do: ""

  defp checkbox_cell(true), do: "true"
  defp checkbox_cell(false), do: "false"
  defp checkbox_cell(_), do: ""

  # ── values ──────────────────────────────────────────────────────────────────

  # The visible text as a STRING. On a masked plane `Reads` handed a `%Samen.Masked{}`, whose
  # `String.Chars` impl is the mask — so this stringifies a mask, never unwraps a token.
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  # Markdown's half of "stored text is NEVER markup" (R12). Block text is TEXT: a page whose
  # paragraph reads `<script>alert(1)</script>` must download as those characters, not as a tag a
  # Markdown viewer would execute, and an `&` must survive a round trip rather than starting an
  # entity. This is an ESCAPE, not a sanitizer — nothing is stripped, so the export still says
  # exactly what the page says.
  #
  # A masked value (`••••`) passes through unchanged: escaping is applied AFTER the plane resolved
  # the value, so the mask is never re-interpreted and no `vt_*` token can be reconstructed from
  # the HTML entities of one.
  defp md_text(value) do
    value
    |> text()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # `Doc.title` is non-PII by construction (only `body`/`secure_body` and the block text pair are
  # vault-routed), so a title is safe to export on every plane.
  defp title(doc) do
    case Map.get(doc, :title) do
      title when is_binary(title) and title != "" -> title
      _ -> "Untitled"
    end
  end

  defp slug(title) do
    case title
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/u, "-")
         |> String.trim("-")
         |> String.slice(0, 60)
         |> String.trim("-") do
      "" -> "page"
      slug -> slug
    end
  end
end
