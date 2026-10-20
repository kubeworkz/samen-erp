defmodule Samen.UI.NoteBlock do
  @moduledoc """
  The block-editor kit for WS-Notes (ADR-053 §2 D3 / §4; WS-Notes Phase 3 unit 3.3):
  `note_block_row/1`, `note_palette/1`, `note_conflict_banner/1`, `note_empty_state/1`.

  ## Masking (LOAD-BEARING)

  These components render whatever value they are handed and resolve NOTHING. A block arriving
  from `Samen.Web.Notes.Reads` carries an already plane-resolved `:text`: plaintext on the tenant
  plane, `%Samen.Masked{}` on an operator plane without a grant — which renders `••••` via the
  `Phoenix.HTML.Safe` impl on `Samen.Masked`. The read-only branch hands a binary to
  `Samen.Web.Notes.Inline`, and for a non-binary (masked) value it renders the value ITSELF, so a
  mask is never converted to a string and never re-classified here. There is no "reveal" branch,
  and no `raw/1` anywhere in this module (invariant R12).

  ## Why a `<textarea>` (ADR-053 §2 D3)

  The editable control is a native `<textarea>`: the browser owns its value, LiveView value-diffs
  it, and the platform handles IME/paste/caret — so the class of bugs a hand-rolled
  `contenteditable` fails cannot arise. Stored text is never HTML; the constrained inline dialect
  is tokenised server-side into CONSTRUCTED HEEx and is only used where the block is READ-ONLY
  (a masked plane, or a legacy body).

  The `NoteBlock` client hook (`priv/static/assets/app.js`) reports INTENT only: split at a caret
  offset, merge, indent, move, open the palette. It never resolves a stored value and never
  mutates the DOM except its own `rows` (auto-grow); the two things it reads are its OWN control's
  caret offset (for the split) and whether that control is empty (the `/` affordance), both of
  which exist only in the browser.
  """

  use Phoenix.Component

  alias Samen.Scopes.Docs.BlockShape

  @type_labels %{
    paragraph: "Text",
    heading_1: "Heading 1",
    heading_2: "Heading 2",
    heading_3: "Heading 3",
    bulleted_list_item: "Bulleted list",
    numbered_list_item: "Numbered list",
    to_do: "To-do",
    quote: "Quote",
    code: "Code",
    divider: "Divider",
    callout: "Callout",
    page_link: "Page link"
  }

  @doc "The bounded block types the palette offers (the SAME list the model validates)."
  @spec types() :: [atom()]
  def types, do: BlockShape.types()

  @doc "A human label for a block type — unknown tokens fall back to the raw token."
  @spec label(atom() | String.t()) :: String.t()
  def label(type) when is_atom(type), do: Map.get(@type_labels, type, Atom.to_string(type))

  # A string token is matched WITHOUT minting an atom (`String.to_existing_atom/1` would raise on
  # a token the model never defined — the hostile-input path, not the palette's).
  def label(type) when is_binary(type) do
    Enum.find_value(@type_labels, type, fn {token, label} ->
      if Atom.to_string(token) == type, do: label
    end)
  end

  def label(_), do: "Text"

  @doc "A one-glyph marker for the gutter — presentation only, never a value."
  @spec glyph(atom()) :: String.t()
  def glyph(:heading_1), do: "H1"
  def glyph(:heading_2), do: "H2"
  def glyph(:heading_3), do: "H3"
  def glyph(:bulleted_list_item), do: "•"
  def glyph(:numbered_list_item), do: "1."
  def glyph(:to_do), do: "☐"
  def glyph(:quote), do: "❝"
  def glyph(:code), do: "</>"
  def glyph(:divider), do: "—"
  def glyph(:callout), do: "!"
  def glyph(:page_link), do: "↗"
  def glyph(_), do: "¶"

  attr :block, :map, required: true
  attr :editable, :boolean, default: false
  attr :editing, :boolean, default: false
  slot :controls

  @doc """
  One block row: gutter glyph, the editable control (or the read-only inline render), and the
  caller's control slot.

  The editable branch posts `block_text` on the enclosing form and carries the block's
  `revision` as a hidden field, so the write seam's compare-and-set has the revision the client
  actually saw — a stale tab is refused (`{:error, :stale}`) instead of overwriting (R9).
  """
  def note_block_row(assigns) do
    ~H"""
    <div
      class="note-block"
      id={"note-block-" <> @block.id}
      data-type={@block.type}
      data-secure={to_string(@block.secure?)}
      data-checked={to_string(@block.checked)}
    >
      <div class="note-block-gutter" aria-hidden="true">{glyph(@block.type)}</div>

      <div class="note-block-body">
        <%= if @editable do %>
          <form id={"note-form-" <> @block.id} phx-change="block_text">
            <input type="hidden" name="block_id" value={@block.id} />
            <input type="hidden" name="block_revision" value={@block.revision} />
            <textarea
              id={"note-text-" <> @block.id}
              name="text"
              rows="1"
              phx-hook="NoteBlock"
              phx-debounce="400"
              data-block-id={@block.id}
              data-type={@block.type}
              data-editing={to_string(@editing)}
              data-secure={to_string(@block.secure?)}
              phx-focus="focus_block"
              phx-blur="blur_block"
              phx-value-id={@block.id}
              aria-label={"#{label(@block.type)} block"}
            >{@block.text}</textarea>
          </form>
        <% else %>
          <div class="note-block-text" id={"note-text-" <> @block.id} data-type={@block.type}>
            <%= if is_binary(@block.text) do %>
              {Samen.Web.Notes.Inline.render(@block.text)}
            <% else %>
              {@block.text}
            <% end %>
          </div>
        <% end %>

        <div :if={language(@block)} class="note-block-meta">language: {language(@block)}</div>
      </div>

      <div :if={@controls != []} class="note-block-controls">
        {render_slot(@controls)}
      </div>
    </div>
    """
  end

  attr :block_id, :string, required: true
  attr :types, :list, default: nil

  @doc """
  The server-rendered type palette (the `/` affordance), anchored to `block_id` — `"start"` /
  `"end"` anchor at the page edges, any other value anchors after that block.

  Every entry is a `BUTTON` carrying the bounded token from `types/0`, so an unknown token can
  only arrive from a crafted event, where the write seam refuses it (R11).
  """
  def note_palette(assigns) do
    # The attr's default is `nil` so the caller can pass a subset; the bounded vocabulary is what
    # fills it in here (`assign_new/3` would keep the explicit `nil` the attr default already set).
    assigns = assign(assigns, :types, assigns[:types] || types())

    ~H"""
    <div class="note-palette" id="note-palette" role="group" aria-label="Insert a block">
      <button
        :for={type <- @types}
        type="button"
        class="note-palette-item"
        phx-click="insert_block"
        phx-value-type={type}
        phx-value-after={@block_id}
        id={"note-palette-#{type}"}
      >
        <span class="note-palette-glyph" aria-hidden="true">{glyph(type)}</span>
        <span>{label(type)}</span>
      </button>
      <button type="button" class="note-palette-close" phx-click="close_palette">Close</button>
    </div>
    """
  end

  attr :block_id, :string, required: true

  @doc """
  The stale-write banner (R9's UX half): the block changed while this client was typing, so the
  write was REFUSED — never applied last-write-wins. The affordances re-read the current row
  (through `Reads`, plane-correct) or dismiss the banner.
  """
  def note_conflict_banner(assigns) do
    ~H"""
    <div class="note-conflict" id={"note-conflict-" <> @block_id} role="alert">
      <span>This block changed while you were typing — your edit was not applied.</span>
      <button type="button" phx-click="reload_block" phx-value-id={@block_id}>Load the current text</button>
      <button type="button" phx-click="dismiss_conflict">Dismiss</button>
    </div>
    """
  end

  @doc "The empty page state — a zero-block page offers the palette instead of a blank pane."
  def note_empty_state(assigns) do
    ~H"""
    <div class="note-empty" id="note-empty">
      <p class="note-empty-title">This page is empty.</p>
      <p class="note-empty-body">
        Add a text block to start writing. Inline formatting is a small closed dialect
        (<code>**bold**</code>, <code>`code`</code>, <code>[[Page]]</code>) — stored text is never HTML.
      </p>
      <button type="button" id="note-empty-add" phx-click="open_palette" phx-value-id="start">
        Add your first block
      </button>
    </div>
    """
  end

  # Only a `code` block carries a language token (BlockShape refuses it elsewhere).
  defp language(%{type: :code, metadata: %{"language" => language}}) when is_binary(language),
    do: language

  defp language(_), do: nil
end
