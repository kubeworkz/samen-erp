defmodule Samen.Web.ErpDashboardTest do
  @moduledoc """
  The ERP landing dashboard (`/erp`): the hosted-OCR budget is visible before
  an operator reaches the capture uploader, and every state is honest —
  available, exhausted, unreadable, and no adapter configured.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.DashboardLive
  alias Samen.Web.Erp.OcrQuota
  alias Samen.WebTest.RateLimitFlood
  alias Samen.WebTest.Repo

  @org "55555555-6666-7777-8888-999999999999"

  defp open(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = DashboardLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} = DashboardLive.handle_params(params, "http://localhost/erp", socket)

    socket
  end

  defp open_connected(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    mount = %{mount | labels: Map.put(mount.labels || %{}, :pubsub, Samen.WebTest.PubSub)}
    session = mount_session(mount)

    {:ok, socket} =
      DashboardLive.mount(params, session, %Phoenix.LiveView.Socket{transport_pid: self()})

    {:noreply, socket} = DashboardLive.handle_params(params, "http://localhost/erp", socket)

    socket
  end

  defp render(socket), do: render_html(DashboardLive, socket.assigns)

  defp configure_ocr do
    previous = Application.get_env(:samen_core, :invoice_ocr)
    Application.put_env(:samen_core, :invoice_ocr, Samen.WebTest.FakeOcrAdapter)
    on_exit(fn -> restore_invoice_ocr(previous) end)
  end

  test "renders at the ERP root inside the shell with the dashboard item active" do
    html = render(open())

    assert html =~ ~s(id="erp-dashboard")
    assert html =~ ~s(href="/erp?org=#{@org}" class="on")
    assert html =~ ~s(href="/erp/ap-capture?org=#{@org}")
    assert html =~ ~s(id="erp-dashboard-links")
    assert html =~ ~s(href="/erp/ap_invoices?org=#{@org}")
  end

  test "shows the org's remaining OCR budget" do
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {3, 3_600_000}})

    assert :ok = OcrQuota.check(@org, repo: Repo)

    html = render(open())

    assert html =~ ~s(id="erp-ocr-budget")
    assert html =~ "2 of 3 documents left"
    assert html =~ ~s(id="erp-ocr-reset")
    assert html =~ "Resets in "
    assert html =~ ~s(href="/erp/ap-capture?org=#{@org}")
  end

  test "another session's consumption refreshes the budget without a reload" do
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {2, 3_600_000}})

    socket = open_connected()
    assert render(socket) =~ "2 of 2 documents left"

    # Another session charges one document through the same seam capture uses.
    assert :ok = OcrQuota.check(@org, repo: Repo, pubsub: Samen.WebTest.PubSub)
    assert_receive {:ocr_quota_changed, @org}
    {:noreply, socket} = DashboardLive.handle_info({:ocr_quota_changed, @org}, socket)
    assert render(socket) =~ "1 of 2 documents left"

    # The last slot: the card flips to exhausted without a reload.
    assert :ok = OcrQuota.check(@org, repo: Repo, pubsub: Samen.WebTest.PubSub)
    assert_receive {:ocr_quota_changed, @org}
    {:noreply, socket} = DashboardLive.handle_info({:ocr_quota_changed, @org}, socket)

    html = render(socket)
    assert html =~ ~s(id="erp-ocr-exhausted")
    assert html =~ "Hosted OCR is paused"
  end

  test "re-reads the budget when the quota window rolls over" do
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {2, 3_600_000}})

    assert :ok = OcrQuota.check(@org, repo: Repo)
    assert :ok = OcrQuota.check(@org, repo: Repo)

    socket = open_connected()
    assert render(socket) =~ "Hosted OCR is paused"
    assert is_reference(socket.assigns.ocr_window_timer)
    remaining = Process.read_timer(socket.assigns.ocr_window_timer)
    assert is_integer(remaining) and remaining <= 60_000

    # The boundary passed: the row that exhausted the old window is no longer
    # the current one, so the same org has a full budget again.
    Repo.query!(
      "UPDATE web_ocr_quota SET window_start_ms = window_start_ms - $1::bigint WHERE org_id = $2::text::uuid",
      [3_600_000, @org]
    )

    {:noreply, socket} = DashboardLive.handle_info(:ocr_quota_refresh, socket)

    html = render(socket)
    assert html =~ ~s(id="erp-ocr-budget")
    assert html =~ "2 of 2 documents left"
    assert html =~ ~s(id="erp-ocr-reset")
    assert is_reference(socket.assigns.ocr_window_timer)
  end

  test "a charge for another org is ignored" do
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {3, 3_600_000}})

    socket = open_connected()
    {:noreply, unchanged} = DashboardLive.handle_info({:ocr_quota_changed, "other-org"}, socket)

    assert unchanged.assigns.ocr_budget == socket.assigns.ocr_budget
  end

  test "names exhaustion before an upload is attempted" do
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {2, 3_600_000}})

    assert :ok = OcrQuota.check(@org, repo: Repo)
    assert :ok = OcrQuota.check(@org, repo: Repo)

    html = render(open())

    assert html =~ ~s(id="erp-ocr-exhausted")
    assert html =~ "Hosted OCR is paused"
    assert html =~ ~s(id="erp-ocr-reset")
    assert html =~ "Resets in "
    refute html =~ ~s(id="erp-ocr-budget")
  end

  test "an unreadable counter is reported honestly" do
    configure_ocr()
    Repo.query!("DROP TABLE web_ocr_quota")

    html = render(open())

    assert html =~ ~s(id="erp-ocr-unavailable")
    refute html =~ ~s(id="erp-ocr-budget")
    refute html =~ ~s(id="erp-ocr-reset")
  end

  test "a host with no adapter says so instead of implying a budget" do
    html = render(open())

    assert html =~ ~s(id="erp-ocr-not-configured")
    refute html =~ ~s(id="erp-ocr-budget")
    refute html =~ ~s(id="erp-ocr-reset")
  end

  defp restore_invoice_ocr(nil), do: Application.delete_env(:samen_core, :invoice_ocr)
  defp restore_invoice_ocr(module), do: Application.put_env(:samen_core, :invoice_ocr, module)
end
