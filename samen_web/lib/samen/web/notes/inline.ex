defmodule Samen.Web.Notes.Inline do
  @moduledoc """
  The **constrained inline dialect** for WS-Notes (ADR-053 §2 D3; WS-Notes Phase 2 unit 2.3).

  Stored block text is never HTML. This module tokenises a closed set of inline forms and renders
  each token into **constructed HEEx** — the render path contains no `raw/1` (invariant R12), so
  stored text cannot become executable markup even if the author types markup. Everything that is
  not a recognised token is emitted literally, escaped by HEEx.

  ## The closed grammar

  | Form | Token | Renders |
  |---|---|---|
  | `**bold**` | `:bold` | `<strong>` |
  | `*italic*` | `:italic` | `<em>` |
  | `` `code` `` | `:code` | `<code>` |
  | `~~strike~~` | `:strike` | `<del>` |
  | `[text](https://…)` | `:link` | `<a href="…" rel="noopener noreferrer">` |
  | `[[Page]]` | `:page` | `<span class="inline-page-link" data-page="Page">` |
  | `@Name` | `:mention` | `<span class="inline-mention" data-mention="Name">` |

  That is the whole list. There is no nesting (`**bold with `code`**` is bold containing literal
  backticks), no arbitrary HTML, no URL schemes other than `http`/`https`, and no mention inside a
  word (`email@example.test` stays literal — the `@` must start at a word boundary). Emphasis also
  requires a non-space character at each edge, so prose arithmetic (`2 * 3 * 4`) stays literal
  instead of becoming an accidental italic.

  ## Near-misses are part of the spec

  An unclosed marker (`**bold`), a non-http link (`[x](ftp://…)`), a single-bracket page reference
  (`[Page]`), a bare `@`, and every other unknown form render **literally**. The test table in
  `notes_inline_test.exs` pairs every token with its near-miss twin, so widening the grammar
  without updating the table is a failing test, not a silent behaviour change.
  """

  use Phoenix.Component

  @type token :: %{
          required(:kind) => :text | :bold | :italic | :code | :strike | :link | :page | :mention,
          required(:text) => String.t(),
          optional(:href) => String.t()
        }

  # Ordered by precedence. `code` is first so a marker inside a code span is literal; `strike`
  # before `bold`/`italic` because `~~` also starts with `~` (no ambiguity, but explicit order
  # makes the intent reviewable); `bold` before `italic` so `**x**` never parses as `*` + `*x*`.
  @code ~r/\A`([^`\n]+)`/
  @strike ~r/\A~~([^~\s](?:[^~\n]*[^~\s])?)~~/
  @bold ~r/\A\*\*([^*\s](?:[^*\n]*[^*\s])?)\*\*/
  @italic ~r/\A\*([^*\s](?:[^*\n]*[^*\s])?)\*/
  @link ~r/\A\[([^\[\]\n]+)\]\((https?:\/\/[^\s)]+)\)/
  @page ~r/\A\[\[([^\[\]\n]+)\]\]/
  @mention ~r/\A@([A-Za-z][A-Za-z0-9_.\-]*)/

  # A mention only starts at a word boundary — otherwise an email address in prose would become a
  # mention of its domain ("a@b.test" → "@b.test"). These are the characters that may precede it.
  @mention_boundaries ["", " ", "\t", "\n", "(", "[", "{", ",", ";", ":", "\"", "'"]

  @doc """
  Render `text` as constructed HEEx (a `Phoenix.LiveView.Rendered`).

  Use it directly from a LiveView template (`<%= Inline.render(@block.text) %>`); tests convert it
  with `Phoenix.LiveViewTest.rendered_to_string/1`.
  """
  @spec render(binary()) :: Phoenix.LiveView.Rendered.t()
  def render(text) when is_binary(text) do
    assigns = %{nodes: tokenize(text)}
    ~H"<.inline_nodes nodes={@nodes} />"
  end

  @doc """
  Tokenise `text` into `:text | :bold | :italic | :code | :strike | :link | :page | :mention`
  tokens, coalescing adjacent literal text.

  Public because the dialect table is the spec: a test can assert the token stream (what the
  grammar recognised) independently of the HTML it renders to.
  """
  @spec tokenize(binary()) :: [token()]
  def tokenize(text) when is_binary(text), do: scan(text, "", [])

  # ── components ─────────────────────────────────────────────────────────────

  attr(:nodes, :list, required: true)

  def inline_nodes(assigns) do
    ~H"""
    <%= for node <- @nodes do %><.inline_node node={node} /><% end %>
    """
  end

  attr(:node, :map, required: true)

  def inline_node(%{node: %{kind: :text}} = assigns), do: ~H"<%= @node.text %>"

  def inline_node(%{node: %{kind: :bold}} = assigns),
    do: ~H"<strong><%= @node.text %></strong>"

  def inline_node(%{node: %{kind: :italic}} = assigns),
    do: ~H"<em><%= @node.text %></em>"

  def inline_node(%{node: %{kind: :code}} = assigns),
    do: ~H"<code><%= @node.text %></code>"

  def inline_node(%{node: %{kind: :strike}} = assigns),
    do: ~H"<del><%= @node.text %></del>"

  def inline_node(%{node: %{kind: :link}} = assigns) do
    ~H"""
    <a href={@node.href} rel="noopener noreferrer"><%= @node.text %></a>
    """
  end

  # A page reference is not a link until Phase 4 resolves it against an org-scoped title; until
  # then it renders as a labelled span carrying the typed title (never an href to nowhere).
  def inline_node(%{node: %{kind: :page}} = assigns) do
    ~H"""
    <span class="inline-page-link" data-page={@node.text}><%= @node.text %></span>
    """
  end

  def inline_node(%{node: %{kind: :mention}} = assigns) do
    ~H"""
    <span class="inline-mention" data-mention={@node.text}>@<%= @node.text %></span>
    """
  end

  # ── tokeniser ──────────────────────────────────────────────────────────────

  defp scan("", buffer, acc), do: Enum.reverse(flush_text(acc, buffer))

  defp scan(rest, buffer, acc) do
    case match(rest, String.last(buffer) || "") do
      {token, tail} -> scan(tail, "", [token | flush_text(acc, buffer)])
      nil -> append_grapheme(rest, buffer, acc)
    end
  end

  defp append_grapheme(rest, buffer, acc) do
    case String.next_grapheme(rest) do
      nil -> Enum.reverse(flush_text(acc, buffer))
      {grapheme, tail} -> scan(tail, buffer <> grapheme, acc)
    end
  end

  defp flush_text(acc, ""), do: acc
  defp flush_text(acc, buffer), do: [%{kind: :text, text: buffer} | acc]

  defp match(text, previous) do
    cond do
      token = run(@code, :code, text) -> token
      token = run(@strike, :strike, text) -> token
      token = run(@bold, :bold, text) -> token
      token = run(@italic, :italic, text) -> token
      token = run(@link, :link, text) -> token
      token = run(@page, :page, text) -> token
      previous in @mention_boundaries -> run(@mention, :mention, text)
      true -> nil
    end
  end

  # The patterns are anchored (`\A`), so the full match is a literal prefix: the tail is the text
  # after the matched BYTES (captures are byte offsets from `return: :index`, so multi-byte content
  # — emoji, CJK — neither miscounts nor corrupts the remainder).
  defp run(regex, kind, text) do
    case Regex.run(regex, text, return: :index) do
      [{0, matched_bytes} | captures] ->
        tail = binary_part(text, matched_bytes, byte_size(text) - matched_bytes)

        token =
          case {kind, Enum.map(captures, &binary_part(text, elem(&1, 0), elem(&1, 1)))} do
            {:link, [label, href]} -> %{kind: :link, text: label, href: href}
            {kind, [content]} -> %{kind: kind, text: content}
          end

        {token, tail}

      nil ->
        nil
    end
  end
end
