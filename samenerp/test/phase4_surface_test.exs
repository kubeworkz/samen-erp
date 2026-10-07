defmodule Samenerp.Phase4WebhookStub do
  @moduledoc """
  Test-local provider adapter for the Phase-4 ingress proof: verifies an
  HMAC-SHA256 over the RAW request bytes with a shared test secret. This is the
  load-bearing detail — if the endpoint's `Samen.Web.Webhook.RawBodyReader`
  (or the pipeline wiring) ever stops delivering the exact signed bytes, even a
  correctly-signed delivery fails verification and the accepted-delivery proof
  flips. Returns a plain map event: the ingress only reads
  `event_id`/`kind`/`occurred_at`/`payload`, and `domain_of/1` falls to the
  honest `"unknown"` domain for non-Samen structs.
  """

  def verify_and_parse_event(raw, headers, %{secret: secret}) do
    sig = Enum.find_value(headers, fn {k, v} -> if k == "x-acme-signature", do: v end)
    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

    if sig == expected do
      {:ok,
       %{
         event_id: "evt_phase4_001",
         kind: "test.event",
         occurred_at: DateTime.utc_now(),
         payload: %{"note" => "phase4 proof"}
       }}
    else
      {:error, :bad_signature}
    end
  end
end

defmodule Samenerp.Phase4SurfaceTest do
  @moduledoc """
  Phase-4 host surface proofs — Integrations (feature flags + shared webhook
  ingress), driven through the REAL router (the `Samenerp.Phase1/2/3SurfaceTest`
  discipline):

    * `GET /flags` — the `samen_flags_routes(:flags, Samenerp.Primitives, …)`
      one-liner surfaces the framework flag admin (200 + the honest
      "No feature flags yet." empty state), and a SEEDED `eff_feature_flag` row
      renders by name (org-scoped read through the mount).
    * `POST /webhooks/stripe` with NO host provider config — the honest
      fail-closed 404 `unknown_provider` from the ingress lifecycle. This test
      doubles as the CSRF-posture proof: a 403 here would mean
      `protect_from_forgery` leaked into the dedicated `:webhook_ingress`
      pipeline and every real vendor delivery would be rejected.
    * `POST /webhooks/acme` with a TEST-LOCAL provider config — the full
      ADR-038 §5.2 lifecycle through the real endpoint: a correctly HMAC-signed
      body verifies and persists (`whk_event` row, `status: received`), the SAME
      delivery again answers 200 `duplicate` (the `{provider, event_id}` unique
      index is the replay arbiter — row count stays 1), and a forged signature
      answers 400 `invalid_signature` with NOTHING persisted. The signature
      covers the raw bytes, so this also proves the endpoint's RawBodyReader
      wiring delivers the exact signed bytes end-to-end.

  Non-PII throughout: flag attributes are NON-PII by blueprint (ADR-020
  NonPiiTargeting), the webhook envelope payload carries only the stub's
  non-PII note, and no provider secrets exist in the repo (the production
  provider map lives in runtime config only).
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Operator, as: Op
  alias Samenerp.Primitives.FeatureFlag

  @endpoint SamenerpWeb.Endpoint

  @webhook_secret "phase4-shared-test-secret"

  setup do
    start_supervised!(SamenerpWeb.Endpoint)

    # Each test may set its own ingress config; restore whatever the suite had.
    prev = Application.get_env(:samen_web, Samen.Web.Webhook)

    on_exit(fn ->
      if prev do
        Application.put_env(:samen_web, Samen.Web.Webhook, prev)
      else
        Application.delete_env(:samen_web, Samen.Web.Webhook)
      end
    end)

    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp sign(raw) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @webhook_secret, raw), case: :lower)
  end

  defp signed_post(raw, sig) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-acme-signature", sig)
    |> post("/webhooks/acme", raw)
  end

  defp event_count do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        Samenerp.Repo,
        "SELECT count(*) FROM whk_event WHERE whk_provider = 'acme'",
        []
      )

    n
  end

  # ==========================================================================
  # Feature flags
  # ==========================================================================

  test "the flag admin renders with its honest empty state" do
    tenant = create_org!("Phase4 Flags QA")

    conn = get(build_conn(), "/flags?org=#{tenant.id}")

    assert conn.status == 200,
           "the /flags page did not render (status=#{conn.status}) — the samen_flags_routes mount is missing or crashing"

    body = conn.resp_body
    assert body =~ ~s(id="flags-settings"), "the flag admin surface did not render"
    assert body =~ "Feature flags", "the flag admin heading did not render"
    assert body =~ "No feature flags yet.", "the honest empty state did not render"
  end

  test "a seeded org flag renders by name through the mounted read" do
    tenant = create_org!("Phase4 Flags Seeded")

    FeatureFlag
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: tenant.id, name: "phase4_beta_console", enabled: true, rollout_pct: 25},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    conn = get(build_conn(), "/flags?org=#{tenant.id}")

    assert conn.status == 200
    assert conn.resp_body =~ "phase4_beta_console",
           "the seeded flag row did not render in the org's list"
    refute conn.resp_body =~ "No feature flags yet.",
           "the empty state must not render alongside a seeded row"
  end

  # ==========================================================================
  # Webhook ingress
  # ==========================================================================

  test "an unconfigured provider is refused fail-closed (and the route is CSRF-exempt by design)" do
    Application.delete_env(:samen_web, Samen.Web.Webhook)

    conn = post(build_conn(), "/webhooks/stripe", %{})

    assert conn.status == 404,
           "expected the honest fail-closed 404 (status=#{conn.status} body=#{inspect(conn.resp_body)}) — " <>
             "a 403 means protect_from_forgery leaked into the :webhook_ingress pipeline and every real vendor delivery would be rejected"

    assert conn.resp_body == "unknown_provider",
           "the unconfigured-provider posture must be the explicit unknown_provider refusal"
  end

  test "a signed delivery verifies + persists, a replay dedupes, a forgery persists nothing" do
    Application.put_env(:samen_web, Samen.Web.Webhook,
      providers: %{"acme" => {Samenerp.Phase4WebhookStub, %{secret: @webhook_secret}}},
      repo: Samenerp.Repo
    )

    raw = Jason.encode!(%{"id" => "evt_phase4_001", "data" => %{"x" => 1}})

    # 1. Forged signature → 400 BEFORE any write (the pre-crypto/verify gate).
    forged = signed_post(raw, sign(raw <> "tamper"))

    assert forged.status == 400,
           "a forged delivery must be refused (status=#{forged.status} body=#{inspect(forged.resp_body)})"

    assert forged.resp_body == "invalid_signature"
    assert event_count() == 0, "a forged delivery must persist NOTHING"

    # 2. Correct signature → verified + persisted (raw bytes intact end-to-end).
    accepted = signed_post(raw, sign(raw))

    assert accepted.status == 200,
           "a correctly signed delivery must be accepted (status=#{accepted.status} body=#{inspect(accepted.resp_body)})"

    assert accepted.resp_body == "ok"
    assert event_count() == 1, "the verified envelope must be persisted exactly once"

    # 3. Same delivery again → 200 duplicate, row count unchanged (replay
    #    protection arbitrated by the {provider, event_id} unique index).
    replay = signed_post(raw, sign(raw))

    assert replay.status == 200
    assert replay.resp_body == "duplicate", "a replay must answer the honest duplicate no-op"
    assert event_count() == 1, "a replay must not create a second envelope"
  end
end
