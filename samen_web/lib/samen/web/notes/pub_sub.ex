defmodule Samen.Web.Notes.PubSub do
  @moduledoc """
  The realtime transport for WS-Notes (ADR-053 §2 D4; WS-Notes Phase 5 unit 5.1) — one
  `Phoenix.PubSub` topic PER PAGE, with an **id-only** broadcast envelope so block text NEVER
  transits PubSub.

  ## The topic

  `"samen:notes:page:<page_id>"`. Every session viewing a page subscribes to its topic; a write
  broadcasts to it; each subscriber's `handle_info` re-reads the named block through
  `Samen.Web.Notes.Reads` with ITS OWN scope, so the text resolves per the RECEIVING viewer's
  plane (ADR-053 §2 D5). This is the chat shape (ADR-012 §3.1) applied to a page: masking survives
  the realtime path by construction, because the broadcast carries ids and revisions and nothing
  else. A masked operator session cannot receive plaintext even by listening on the topic.

  ## The two envelopes (R8)

      {:block_changed, %{block_id: id, revision: revision}}
      {:page_structure_changed, %{doc_id: id, revision: revision}}

  That key set is the whole contract, and it is asserted (`Map.keys/1` plus a byte scan of the
  serialized envelope) rather than described: a vaulted block's plaintext is present on the
  struct handed to `block_envelope/1` — the write that produced it resolved it on the writer's
  plane — so "just include the text to save a read" is a one-line change that WOULD leak. Sabotage
  **358** makes exactly that change and the byte-scan test fails.

  ## The pubsub server

  The server name is a HOST fact, read from the mount's `:pubsub` label (default
  `Driftwood.PubSub` — the running server in the reference vertical; any host overrides via the
  label, exactly as `Samen.Web.Chat.PubSub` and `Samen.Web.Notifications.PubSub` do). A host
  mounting `samen_notes_routes/3` on a different bus passes
  `labels: %{pubsub: MyApp.PubSub}`.

  Every call here is BEST-EFFORT and returns `:ok | {:error, term}`: a dead-rendered socket, or a
  test/seed without a PubSub server, must still render and still WRITE. A failed broadcast never
  loses data — the write is already committed, and the next read sees it.
  """

  alias Samen.Web.Mount

  @doc "The PubSub topic for a page id."
  @spec topic(String.t()) :: String.t()
  def topic(page_id) when is_binary(page_id), do: "samen:notes:page:" <> page_id

  @doc "The pubsub server name for a mount (`:pubsub` label; default `Driftwood.PubSub`)."
  @spec server(Mount.t()) :: atom()
  def server(%Mount{} = mount), do: Mount.label(mount, :pubsub, Driftwood.PubSub)

  @doc """
  Subscribe the calling process to a page's topic. Called from the editor's `mount`/`handle_params`
  on the CONNECTED socket only; a `{:error, _}` (no PubSub server) is tolerated by the caller —
  the page still renders and writes, realtime just does not deliver until a live server is there.
  """
  @spec subscribe(Mount.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(%Mount{} = mount, page_id) when is_binary(page_id) do
    Phoenix.PubSub.subscribe(server(mount), topic(page_id))
  rescue
    e -> {:error, e}
  end

  @doc "Unsubscribe the calling process (the editor's `terminate/2`)."
  @spec unsubscribe(Mount.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(%Mount{} = mount, page_id) when is_binary(page_id) do
    Phoenix.PubSub.unsubscribe(server(mount), topic(page_id))
  rescue
    e -> {:error, e}
  end

  # ── the envelopes (the ONE place an id-only payload is built) ──────────────

  @doc """
  The **id-only** envelope for one changed block (R8): the block id and its new revision.

  Its input is the record a write just returned — deliberately, so the call site has nothing to
  decide — and its OUTPUT carries no text whether or not the record has any. A vaulted block's
  `text_secure` is plaintext on that struct (the writer's plane resolved it), which is exactly why
  the builder must not pass it through.
  """
  @spec block_envelope(map()) :: {:block_changed, map()}
  def block_envelope(block) when is_map(block) do
    {:block_changed,
     %{
       block_id: id_of(block, :id),
       revision: Map.get(block, :revision)
     }}
  end

  @doc """
  The **id-only** envelope for a page-structure change (a split/merge/insert/move/archive bumped
  the page revision): the page id and the page's new revision. A subscriber re-reads the page.
  """
  @spec structure_envelope(term(), integer() | nil) :: {:page_structure_changed, map()}
  def structure_envelope(doc_id, revision) do
    {:page_structure_changed, %{doc_id: doc_id, revision: revision}}
  end

  # ── broadcasting ───────────────────────────────────────────────────────────

  @doc """
  Broadcast one block's id-only change envelope on its page's topic.

  Returns `:ok` (or `{:error, _}` when no PubSub server is running — the write is already
  committed, so a broadcast failure never loses data).
  """
  @spec broadcast_block_changed(Mount.t(), String.t(), map()) :: :ok | {:error, term()}
  def broadcast_block_changed(%Mount{} = mount, page_id, block) do
    broadcast(mount, page_id, block_envelope(block))
  end

  @doc "Broadcast one page's id-only structure envelope on its topic."
  @spec broadcast_page_structure_changed(Mount.t(), String.t(), term(), integer() | nil) ::
          :ok | {:error, term()}
  def broadcast_page_structure_changed(%Mount{} = mount, page_id, doc_id, revision) do
    broadcast(mount, page_id, structure_envelope(doc_id, revision))
  end

  @doc """
  Send a pre-built envelope on a page's topic. Exposed so a host or a kernel job can publish the
  same two shapes without re-implementing the topic; it is not a general-purpose bus — the
  envelopes above are the closed set `PageLive` understands.
  """
  @spec broadcast(Mount.t(), String.t(), tuple()) :: :ok | {:error, term()}
  def broadcast(%Mount{} = mount, page_id, envelope) when is_binary(page_id) do
    Phoenix.PubSub.broadcast(server(mount), topic(page_id), envelope)
  rescue
    e -> {:error, e}
  end

  # A block may arrive as an Ash struct or as the plain map `Reads` projects; both carry `:id`.
  defp id_of(record, key) do
    case Map.get(record, key) do
      nil -> nil
      id -> to_string(id)
    end
  end
end
