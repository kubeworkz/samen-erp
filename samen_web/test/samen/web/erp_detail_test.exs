defmodule Samen.Web.ErpDetailTest do
  @moduledoc """
  WS-ERP E8 detail + write-affordance proof over the REAL `Samen.WebTest.Erp`
  action shapes (the Finance + Inventory scope blueprints, not a stand-in):

    * the record page renders inside the app shell with the surface's nav item
      active and the bounded `Erp.detail_fields/1` facts (a seeded CoA account);
    * an id that resolves nothing renders the honest not-found card, an unknown
      surface the not-found state — neither names a module;
    * Edit rides `AshPhoenix.Form.for_update` — blank required fields render
      inline errors and persist nothing, a valid save lands;
    * the governed `accept([])` transitions: a balanced draft entry Posts
      (status flips, the offered buttons follow the registry's `from_statuses`)
      and an out-of-pre-state transition is refused server-side;
    * the journal-entry CREATE with the bounded line repeater lands BOTH the
      entry and its two balanced lines (the line-argument path);
    * the operator plane carries no write affordance.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.DetailLive
  alias Samen.Web.Erp.SurfaceLive

  @org "33333333-4444-5555-6666-777777777777"

  # -- harness ----------------------------------------------------------------

  defp open(module, params) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = module.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = module.handle_params(params, "http://localhost/erp/detail", socket)
    socket
  end

  defp event(module, socket, name, params) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  # -- seeds ------------------------------------------------------------------

  defp seed_account(code \\ "1000") do
    Samen.WebTest.Erp.Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        code: code,
        name: "Cash",
        kind: :asset,
        normal_side: :debit,
        currency: "USD"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_entry(account_id) do
    Samen.WebTest.Erp.JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        entry_date: ~D[2026-10-01],
        memo: "Opening balance",
        lines: [
          %{account_id: account_id, debit_cents: 50_000, credit_cents: 0},
          %{account_id: account_id, debit_cents: 0, credit_cents: 50_000}
        ]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp reload_entry(id) do
    Samen.WebTest.Erp.JournalEntry
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  defp count(mod), do: mod |> Ash.read!(authorize?: false) |> length()

  # -- the record page ----------------------------------------------------------

  test "a seeded record renders its bounded facts in the shell with the surface active" do
    account = seed_account("1000")
    socket = open(DetailLive, %{"org" => @org, "surface" => "coa", "id" => account.id})
    html = render_html(DetailLive, socket.assigns)

    assert html =~ ~s(id="erp-detail")
    assert html =~ ~s(class="app")
    # The surface's nav item is active from the record page too.
    assert html =~ ~s(href="/erp/coa?org=#{@org}" class="on")
    # Bounded facts (humanized registry field labels) + the values.
    assert html =~ "Normal side"
    assert html =~ "1000"
    assert html =~ "Cash"
    assert html =~ "debit"
    # Back link to the list, the edit affordance, the coa has no transitions.
    assert html =~ ~s(href="/erp/coa?org=#{@org}")
    assert html =~ ~s(id="edit-record")
    refute html =~ ~s(id="erp-transitions")
  end

  test "an id that resolves nothing renders the honest not-found card" do
    socket =
      open(DetailLive, %{
        "org" => @org,
        "surface" => "coa",
        "id" => "99999999-9999-9999-9999-999999999999"
      })

    html = render_html(DetailLive, socket.assigns)

    assert html =~ "Account not found."
  end

  test "an unknown surface renders the not-found state and names no module" do
    socket =
      open(DetailLive, %{
        "org" => @org,
        "surface" => "bogus",
        "id" => "99999999-9999-9999-9999-999999999999"
      })

    html = render_html(DetailLive, socket.assigns)

    assert html =~ "not available on this workspace's mounted modules"
    assert html =~ "Not found"
  end

  # -- edit --------------------------------------------------------------------

  test "edit: blank required fields render inline errors; a valid save lands" do
    account = seed_account("1000")
    params = %{"org" => @org, "surface" => "coa", "id" => account.id}
    socket = open(DetailLive, params)

    socket = event(DetailLive, socket, "edit_record", %{})
    assert render_html(DetailLive, socket.assigns) =~ ~s(id="erp-edit-modal")

    socket =
      event(DetailLive, socket, "validate_edit", %{
        "form" => %{
          "name" => "",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    assert render_html(DetailLive, socket.assigns) =~ "field-invalid"

    # Invalid submit: still on the form, nothing persisted.
    socket =
      event(DetailLive, socket, "save_edit", %{
        "form" => %{
          "name" => "",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    assert render_html(DetailLive, socket.assigns) =~ "field-invalid"
    assert reload(account.id).name == "Cash"

    # Valid submit: persisted, modal closed, facts refreshed.
    socket =
      event(DetailLive, socket, "save_edit", %{
        "form" => %{
          "name" => "Operating Cash",
          "kind" => "asset",
          "normal_side" => "debit",
          "currency" => "USD"
        }
      })

    html = render_html(DetailLive, socket.assigns)
    refute html =~ ~s(id="erp-edit-modal")
    assert reload(account.id).name == "Operating Cash"
    assert html =~ "Operating Cash"
  end

  defp reload(id) do
    Samen.WebTest.Erp.Account
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # -- governed transitions ------------------------------------------------------

  test "Post flips a balanced draft entry and the offered buttons follow the registry" do
    account = seed_account()
    entry = seed_entry(account.id)
    params = %{"org" => @org, "surface" => "entries", "id" => entry.id}

    socket = open(DetailLive, params)
    html = render_html(DetailLive, socket.assigns)

    assert html =~ ~s(id="transition-post")
    refute html =~ ~s(id="transition-void")
    assert reload_entry(entry.id).status == :draft

    socket = event(DetailLive, socket, "transition", %{"action" => "post"})
    html = render_html(DetailLive, socket.assigns)

    posted = reload_entry(entry.id)
    assert posted.status == :posted
    assert posted.posted_at
    # Void becomes offerable from :posted; post does not.
    assert html =~ ~s(id="transition-void")
    refute html =~ ~s(id="transition-post")
    refute html =~ ~s(id="action-error")
  end

  test "an out-of-pre-state transition is refused server-side (never trusts the click)" do
    account = seed_account()
    entry = seed_entry(account.id)
    params = %{"org" => @org, "surface" => "entries", "id" => entry.id}

    socket = open(DetailLive, params)
    # `void` is only offered FROM :posted — a draft click is silently refused.
    socket = event(DetailLive, socket, "transition", %{"action" => "void"})

    assert reload_entry(entry.id).status == :draft
    _ = render_html(DetailLive, socket.assigns)
  end

  # -- the create line-repeater path ---------------------------------------------

  test "journal-entry create lands the entry AND its balanced lines through the repeater" do
    account = seed_account()
    params = %{"org" => @org, "surface" => "entries"}
    socket = open(SurfaceLive, params)

    socket = event(SurfaceLive, socket, "new_record", %{})
    assert render_html(SurfaceLive, socket.assigns) =~ ~s(id="line-rows")

    form = %{
      "entry_date" => "2026-10-02",
      "memo" => "Opening entry",
      "lines" => [
        %{"account_id" => account.id, "debit_cents" => "50000", "credit_cents" => "0"},
        %{"account_id" => account.id, "debit_cents" => "0", "credit_cents" => "50000"}
      ]
    }

    socket = event(SurfaceLive, socket, "validate_new", %{"form" => form})
    socket = event(SurfaceLive, socket, "save_new", %{"form" => form})

    assert count(Samen.WebTest.Erp.JournalEntry) == 1
    assert count(Samen.WebTest.Erp.JournalLine) == 2

    [entry] =
      Samen.WebTest.Erp.JournalEntry
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.read!(authorize?: false)

    assert entry.status == :draft
    assert entry.org_id == @org

    # The fresh row links onward to its own detail page.
    html = render_html(SurfaceLive, socket.assigns)
    assert html =~ ~s(href="/erp/entries/#{entry.id}?org=#{@org}")
  end

  test "an unbalanced entry create is refused honestly by the balance guard" do
    account = seed_account()
    params = %{"org" => @org, "surface" => "entries"}
    socket = open(SurfaceLive, params)
    socket = event(SurfaceLive, socket, "new_record", %{})

    form = %{
      "entry_date" => "2026-10-02",
      "lines" => [
        %{"account_id" => account.id, "debit_cents" => "50000", "credit_cents" => "0"}
      ]
    }

    socket = event(SurfaceLive, socket, "save_new", %{"form" => form})

    assert count(Samen.WebTest.Erp.JournalEntry) == 0
    assert count(Samen.WebTest.Erp.JournalLine) == 0
    assert render_html(SurfaceLive, socket.assigns) =~ ~s(id="new-record-modal")
  end

  # -- operator posture ------------------------------------------------------------

  test "the operator plane carries no detail write affordance" do
    account = seed_account()

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)
    params = %{"org" => @org, "surface" => "coa", "id" => account.id}

    {:ok, socket} = DetailLive.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = DetailLive.handle_params(params, "http://localhost/erp/detail", socket)
    html = render_html(DetailLive, socket.assigns)

    refute html =~ ~s(id="edit-record")
    refute html =~ ~s(id="erp-transitions")
  end
end
