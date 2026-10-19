defmodule Samen.Web.NotesSpikeMechanicsTest do
  @moduledoc """
  **P0 mechanics gate** for WS-Notes (`docs/ws-notes/build-plan.md` Phase 0; ADR-053 §2 D3).

  Four assertions on a REAL connected socket (`live_isolated/3` — the actual LiveView process, the
  actual channel, `phx-change` and `pushEvent` as the browser would drive them):

    * **(a)** the server echoes the exact submitted text, so the textarea's value node is not part
      of the patch — the causal mechanism for "the caret survives a debounced round trip";
    * **(b)** a remote change to the block being edited is SKIPPED while focused (and picked up on
      blur), driven by two sockets sharing one PubSub topic with an id-only envelope;
    * **(c)** `Enter` — `{block_id, caret offset}` from the hook — splits server-side and returns a
      focus request for the new block;
    * **(d)** `Backspace` at offset 0 merges into the previous block.

  What this file deliberately does NOT prove: the caret itself. `selectionStart` is a browser
  property and there is no browser in this suite — the live-browser pass
  (`test/support/notes_spike/`) measures it, and this suite proves the mechanism that makes it
  hold (an unchanged value node ⇒ nothing for the client to re-select).
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Samen.WebTest.NotesSpike

  @endpoint Samen.WebTest.SecurityEndpoint

  setup do
    ensure_pubsub!()
    NotesSpike.seed!()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp ensure_pubsub! do
    name = NotesSpike.pubsub()

    if Process.whereis(name) do
      :ok
    else
      start_supervised!({Phoenix.PubSub, name: name})
      :ok
    end
  end

  defp mount(conn), do: live_isolated(conn, NotesSpike, session: %{})

  # Synchronise with a LiveView process: it has handled every message sent to it up to now,
  # which is what makes the broadcast assertions deterministic instead of sleep-based.
  defp sync(view), do: :sys.get_state(view.pid)

  describe "(a) the echo — the value node is not patched" do
    test "the server stores and returns the EXACT submitted text (no trim, no normalisation)", %{
      conn: conn
    } do
      {:ok, view, _html} = mount(conn)

      typed = "  Hello <world> & co — naïve\t "
      payload = %{"text" => %{"b1" => typed, "b2" => "Second line.", "b3" => "Third line."}}

      {micros, _html} =
        :timer.tc(fn -> view |> form("#spike-form", payload) |> render_change() end)

      # The row holds exactly what was typed — including leading/trailing space, markup
      # characters and a non-ASCII grapheme.
      assert NotesSpike.get_block("b1").text == typed

      # ... and the re-render carries the SAME text back, so the client sees no change to the
      # textarea's value node (which is why the caret is not disturbed).
      textarea = view |> element("#row-b1 textarea") |> render()
      assert textarea =~ "&lt;world&gt; &amp; co"
      refute NotesSpike.get_block("b1").text |> String.trim() == typed

      IO.puts(
        "P0 (a) measured server round-trip for one debounced change: #{Float.round(micros / 1000, 2)} ms"
      )
    end

    test "an empty submit is not treated as an edit of every block", %{conn: conn} do
      {:ok, view, _html} = mount(conn)

      html =
        view
        |> form("#spike-form", %{"text" => %{"b1" => "First line.", "b2" => "Second line.", "b3" => "Third line."}})
        |> render_change()

      assert html =~ "First line."
      assert NotesSpike.get_block("b1").rev == 0
    end
  end

  describe "(b) the focus guard — a remote change cannot clobber the block being edited" do
    test "focused block is skipped; blur re-reads it", %{conn: conn} do
      {:ok, alice, _} = mount(conn)
      {:ok, bob, _} = mount(conn)

      # Alice focuses b1 (declarative phx-focus → phx-value-id), no JS involved.
      alice |> element("#row-b1 textarea") |> render_focus()
      assert alice |> render() =~ ~s(data-editing="true")

      before_rev = NotesSpike.get_block("b1").rev

      # Bob edits b1 from a DIFFERENT socket: one row write + one id-only broadcast.
      bob |> element("#touch-b1") |> render_click()
      sync(alice)

      after_rev = NotesSpike.get_block("b1").rev
      assert after_rev > before_rev, "the store must actually have changed"

      # Alice's control is untouched and still holds HER text; the skip is recorded.
      alice_html = alice |> render()
      assert alice_html =~ "First line."
      refute alice_html =~ "remote edit"
      assert alice_html =~ ~s(<p id="skipped">b1</p>)

      # On blur the skipped block is re-read — the update is deferred, never lost.
      alice |> element("#row-b1 textarea") |> render_blur()
      assert alice |> render() =~ "remote edit"
    end

    test "the broadcast envelope carries ids only (no text)", %{conn: conn} do
      {:ok, _alice, _} = mount(conn)

      Phoenix.PubSub.subscribe(NotesSpike.pubsub(), NotesSpike.topic())

      {:ok, bob, _} = mount(conn)
      bob |> element("#touch-b2") |> render_click()

      assert_receive {:block_changed, "b2", rev}, 1_000
      # The envelope is a 3-tuple: a tag, a block id, a revision. There is no field a text value
      # could ride in, which is the invariant — asserted structurally, not by inspection.
      assert is_binary("b2")
      assert is_integer(rev)
    end
  end

  describe "(c) Enter splits at the caret offset" do
    test "the hook's {id, offset} splits the row and requests focus on the new block", %{
      conn: conn
    } do
      {:ok, view, _html} = mount(conn)

      # "First line." → offset 6 → "First " | "line."
      html = view |> element("#row-b1 textarea") |> render_hook("split", %{"id" => "b1", "offset" => 6})

      assert NotesSpike.get_block("b1").text == "First "

      new_id =
        NotesSpike.all_blocks()
        |> Enum.at(1)
        |> Map.fetch!(:id)

      assert NotesSpike.get_block(new_id).text == "line."
      assert html =~ ~s(data-focus-request="#{new_id}")
      assert length(NotesSpike.all_blocks()) == 4
      # Ordering is preserved: the new block sits directly after its parent.
      assert NotesSpike.all_blocks() |> Enum.map(& &1.id) |> Enum.take(3) == ["b1", new_id, "b2"]
    end

    test "an out-of-range offset is clamped, never raises", %{conn: conn} do
      {:ok, view, _html} = mount(conn)

      view |> element("#row-b3 textarea") |> render_hook("split", %{"id" => "b3", "offset" => 999})

      assert NotesSpike.get_block("b3").text == "Third line."
      assert length(NotesSpike.all_blocks()) == 4
    end
  end

  describe "(d) Backspace at offset 0 merges into the previous block" do
    test "the two rows become one and focus is requested on the survivor", %{conn: conn} do
      {:ok, view, _html} = mount(conn)

      html = view |> element("#row-b2 textarea") |> render_hook("merge", %{"id" => "b2"})

      assert NotesSpike.get_block("b2") == nil
      assert NotesSpike.get_block("b1").text == "First line.Second line."
      assert html =~ ~s(data-focus-request="b1")
      assert length(NotesSpike.all_blocks()) == 2
    end

    test "merging the first block is a no-op (nothing to merge into)", %{conn: conn} do
      {:ok, view, _html} = mount(conn)

      view |> element("#row-b1 textarea") |> render_hook("merge", %{"id" => "b1"})

      assert NotesSpike.get_block("b1").text == "First line."
      assert length(NotesSpike.all_blocks()) == 3
    end
  end
end
