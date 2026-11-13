defmodule Samen.Web.ErpJournalTemplatesTest do
  @moduledoc """
  The recurring journal-template surface (`/erp/journal_templates`):

    * the list is mounted through the closed ERP surface registry, appears in
      the ERP nav, filters by name, and links each template to its detail page;
    * a template can be created through the bounded line repeater;
    * its detail page renders the stored lines, edits both header fields and
      the line set, and offers Generate;
    * Generate creates an ordinary `JournalEntry` draft, never a posting, and
      the page links straight to that draft;
    * the operator plane still carries no write affordance.
  """

  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Erp.{DetailLive, SurfaceLive}

  alias Samen.WebTest.Erp.{
    JournalEntry,
    JournalLine,
    JournalTemplate
  }

  @org "77777777-8888-9999-aaaa-bbbbbbbbbbbb"

  # -- harness ----------------------------------------------------------------

  defp open(module, params) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = module.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      module.handle_params(params, "http://localhost/erp/journal_templates", socket)

    socket
  end

  defp event(module, socket, name, params) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  defp render(module, socket), do: render_html(module, socket.assigns)

  # -- seeds ------------------------------------------------------------------

  defp seed_account(code, name, kind, side) do
    Samen.WebTest.Erp.Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: @org, code: code, name: name, kind: kind, normal_side: side, currency: "USD"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp accounts do
    {seed_account("1000", "Cash", :asset, :debit),
     seed_account("4000", "Revenue", :income, :credit)}
  end

  defp template_lines(cash, sales, amount) do
    [
      %{account_id: cash.id, debit_cents: amount, credit_cents: 0, memo: "Debit"},
      %{account_id: sales.id, debit_cents: 0, credit_cents: amount, memo: "Credit"}
    ]
  end

  defp ui_lines(cash, sales, amount) do
    [
      %{
        "account_id" => cash.id,
        "debit_cents" => Integer.to_string(amount),
        "credit_cents" => "0",
        "memo" => "Debit"
      },
      %{
        "account_id" => sales.id,
        "debit_cents" => "0",
        "credit_cents" => Integer.to_string(amount),
        "memo" => "Credit"
      }
    ]
  end

  defp seed_template(attrs \\ %{}) do
    lines =
      Map.get_lazy(attrs, :lines, fn ->
        {cash, sales} = accounts()
        template_lines(cash, sales, 125_000)
      end)

    attrs =
      Map.merge(
        %{
          org_id: @org,
          name: "Monthly rent",
          memo: "Office rent",
          frequency: :monthly,
          next_run_on: ~D[2026-12-01],
          active: true,
          lines: lines
        },
        attrs
      )

    JournalTemplate
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  defp templates do
    JournalTemplate
    |> Ash.read!(authorize?: false)
  end

  # -- list + route -----------------------------------------------------------

  test "the template surface is registered, linked in the ERP nav, and lists templates" do
    template = seed_template()

    assert Samen.Web.Erp.surface("journal_templates") == :journal_templates
    assert Samen.Web.Erp.resource(build_mount(:erp), :journal_templates) == JournalTemplate

    html =
      mount_smoke(SurfaceLive, build_mount(:erp), %{
        "org" => @org,
        "surface" => "journal_templates"
      })

    assert html =~ ~s(id="erp-surface")
    assert html =~ ~s(href="/erp/journal_templates?org=#{@org}" class="on")
    assert html =~ "Journal templates"
    assert html =~ template.name
    assert html =~ "monthly"
    assert html =~ ~s(href="/erp/journal_templates/#{template.id}?org=#{@org}")
  end

  test "the list filters by template name" do
    {cash, sales} = accounts()
    rent = seed_template(%{name: "Rent", lines: template_lines(cash, sales, 100_000)})

    payroll =
      seed_template(%{
        name: "Payroll accrual",
        lines: template_lines(cash, sales, 200_000)
      })

    socket = open(SurfaceLive, %{"org" => @org, "surface" => "journal_templates"})

    socket = event(SurfaceLive, socket, "filter", %{"filter" => "Rent"})
    html = render(SurfaceLive, socket)

    assert html =~ rent.name
    refute html =~ payroll.name
  end

  # -- create through the line repeater ---------------------------------------

  test "a template is created with balanced lines from the list" do
    {cash, sales} = accounts()
    socket = open(SurfaceLive, %{"org" => @org, "surface" => "journal_templates"})
    socket = event(SurfaceLive, socket, "new_record", %{})

    assert render(SurfaceLive, socket) =~ ~s(id="line-rows")

    form = %{
      "name" => "Quarterly software",
      "memo" => "Licence renewal",
      "frequency" => "quarterly",
      "next_run_on" => "2027-01-15",
      "active" => "true",
      "lines" => ui_lines(cash, sales, 48_000)
    }

    socket = event(SurfaceLive, socket, "validate_new", %{"form" => form})
    socket = event(SurfaceLive, socket, "save_new", %{"form" => form})

    [template] = templates()

    assert template.name == "Quarterly software"
    assert template.frequency == :quarterly
    assert template.next_run_on == ~D[2027-01-15]
    assert template.active
    assert length(template.lines) == 2

    html = render(SurfaceLive, socket)
    refute html =~ ~s(id="new-record-modal")
    assert html =~ "Quarterly software"
    assert html =~ ~s(href="/erp/journal_templates/#{template.id}?org=#{@org}")
  end

  # -- detail, lines, edit ----------------------------------------------------

  test "the detail page renders lines and edits the header and line set" do
    {cash, sales} = accounts()
    template = seed_template(%{name: "Monthly rent", lines: template_lines(cash, sales, 90_000)})

    socket =
      open(DetailLive, %{
        "org" => @org,
        "surface" => "journal_templates",
        "id" => template.id
      })

    html = render(DetailLive, socket)
    assert html =~ template.name
    assert html =~ "monthly"
    assert html =~ "Generate draft"
    assert html =~ ~s(id="erp-lines")
    assert html =~ cash.id
    assert html =~ sales.id
    refute html =~ ~s(id="generated-draft-link")

    socket = event(DetailLive, socket, "edit_record", %{})
    html = render(DetailLive, socket)

    assert html =~ ~s(id="erp-edit-modal")
    assert html =~ ~s(id="edit-line-rows")
    assert html =~ ~s(id="add-edit-line")
    assert html =~ cash.id

    # Exercise the browser's index-keyed lines map (with its used-input
    # markers), not just the direct-call list shape.
    indexed_lines =
      ui_lines(cash, sales, 150_000)
      |> Enum.with_index()
      |> Map.new(fn {line, index} ->
        {Integer.to_string(index), Map.put(line, "_unused_memo", "")}
      end)

    form = %{
      "name" => "Updated rent",
      "memo" => "Updated memo",
      "frequency" => "yearly",
      "next_run_on" => "2027-06-01",
      "active" => "false",
      "lines" => indexed_lines
    }

    socket = event(DetailLive, socket, "validate_edit", %{"form" => form})
    socket = event(DetailLive, socket, "save_edit", %{"form" => form})

    updated = Ash.get!(JournalTemplate, template.id, authorize?: false)

    assert updated.name == "Updated rent"
    assert updated.memo == "Updated memo"
    assert updated.frequency == :yearly
    assert updated.next_run_on == ~D[2027-06-01]
    refute updated.active
    assert length(updated.lines) == 2
    assert Enum.any?(updated.lines, &(&1.debit_cents == 150_000))

    html = render(DetailLive, socket)
    refute html =~ ~s(id="erp-edit-modal")
    assert html =~ "Updated rent"
    assert html =~ "yearly"
  end

  # -- generate ---------------------------------------------------------------

  test "Generate creates an ordinary draft and links to it" do
    {cash, sales} = accounts()
    template = seed_template(%{lines: template_lines(cash, sales, 42_000)})

    socket =
      open(DetailLive, %{
        "org" => @org,
        "surface" => "journal_templates",
        "id" => template.id
      })

    assert render(DetailLive, socket) =~ "Generate draft"

    socket = event(DetailLive, socket, "generate", %{})
    entry_id = socket.assigns.record.last_entry_id

    assert entry_id
    assert socket.assigns.record.last_generated_on == Date.utc_today()
    assert socket.assigns.action_error == nil

    html = render(DetailLive, socket)
    assert html =~ ~s(id="generated-draft-link")
    assert html =~ ~s(href="/erp/entries/#{entry_id}?org=#{@org}")
    assert html =~ "Generated draft #{entry_id}"

    entry = Ash.get!(JournalEntry, entry_id, authorize?: false)

    assert entry.status == :draft
    assert entry.entry_date == Date.utc_today()
    assert entry.source_key == "journal_template"
    assert entry.source_id == template.id
    assert entry.approval_id == nil

    lines =
      JournalLine
      |> Ash.Query.filter(entry_id == ^entry.id)
      |> Ash.read!(authorize?: false)

    assert length(lines) == 2
    assert Enum.any?(lines, &(&1.debit_cents == 42_000))
  end

  # -- posture ----------------------------------------------------------------

  test "the operator plane carries no generate or edit affordance" do
    {cash, sales} = accounts()
    template = seed_template(%{lines: template_lines(cash, sales, 10_000)})

    mount = build_mount(:erp, plane: :operator, target_org_id: @org)
    session = mount_session(mount)

    params = %{
      "org" => @org,
      "surface" => "journal_templates",
      "id" => template.id
    }

    {:ok, socket} = DetailLive.mount(params, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = DetailLive.handle_params(params, "http://localhost/erp/detail", socket)
    html = render_html(DetailLive, socket.assigns)

    refute html =~ ~s(id="generate-draft")
    refute html =~ ~s(id="edit-record")
  end
end
