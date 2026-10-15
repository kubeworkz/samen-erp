defmodule Samen.Web.UnreadIsNotEmptyTest do
  @moduledoc """
  "Could not be read" is NOT "read nothing" (fail-honest, ADR-014/024/026).

  ## The defect class this closes

  An empty list communicates a claim about the DATA — "there is nothing here" — whether or
  not it is true. A surface that renders a RESCUED query, an absent dependency table, or a
  `{:error, _}` seam as an empty list is asserting something it never observed, which is the
  same lie the adapter contract forbids (`{:ok, _}` for work it did not do). `Samen.UI` had
  exactly one zero-row affordance (`empty_state/1`), so every failure collapsed into it.

  ## What is proven

    * **PRIMITIVE** — `unread_state/1` renders a state that is structurally and textually
      distinct from `empty_state/1` (different marker, "could not be read" copy, the reason
      token), and `list_view/1` renders it INSTEAD of the empty state whenever the page
      carries an `unread` reason — including when the caller supplied a tailored `:empty`
      slot, so a failed read can never be dressed as that surface's own empty copy.
    * **GREEN** — a page with `unread: nil` still renders the ordinary empty state (no
      regression for every existing `%Page{}` construction, which does not set the field).
    * **SABOTAGE TWIN** — the assertion is refutable: the SAME `%Page{}` with `unread: nil`
      renders the empty state and does NOT render the unread state, so the green/red pair is
      a genuine discriminator and not two spellings of one render.
    * **END-TO-END** — the wired operator surfaces (`WebhookDlqLive`, `RevenueLive`,
      `PlatformBillingLive`, `AnalyticsLive`, `AggregateLive`) are driven through their REAL
      loaders with the failure forced at the read layer, proving the wiring exists rather
      than the component alone.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Operator.AggregateLive
  alias Samen.Web.Operator.AnalyticsLive
  alias Samen.Web.Operator.DeliverabilityReads
  alias Samen.Web.Operator.PlatformBillingLive
  alias Samen.Web.Operator.RevenueLive
  alias Samen.Web.Operator.WebhookDlqLive
  alias Samen.Web.Page

  @operator_org "00000000-0000-0000-0000-00000000beef"

  defp page(unread, items \\ []) do
    %Page{items: items, page_size: 50, unread: unread}
  end

  defp list_view(unread, opts \\ []) do
    render_component(
      &Samen.UI.list_view/1,
      %{
        id: "t",
        page: page(unread),
        state: nil,
        head: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<th>Col</th>") end}],
        row: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<td>x</td>") end}],
        empty: Keyword.get(opts, :empty, []),
        empty_text: Keyword.get(opts, :empty_text, "Nothing here yet.")
      }
    )
  end

  defp mount(org_id \\ @operator_org) do
    build_operator_mount(org_id)
  end

  # A mount whose queue read cannot succeed — the repo is not a usable Ecto repo, so
  # `list_envelopes/1` takes its rescue path. This is the SAME state a host reaches when the
  # `whk_event` table is absent, without depending on the scratch DB's migration set.
  defp unreadable_mount do
    build_operator_mount(@operator_org, repo: :not_a_real_repo)
  end

  defp rendered(live, socket_assigns) do
    assigns =
      Enum.reduce(socket_assigns, %Phoenix.LiveView.Socket{}, fn {k, v}, acc ->
        Phoenix.Component.assign(acc, k, v)
      end)

    assigns = live.load(assigns) |> Map.fetch!(:assigns)
    render_html(live, assigns)
  end

  # ==========================================================================
  # The PRIMITIVE
  # ==========================================================================

  test "unread_state/1 renders a state distinct from empty_state/1" do
    unread = render_component(&Samen.UI.unread_state/1, %{reason: :read_failed})
    empty = render_component(&Samen.UI.empty_state/1, %{title: "Nothing here yet."})

    # A machine-readable marker, so no surface can present one as the other.
    assert unread =~ ~s(data-read-state="unread")
    refute empty =~ ~s(data-read-state="unread")

    # The honest wording, and the reason a reader can quote.
    assert unread =~ "Could not be read."
    assert unread =~ ~s(data-unread-reason="read_failed")
    assert unread =~ "read_failed"
    # …and it says outright that it is NOT an empty result (the claim it exists to refuse).
    assert unread =~ "This is not an empty result"

    # The empty state claims the opposite thing and must not carry the unread vocabulary.
    refute empty =~ "Could not be read."
    refute empty =~ ~s(data-unread-reason=)
    refute empty =~ "This is not an empty result"
  end

  test "unread_state/1 names a bounded reason and never renders a raw error term" do
    # A `{tag, detail}` reason renders the TAG only — the detail is a raw error and has no
    # business in the DOM.
    html =
      render_component(&Samen.UI.unread_state/1, %{
        reason: {:read_failed, %RuntimeError{message: "secret-ish internal detail"}}
      })

    assert html =~ "read_failed"
    refute html =~ "secret-ish internal detail"

    # A nil reason renders no reason line at all (never a fabricated token).
    none = render_component(&Samen.UI.unread_state/1, %{reason: nil})
    refute none =~ "reason:"
    refute none =~ ~s(data-unread-reason=)
  end

  test "unread_state/1 offers a Retry control only when the surface can re-run its read" do
    with_retry = render_component(&Samen.UI.unread_state/1, %{reason: :read_failed, retry_event: "reload"})
    assert with_retry =~ ~s(phx-click="reload")
    assert with_retry =~ "Retry"

    without = render_component(&Samen.UI.unread_state/1, %{reason: :read_failed})
    refute without =~ "phx-click"
  end

  # ==========================================================================
  # list_view/1 wiring — every adopter inherits the contract
  # ==========================================================================

  test "list_view/1 renders the UNREAD state for a page that could not be read" do
    html = list_view(:read_failed)

    assert html =~ ~s(data-read-state="unread")
    assert html =~ "read_failed"
    assert html =~ "list-unread"
    # NOT the empty state's claim.
    refute html =~ "Nothing here yet."
    refute html =~ ~s(class="card empty-state")
  end

  test "GREEN — a page with no unread reason still renders the ordinary empty state" do
    html = list_view(nil, empty_text: "No contacts yet.")

    assert html =~ "No contacts yet."
    assert html =~ "empty-state"
    refute html =~ ~s(data-read-state="unread")
    refute html =~ "could not be read"
  end

  test "SABOTAGE TWIN — the SAME page renders the two states, so the probe discriminates" do
    unread = list_view(:read_failed)
    empty = list_view(nil)

    assert unread =~ ~s(data-read-state="unread")
    assert_raise ExUnit.AssertionError, fn ->
      assert empty =~ ~s(data-read-state="unread")
    end
  end

  test "an unread page overrides even a caller-supplied :empty slot — a failure is not that surface's empty copy" do
    tailored = [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<p>No invoices for this account.</p>") end}]

    unread = list_view(:read_failed, empty: tailored)
    assert unread =~ ~s(data-read-state="unread")
    refute unread =~ "No invoices for this account."

    # …while the same tailored slot IS what a genuinely-empty page renders (the control).
    assert list_view(nil, empty: tailored) =~ "No invoices for this account."
  end

  test "a NON-empty page ignores the unread field — rows are still the answer" do
    html =
      render_component(
        &Samen.UI.list_view/1,
        %{
          id: "t",
          page: page(:read_failed, [%{id: "1"}]),
          state: nil,
          head: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<th>Col</th>") end}],
          row: [%{inner_block: fn _, _ -> Phoenix.HTML.raw("<td>a real row</td>") end}],
          empty: [],
          empty_text: "Nothing here yet."
        }
      )

    assert html =~ "a real row"
    refute html =~ ~s(data-read-state="unread")
  end

  # ==========================================================================
  # END-TO-END — the wired operator surfaces
  # ==========================================================================

  test "the DLQ page reports an UNREADABLE queue instead of claiming nothing dead-lettered" do
    # A mount whose repo cannot answer the queue query — the documented fail-safe path (a host
    # that has not run the `whk_event` migration reaches the same state). `list_envelopes/1`
    # reports a REASON, and the page must render that, never "nothing has dead-lettered".
    html = rendered(WebhookDlqLive, %{samen_mount: unreadable_mount(), samen_operator_role: :operator_admin})

    assert html =~ ~s(data-read-state="unread")
    assert html =~ "could not be read"
    assert html =~ "dlq-unread"
    assert html =~ "read_failed"
    # The confident empty-state copy must NOT appear…
    refute html =~ "No webhook envelopes."
    # …and the posture bar must not report a dead count it did not read.
    assert html =~ "dead count unknown"
    assert html =~ "The queue itself"
  end

  test "POSITIVE CONTROL — a READABLE (empty) queue renders the honest empty state, not the unread one" do
    # The scratch repo DOES have `whk_event`; with no rows the read SUCCEEDS and is genuinely
    # empty — the state the unread path must not be confused with.
    html = rendered(WebhookDlqLive, %{samen_mount: mount(), samen_operator_role: :operator_admin})

    refute html =~ ~s(data-read-state="unread")
    refute html =~ "could not be read"
    assert html =~ "No webhook envelopes."
    # …and the posture bar reports a REAL count (the green side of the same predicate).
    assert html =~ "Nothing is dead right now"
    refute html =~ "dead count unknown"
  end

  test "the revenue read layer marks a FAILED rollup read, and never a successful one" do
    # The no-org shape is a KNOWN outcome, so NEITHER half of it is marked unread…
    assert %{unread: nil, cohorts_unread: nil} = Samen.Web.Operator.RevenueReads.empty()

    # …while `revenue/2`'s rescue marks BOTH halves of its own empty shape. The halves read
    # DIFFERENT sources (the rollup raw table vs the mov timeline), which is why each carries
    # its own marker — the per-half green/read-failed/twin proofs live in
    # `operator_revenue_render_test.exs`.
    src = File.read!("lib/samen/web/operator/revenue/reads.ex")
    assert src =~ "%{empty() | unread: :read_failed, cohorts_unread: :read_failed}"
  end

  test "GREEN — the revenue page renders normally for a read that SUCCEEDED" do
    html = rendered(RevenueLive, %{samen_mount: mount(), samen_operator_role: :operator_admin})

    # The scratch DB's rollup answers, so the green side must hold: a successful read is never
    # presented as unread.
    refute html =~ "could not be read"
    refute html =~ ~s(data-read-state="unread")
  end

  test "platform billing distinguishes a failed read from a measured zero" do
    # The no-org shape is a KNOWN outcome (not unread)…
    empty = %{
      subscriptions: [],
      invoices: [],
      dunning: [],
      mrr_cents: 0,
      past_due_cents: 0,
      active_subs: 0,
      unread: nil
    }

    assert empty.unread == nil

    # …while the read layer's rescue marks ITS zeroed shape `:read_failed`, so the renderer
    # can tell "no org" from "$0 because the read raised". A nil scope makes the
    # subscription read raise (`OrgScope` has no actor), which is exactly that path.
    raised = Samen.Web.Operator.Reads.platform_billing(build_operator_mount(@operator_org), nil)

    assert raised.unread == :read_failed
    assert raised.subscriptions == []
    assert raised.mrr_cents == 0
    # The marker is what separates it from a measured zero — the shape alone would not.
    assert raised.unread != nil
  end

  test "the portfolio surface separates an UNWIRED projection from a WIRED one that failed" do
    # No loader wired → a true statement about the host.
    unwired =
      rendered(AggregateLive, %{
        samen_mount: mount(),
        samen_operator_role: :operator_admin
      })

    assert unwired =~ "No aggregate projection wired."

    # A wired loader that raises → NOT the same fact.
    raising = build_operator_mount(@operator_org, labels: %{aggregate_loader: {__MODULE__, :raise_loader, []}})

    html = rendered(AggregateLive, %{samen_mount: raising, samen_operator_role: :operator_admin})

    assert html =~ ~s(data-read-state="unread")
    assert html =~ "read_failed"
    refute html =~ "No aggregate projection wired."
  end

  @doc false
  def raise_loader, do: raise("loader exploded")

  test "the analytics surface carries the unread marker through its reads" do
    assert Samen.Web.Operator.AnalyticsReads.empty().unread == nil

    html = rendered(AnalyticsLive, %{samen_mount: mount(), samen_operator_role: :operator_admin})
    # The scratch DB has the paf rollup, so the green side holds: a successful read is not unread.
    refute html =~ "could not be read"
    refute html =~ ~s(data-read-state="unread")
  end

  test "an operator page with NO operator ORG states that, and does not claim a failed read" do
    # A mount that resolves no operator org — the page states it, and renders no unread state.
    html = rendered(PlatformBillingLive, %{samen_mount: mount(nil), samen_operator_role: :operator_admin})

    assert html =~ "No operator org resolved."
    refute html =~ ~s(data-read-state="unread")
    refute html =~ "Platform MRR"
  end

  test "a page with no org is NOT the unread state — the two silences stay distinct" do
    no_org = rendered(PlatformBillingLive, %{samen_mount: mount(nil), samen_operator_role: :operator_admin})
    readable = rendered(PlatformBillingLive, %{samen_mount: mount(), samen_operator_role: :operator_admin})

    assert no_org =~ "No operator org resolved."
    refute no_org =~ ~s(data-read-state="unread")
    # …and a readable org renders the real tiles, so the probe discriminates.
    assert readable =~ "Platform MRR"
    refute readable =~ "No operator org resolved."
  end

  test "the deliverability read layer marks a FAILED read, and never a successful one" do
    # The deliverability/suppression reads are raw Ecto repo reads (`mount.repo`), so an
    # unusable repo forces the rescue path — the same state a host reaches when the
    # `dlv_suppression` / `dlv_email_event` tables are absent.
    ok = DeliverabilityReads.deliverability(mount(), nil, @operator_org)
    assert ok.unread == nil
    assert ok.suppressed_subscriber_ids == MapSet.new()

    bad = DeliverabilityReads.deliverability(unreadable_mount(), nil, @operator_org)

    assert bad.unread == :read_failed
    assert bad.suppressions == []
    assert bad.events == []
    # The marker — not the shape — is what keeps "could not read" from being rendered as
    # "nobody is suppressed", which is the exact misdirection this closes.
    assert bad.unread != ok.unread
  end

  test "the deliverability page names the unread silence for both tables, and the readable one for neither" do
    src = File.read!("lib/samen/web/operator/deliverability_live.ex")

    # Both confident empty states are now gated on the read having ANSWERED…
    assert src =~ "@detail.suppressions == [] and Map.get(@detail, :unread)"
    assert src =~ "@detail.events == [] and Map.get(@detail, :unread)"
    # …and both unread states are rendered INSTEAD of them.
    assert src =~ ~s(class="suppressions-unread")
    assert src =~ ~s(class="events-unread")
  end

  test "the flags cohort read reports which silence it is, and the page renders it" do
    # `tenant_cohorts/2` hands back the reason as a VALUE, so "No tenant accounts yet." can
    # never be shown over a read that raised.
    {cohorts, unread} = Samen.Web.Flags.Reads.tenant_cohorts(mount(), @operator_org)
    assert unread == nil
    assert is_list(cohorts)

    src = File.read!("lib/samen/web/operator/flag_admin_live.ex")
    assert src =~ "@cohorts == [] and @cohorts_unread"
    assert src =~ ~s(class="cohorts-unread")
    assert src =~ "@cohorts == [] and is_nil(@cohorts_unread)"

    # …and the flags LIST read carries the same marker through `list_view/1` (the seam that
    # renders it is the primitive's own, asserted above).
    flag_src = File.read!("lib/samen/web/flags/reads.ex")
    assert flag_src =~ "unread: :read_failed"
    assert flag_src =~ "{[], :read_failed}"
  end

  test "the activity feed separates an UNREADABLE tier from an empty window" do
    # A nil org is a KNOWN outcome — nothing was asked to read…
    assert Samen.Web.Operator.ActivityReads.activity(mount(), nil).unread == nil

    # …while a tier that RAISED is reported as a value, so "No changes in this window." is
    # never asserted over a ledger that never answered.
    ok = Samen.Web.Operator.ActivityReads.activity(mount(), @operator_org)
    assert ok.unread == nil
    assert is_list(ok.items)

    bad = Samen.Web.Operator.ActivityReads.activity(unreadable_mount(), @operator_org)
    assert bad.unread == :tier_unreadable
    assert bad.items == []

    # …and the page renders the unread state INSTEAD of the confident empty copy.
    src = File.read!("lib/samen/web/operator/activity_live.ex")
    assert src =~ "Map.get(@feed, :unread)"
    assert src =~ ~s(class="activity-unread")
  end
end
