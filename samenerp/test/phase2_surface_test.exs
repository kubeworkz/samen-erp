defmodule Samenerp.Phase2SurfaceTest do
  @moduledoc """
  Phase-2 host surface proofs — the Chat + Communication mount, driven through the
  REAL router (no mount constructed here; the `Samenerp.Phase1SurfaceTest` /
  `Samenerp.BankingSurfaceTest` discipline):

    * `GET /chat` — the `samen_chat_routes(:chat, Samenerp.Chat, …)` one-liner
      actually surfaces the framework thread console (200 + the honest
      "No conversations yet." empty state — never a fabricated row);
    * `GET /chat` + `GET /chat/:id` with a SEEDED thread — the list row carries the
      subject and the room renders the vault-routed message body IN THE CLEAR on the
      TENANT plane (green half of the masking pair; the operator-plane masked half
      is the framework's own chat masking proofs in samen_web — this proves the
      HOST's mount resolves PII through `Samen.Api.PiiResolution` on the right
      plane, not hand-masked copy);
    * `GET /chat/:id` for a missing thread — the honest "Conversation not
      available." posture, never a crash and never a fabricated conversation.

  PubSub/Presence are NOT started under test (`start_repo?: false` — the framework
  `PubSub.subscribe/2` tolerates their absence and the first dead render works
  either way), mirroring how driftwood exercises chat.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Chat.{ChatMessage, ChatParticipant, ChatThread}
  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  @subject "Phase-2 chat proof thread"
  @body_phrase "pickup window for load 9931"
  @handle "dispatch-kate"

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # The seed mirrors samen_web's `Seeds.seed_chat/2` create shapes (thread → tenant
  # participant → message): writes go through Ash so the vault routes the
  # participant `full_name` + message `body` on write — clear at rest never happens.
  defp seed_chat!(org_id) do
    thread =
      ChatThread
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          subject: @subject,
          kind: :cross_plane,
          status: :open,
          disclosure_mode: :masked
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    participant =
      ChatParticipant
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          thread_id: thread.id,
          party: :tenant,
          principal_kind: :user,
          handle: @handle,
          identity_shared: true,
          role: :owner,
          full_name: %Samen.Type.FullName{first: "Kate", last: "Reyes"}
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          thread_id: thread.id,
          participant_id: participant.id,
          sender_party: :tenant,
          kind: :message,
          body: "Please confirm the #{@body_phrase} before dispatch.",
          refs: []
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    %{thread: thread, participant: participant, message: message}
  end

  test "the chat console renders through the mounted route with its honest empty state" do
    tenant = create_org!("Phase2 Chat QA")

    conn = get(build_conn(), "/chat?org=#{tenant.id}")

    assert conn.status == 200,
           "the /chat page did not render — the samen_chat_routes mount is missing or crashing"

    body = conn.resp_body
    assert body =~ "No conversations yet.", "the threads empty state did not render"
    assert body =~ "Start conversation", "the new-conversation affordance (tenant plane) did not render"
  end

  test "a seeded thread lists by subject and its vault-routed body renders CLEAR on the tenant plane" do
    tenant = create_org!("Phase2 Chat Room")
    %{thread: thread} = seed_chat!(tenant.id)

    list = get(build_conn(), "/chat?org=#{tenant.id}")
    assert list.status == 200
    assert list.resp_body =~ @subject, "the seeded thread row did not render its subject in the list"

    room = get(build_conn(), "/chat/#{thread.id}?org=#{tenant.id}")
    assert room.status == 200,
           "the /chat/:id room did not render — the seeded conversation is unreachable"

    body = room.resp_body
    assert body =~ @subject, "the room must show the thread subject"

    # TENANT plane green proof: the vault-routed message body resolves in the clear
    # through PiiResolution on this plane (never a vt_* token, never a raw refusal).
    assert body =~ @body_phrase,
           "the vault-routed message body did not resolve CLEAR on the tenant plane"

    assert body =~ @handle, "the participant handle (the safe label) did not render"
    refute body =~ "vt_", "a raw vault token leaked into the chat room DOM"
  end

  test "a missing thread renders the honest not-available posture, never a crash" do
    tenant = create_org!("Phase2 Chat Missing")

    conn = get(build_conn(), "/chat/#{Ash.UUID.generate()}?org=#{tenant.id}")

    assert conn.status == 200,
           "a missing conversation must render honestly, not raise (NoRouteError/500)"

    assert conn.resp_body =~ "Conversation not available.",
           "the honest missing-conversation posture did not render"
  end
end
