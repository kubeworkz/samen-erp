defmodule Samen.WebTest.NotesSpike do
  @moduledoc """
  **THROWAWAY P0 mechanics spike** for WS-Notes (`docs/ws-notes/build-plan.md` Phase 0;
  ADR-053 §2 D3). Not a product surface, not mounted by any host router, and deliberately ugly —
  its whole job is to answer four questions on a real connected socket BEFORE any model code is
  written:

    1. does the server echo the exact submitted text (so the textarea's value node never changes
       in the patch, which is the causal mechanism for "the caret survives a debounced round
       trip")?
    2. does a remote change to the block being edited get SKIPPED while it is focused, and picked
       up on blur?
    3. does `Enter` split server-side at a client-supplied caret offset, and does the client get a
       focus request for the new block?
    4. does `Backspace` at offset 0 merge into the previous block?

  ## Shape (the parts that are meant to survive into the real build)

    * one `<textarea>` per block, `phx-change` on the enclosing form + `phx-debounce="400"`;
    * focus tracking is **declarative** (`phx-focus`/`phx-blur` + `phx-value-id`) — the hook does
      NOT need to report focus, which removes two messages per keystroke-burst from the contract;
    * the only client→server intents that carry an OFFSET are `split` and `merge`, and they arrive
      via `pushEvent` from the `NoteBlock` hook (`render_hook/3` in the test) because the caret
      position exists nowhere but the browser;
    * the realtime envelope is **id-only** (`{:block_changed, id, rev}`) and every subscriber
      re-reads from the store on its own — the chat precedent (ADR-012 §3.1).

  `Store` is an ETS table standing in for the database. It is process-independent on purpose: the
  two sockets in the test, and the browser tabs in the live run, must observe the same rows.
  """

  use Phoenix.LiveView

  @table :notes_spike_blocks
  @default_pubsub Samen.WebTest.NotesSpike.PubSub

  # ── store (stand-in for the future DocBlock table) ─────────────────────────

  @doc "The PubSub name the spike subscribes/broadcasts on (overridable in config)."
  def pubsub, do: Application.get_env(:samen_web, :notes_spike_pubsub, @default_pubsub)

  @doc "The single topic every spike socket joins."
  def topic, do: "notes_spike"

  @doc "Create the ETS table if this VM has not yet (idempotent)."
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      _tid -> @table
    end
  end

  @doc "Seed three paragraphs. Resets any previous rows (the spike has no isolation)."
  def seed!(blocks \\ [{"b1", "First line."}, {"b2", "Second line."}, {"b3", "Third line."}]) do
    ensure_table!()
    :ets.delete_all_objects(@table)

    blocks
    |> Enum.with_index(1)
    |> Enum.each(fn {{id, text}, pos} ->
      :ets.insert(@table, {id, pos, "paragraph", text, 0})
    end)

    :ok
  end

  @doc "Every block in `position` order."
  def all_blocks do
    ensure_table!()

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_id, pos, _type, _text, _rev} -> pos end)
    |> Enum.map(fn {id, pos, type, text, rev} ->
      %{id: id, pos: pos, type: type, text: text, rev: rev}
    end)
  end

  @doc "One block, or `nil`."
  def get_block(id) do
    ensure_table!()

    case :ets.lookup(@table, id) do
      [{^id, pos, type, text, rev}] -> %{id: id, pos: pos, type: type, text: text, rev: rev}
      [] -> nil
    end
  end

  # ── LiveView ───────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    ensure_table!()
    if connected?(socket), do: subscribe()

    {:ok,
     assign(socket,
       blocks: all_blocks(),
       editing_block_id: nil,
       skipped: [],
       conflict: nil,
       focus_request: nil
     )}
  end

  @impl true
  def handle_event("block_text", %{"text" => params}, socket) do
    case changed_block(params, socket.assigns.blocks) do
      nil ->
        {:noreply, socket}

      {id, text} ->
        put_text!(id, text)
        # NOTE: the re-read returns exactly what was written — no trimming, no normalisation.
        {:noreply, assign(socket, blocks: all_blocks(), conflict: nil)}
    end
  end

  def handle_event("focus_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_block_id: id)}
  end

  def handle_event("blur_block", %{"id" => _id}, socket) do
    # On blur the skipped block is re-read — the second half of assertion (b).
    {:noreply, assign(socket, blocks: all_blocks(), editing_block_id: nil)}
  end

  # An EXTERNAL edit: write the row, then broadcast ids only (never the text), like a second
  # user's socket would.
  def handle_event("touch", %{"id" => id}, socket) do
    rev = put_text!(id, "remote edit #{System.unique_integer([:positive])}")
    _ = Phoenix.PubSub.broadcast(pubsub(), topic(), {:block_changed, id, rev})
    {:noreply, assign(socket, blocks: all_blocks())}
  end

  # The hook's `Enter`: {block_id, caret offset} → split in two, focus the new block.
  def handle_event("split", %{"id" => id, "offset" => offset}, socket) do
    block = get_block(id)

    if is_nil(block) do
      {:noreply, socket}
    else
      {left, right} = String.split_at(block.text, clamp_offset(offset, block.text))
      put_text!(id, left)
      new_id = "b#{System.unique_integer([:positive])}"
      insert_after!(id, new_id, right)

      {:noreply,
       socket
       |> assign(blocks: all_blocks(), focus_request: new_id)
       # Focus is a CLIENT concern: the server can only nominate the block. This is the one
       # message the hook must handle beyond `pushEvent`.
       |> push_event("focus_block", %{id: new_id})}
    end
  end

  # The hook's `Backspace` at offset 0: append into the previous block, delete this one.
  def handle_event("merge", %{"id" => id}, socket) do
    blocks = all_blocks()

    case Enum.find_index(blocks, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      0 ->
        {:noreply, socket}

      idx ->
        prev = Enum.at(blocks, idx - 1)
        cur = Enum.at(blocks, idx)
        merged = prev.text <> cur.text

        blocks
        |> List.replace_at(idx - 1, %{prev | text: merged})
        |> List.delete_at(idx)
        |> rewrite!()

        {:noreply,
         socket
         |> assign(blocks: all_blocks(), focus_request: prev.id)
         |> push_event("focus_block", %{id: prev.id})}
    end
  end

  @impl true
  def handle_info({:block_changed, id, _rev}, socket) do
    if id == socket.assigns.editing_block_id do
      # THE GUARD: never patch the control the user is typing into.
      {:noreply, assign(socket, skipped: [id | socket.assigns.skipped])}
    else
      {:noreply, assign(socket, blocks: all_blocks())}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The whole document lives here (the spike route is `layout: false`) so the browser pass is a
  # single self-contained page: vendored Phoenix + LiveView JS, one hook file, no build step.
  @impl true
  def render(assigns) do
    ~H"""
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>WS-Notes P0 mechanics spike</title>
        <script defer src="/phoenix/phoenix.min.js"></script>
        <script defer src="/live_view/phoenix_live_view.min.js"></script>
        <script defer src="/spike/spike.js"></script>
        <style>
          body { font: 15px/1.5 system-ui, sans-serif; margin: 2rem; max-width: 46rem; }
          textarea { width: 100%; resize: none; font: inherit; padding: .4rem .5rem;
                     border: 1px solid #d6d3d1; border-radius: 6px; overflow: hidden; }
          textarea:focus { outline: 2px solid #6366f1; border-color: transparent; }
          .row { margin: 0 0 .4rem; }
          #controls { margin-top: 1rem; display: flex; gap: .4rem; flex-wrap: wrap; }
          #controls button { font: inherit; font-size: 12px; padding: .2rem .5rem; }
          #skipped, #focus-request { font: 12px/1.4 ui-monospace, monospace; color: #57534e; }
        </style>
      </head>
      <body>
    <div id="spike" data-editing={@editing_block_id || ""} data-focus-request={@focus_request || ""}>
      <form id="spike-form" phx-change="block_text">
        <div :for={b <- @blocks} id={"row-" <> b.id} class="row" data-block-id={b.id}>
          <textarea
            id={"text-" <> b.id}
            name={"text[#{b.id}]"}
            rows="1"
            phx-hook="NoteBlock"
            phx-debounce="400"
            data-block-id={b.id}
            data-rev={b.rev}
            data-editing={to_string(@editing_block_id == b.id)}
            phx-focus="focus_block"
            phx-blur="blur_block"
            phx-value-id={b.id}
            aria-label={"block " <> b.id}
          >{b.text}</textarea>
        </div>
      </form>

      <div id="controls">
        <button :for={b <- @blocks} type="button" id={"split-" <> b.id} phx-click="split" phx-value-id={b.id} phx-value-offset="6">split {b.id}</button>
        <button :for={b <- @blocks} type="button" id={"merge-" <> b.id} phx-click="merge" phx-value-id={b.id}>merge {b.id}</button>
        <button :for={b <- @blocks} type="button" id={"touch-" <> b.id} phx-click="touch" phx-value-id={b.id}>touch {b.id}</button>
      </div>

      <p id="skipped">{Enum.join(Enum.reverse(@skipped), ",")}</p>
      <p id="focus-request">{@focus_request || ""}</p>
    </div>
      </body>
    </html>
    """
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp subscribe do
    Phoenix.PubSub.subscribe(pubsub(), topic())
  rescue
    _ -> :ok
  end

  # The form posts EVERY textarea; the one whose value differs from the store is the edit.
  defp changed_block(params, blocks) do
    Enum.find_value(blocks, fn b ->
      text = Map.get(params, b.id)
      if text != nil and text != b.text, do: {b.id, text}
    end)
  end

  @doc false
  def put_text!(id, text) do
    rev =
      case get_block(id) do
        nil -> 0
        b -> b.rev + 1
      end

    pos =
      case get_block(id) do
        nil -> length(all_blocks()) + 1
        b -> b.pos
      end

    :ets.insert(@table, {id, pos, "paragraph", text, rev})
    rev
  end

  defp insert_after!(after_id, new_id, text) do
    blocks = all_blocks()

    {before, rest} = Enum.split_while(blocks, &(&1.id != after_id))
    # `split_while` EXCLUDES the anchor, so it has to be put back explicitly — dropping it was
    # the first bug this spike caught (the row vanished and the split "succeeded" into nothing).
    {anchor, tail} = List.pop_at(rest, 0)

    (before ++ [anchor, %{id: new_id, pos: 0, type: "paragraph", text: text, rev: 0}] ++ tail)
    |> rewrite!()
  end

  defp rewrite!(blocks) do
    ensure_table!()
    :ets.delete_all_objects(@table)

    blocks
    |> Enum.with_index(1)
    |> Enum.each(fn {b, pos} -> :ets.insert(@table, {b.id, pos, b.type, b.text, b.rev}) end)

    :ok
  end

  defp clamp_offset(offset, text) when is_binary(offset) do
    offset |> String.to_integer() |> clamp_offset(text)
  rescue
    _ -> 0
  end

  defp clamp_offset(offset, text) when is_integer(offset) do
    offset |> max(0) |> min(String.length(text))
  end
end
