defmodule Samen.Web.NotesInlineTest do
  @moduledoc """
  WS-Notes Phase 2 unit 2.3 (ADR-053 §2 D3) — **the dialect table is the spec**.

  Every row below is a pair: the recognised token and the near-miss that must stay LITERAL.
  Widening the grammar without adding the matching near-miss is therefore a failing test
  (an unknown form that suddenly renders as markup), which is the property the design
  cares about: the dialect is closed, and "unknown syntax renders literally" is asserted,
  not assumed.

  The render half asserts CONSTRUCTED HEEx: stored text can carry `<script>` and it comes
  out escaped, and no row produces an element the grammar did not name.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Samen.Web.Notes.Inline

  # recognised form => expected token stream (kind + text, plus href for links)
  @tokens [
    {"plain paragraph", [{:text, "plain paragraph"}]},
    {"**bold**", [{:bold, "bold"}]},
    {"*italic*", [{:italic, "italic"}]},
    {"`code()`", [{:code, "code()"}]},
    {"~~gone~~", [{:strike, "gone"}]},
    {"[[Q3 planning]]", [{:page, "Q3 planning"}]},
    {"@Ada", [{:mention, "Ada"}]},
    {"**<b>x</b>**", [{:bold, "<b>x</b>"}]},
    {"a **b** c", [{:text, "a "}, {:bold, "b"}, {:text, " c"}]},
    {"a *b* c", [{:text, "a "}, {:italic, "b"}, {:text, " c"}]},
    {"text `1 < 2` tail", [{:text, "text "}, {:code, "1 < 2"}, {:text, " tail"}]},
    {"ping @Ada_lovelace now", [{:text, "ping "}, {:mention, "Ada_lovelace"}, {:text, " now"}]},
    {"see [[Q3]] now", [{:text, "see "}, {:page, "Q3"}, {:text, " now"}]}
  ]

  # form => why it must NOT be recognised (rendered exactly as typed)
  @near_misses [
    {"**unclosed", "unclosed bold"},
    {"*unclosed", "unclosed italic"},
    {"`unclosed", "unclosed code"},
    {"~~unclosed", "unclosed strike"},
    {"** padded **", "leading/trailing space inside emphasis"},
    {"2 * 3 * 4", "arithmetic is not an italic"},
    {"__underscore__", "no underscore emphasis"},
    {"two ~~ tildes", "a strike needs non-space edges"},
    {"[label](ftp://example.test/x)", "only http(s) links"},
    {"[label](javascript:alert(1))", "only http(s) links"},
    {"[label](https://example.test/x", "unclosed link"},
    {"[Page]", "single brackets are not a page ref"},
    {"[[unclosed", "unclosed page ref"},
    {"a@b.test", "a mention needs a word boundary (emails stay literal)"},
    {"@ alone", "a bare @ is not a mention"},
    {"``", "empty code is not code"}
  ]

  describe "recognised tokens (the grammar)" do
    for {input, expected} <- @tokens do
      test "#{inspect(input)} tokenises to #{inspect(expected)}" do
        assert Inline.tokenize(unquote(input)) ==
                 Enum.map(unquote(expected), &token/1),
               "dialect row #{inspect(unquote(input))} did not tokenise as specified"
      end
    end
  end

  describe "near-misses stay literal (unknown syntax renders as typed)" do
    for {input, why} <- @near_misses do
      test "#{inspect(input)} is literal — #{why}" do
        tokens = Inline.tokenize(unquote(input))

        assert length(tokens) == 1,
               "near-miss #{inspect(unquote(input))} was partially recognised as #{inspect(tokens)}"

        assert hd(tokens) == %{kind: :text, text: unquote(input)}
      end
    end
  end

  describe "links carry their target, and only http(s) survive" do
    test "an https link tokenises with its href" do
      assert [%{kind: :link, text: "docs", href: "https://example.test/a?b=1"}] =
               Inline.tokenize("[docs](https://example.test/a?b=1)")
    end

    test "an http link is accepted too" do
      assert [%{kind: :link, text: "home", href: "http://example.test"}] =
               Inline.tokenize("[home](http://example.test)")
    end
  end

  describe "render/1 — constructed HEEx, never stored markup" do
    test "each recognised form renders the element the grammar names" do
      assert html("**bold**") == "<strong>bold</strong>"
      assert html("*italic*") == "<em>italic</em>"
      assert html("`code`") == "<code>code</code>"
      assert html("~~gone~~") == "<del>gone</del>"
      assert html("[t](https://example.test/x)") ==
               ~s(<a href="https://example.test/x" rel="noopener noreferrer">t</a>)
      assert html("[[Q3]]") == ~s(<span class="inline-page-link" data-page="Q3">Q3</span>)
      assert html("@Ada") == ~s(<span class="inline-mention" data-mention="Ada">@Ada</span>)
    end

    test "stored markup is ESCAPED, not executed (no raw/1 on the render path)" do
      assert html("<script>alert(1)</script>") == "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "markup INSIDE a recognised token is escaped as the token's text" do
      assert html("**<img src=x onerror=alert(1)>**") ==
               "<strong>&lt;img src=x onerror=alert(1)&gt;</strong>"
    end

    test "a javascript: href never becomes an attribute" do
      rendered = html("[x](javascript:alert(1))")

      refute rendered =~ "href"
      assert rendered == "[x](javascript:alert(1))"
    end

    test "mixed content renders in order, text escapes around tokens" do
      rendered = html("a **b** & c")

      assert rendered == "a <strong>b</strong> &amp; c"
    end

    test "an empty string renders nothing" do
      assert html("") == ""
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp html(text), do: text |> Inline.render() |> rendered_to_string()

  defp token({kind, text}), do: %{kind: kind, text: text}
end
