defmodule Samenerp.Phase6SurfaceTest do
  @moduledoc """
  Phase-6 host surface proofs — the Calendar & Scheduling group (the framework
  `.ics` export over this host's materialized `Samenerp.Calendar` domain),
  driven through the REAL router (the `Samenerp.Phase1..5SurfaceTest`
  discipline):

    * `GET /calendar.ics` — the `samen_ics_routes(:ics, Samenerp.Calendar, …)`
      one-liner serves the framework `text/calendar` download over this host's
      `evt_event` rows. A fresh org gets a WELL-FORMED but eventless
      `VCALENDAR` (the honest empty state, never a fabricated feed).
    * **org scoping** — the export serves exactly the `?org=` tenant's events:
      another org's event never appears (the authorization boundary, not a
      rendering detail).
    * **INV-1 three-proof** (`Samen.MaskingCase`) — `attendees` is 🔒 vaulted
      (ADR-016): the raw `evt_attendees` column holds an opaque `vt_*` token,
      the TENANT-plane feed carries the real address in the clear, the
      OPERATOR-plane feed carries the masked `X-SAMEN-ATTENDEES:••••`
      placeholder (never the plaintext, never a `vt_*` token, no per-address
      `ATTENDEE:` line), and both anti-tautology twins hold: the same event
      flipped to the tenant plane goes clear, and a modeled `vt_*` leak IS
      caught by the same scan.
    * **recurrence** — a recurring event exports ONE `VEVENT` carrying an
      `RRULE` (the standard iCalendar shape), mapped from
      `Samen.Scopes.Calendar.Recurrence.cast_rule/1` — the same source of
      truth the expansion helper uses.
  """

  use Samenerp.DataCase, async: false
  use Samen.MaskingCase

  import Phoenix.ConnTest

  alias Samenerp.Operator, as: Op
  alias Samen.Web.Ics
  alias Samen.Web.Plane

  @endpoint SamenerpWeb.Endpoint

  # The vaulted attendee address the leak scan hunts for, on every plane.
  @secret_addr "phase6.vaulted.attendee@sample.invalid"

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("phase6-operator", org_id, "phase6-ics-session"), org_id)

  # Seeded through the GOVERNED create action on the tenant plane, exactly as a
  # real form/API write would — so the vault routing under test is the routing
  # production uses, not a fixture shortcut.
  defp seed_event!(org, attrs \\ %{}) do
    Samenerp.Calendar.Event
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org.id,
          title: "Phase6 Board Sync",
          starts_at: ~U[2026-10-12 15:00:00.000000Z],
          ends_at: ~U[2026-10-12 16:00:00.000000Z],
          location: "HQ",
          attendees: [%{label: "chair", address: @secret_addr}]
        },
        attrs
      ),
      scope: tenant_scope(org.id)
    )
    |> Ash.create!()
  end

  defp export!(scope) do
    {:ok, ics} = Ics.export(Samenerp.Calendar.Event, scope, repo: Samenerp.Repo)
    ics
  end

  defp raw_attendees(org_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT evt_attendees FROM evt_event WHERE evt_org_id = $1",
        [Ecto.UUID.dump!(org_id)]
      )

    Enum.map(rows, fn [value] -> value end)
  end

  # Structural RFC-5545 assertion (a hand-rolled parser, no new dependency —
  # matching how the framework proves its own `.ics` output).
  defp assert_parseable_vcalendar!(ics) do
    assert String.starts_with?(ics, "BEGIN:VCALENDAR\r\n"),
           "the export must open with BEGIN:VCALENDAR (got: #{inspect(String.slice(ics, 0, 40))})"

    assert String.ends_with?(ics, "END:VCALENDAR\r\n"), "the export must close with END:VCALENDAR"
    assert ics =~ "VERSION:2.0\r\n"
    assert ics =~ ~r/^PRODID:.+\r\n/m

    begins = ics |> String.split("BEGIN:VEVENT") |> length() |> Kernel.-(1)
    ends = ics |> String.split("END:VEVENT") |> length() |> Kernel.-(1)
    assert begins == ends, "unbalanced VEVENT blocks (#{begins} BEGIN / #{ends} END)"

    ics
  end

  # ── the mount: a real-route tenant-plane export ─────────────────────────────

  test "GET /calendar.ics serves this host's Calendar mount (tenant plane, attendee clear)" do
    tenant = create_org!("Phase6 ICS QA")
    seed_event!(tenant)

    conn = get(build_conn(), "/calendar.ics?org=#{tenant.id}")

    assert conn.status == 200,
           "the /calendar.ics route did not render (status=#{conn.status}) — the :ics mount is missing or crashing"

    assert hd(Plug.Conn.get_resp_header(conn, "content-type")) =~ "text/calendar"

    assert hd(Plug.Conn.get_resp_header(conn, "content-disposition")) =~
             ~s(filename="calendar.ics")

    ics = conn.resp_body |> assert_parseable_vcalendar!()

    assert ics =~ "BEGIN:VEVENT"
    assert ics =~ "UID:", "a VEVENT must carry a stable UID"
    assert ics =~ "DTSTAMP:"
    assert ics =~ "DTSTART:20261012T150000Z"
    assert ics =~ "SUMMARY:Phase6 Board Sync"
    assert ics =~ "LOCATION:HQ"

    # GREEN: on the tenant's own plane the attendee address is in the clear.
    assert ics =~ @secret_addr
    assert ics =~ "ATTENDEE;CN=chair:mailto:#{@secret_addr}"
    refute ics =~ "vt_", "a vt_* vault token must never reach the exported feed"
  end

  test "a fresh org exports a well-formed but EVENTLESS VCALENDAR (honest empty state)" do
    tenant = create_org!("Phase6 ICS Empty")

    conn = get(build_conn(), "/calendar.ics?org=#{tenant.id}")

    assert conn.status == 200
    ics = conn.resp_body |> assert_parseable_vcalendar!()

    refute ics =~ "BEGIN:VEVENT",
           "an org with no events must export an empty feed, never a fabricated VEVENT"

    refute ics =~ @secret_addr
  end

  test "the export is ORG-SCOPED: another org's events never appear" do
    org_a = create_org!("Phase6 ICS Org A")
    org_b = create_org!("Phase6 ICS Org B")

    seed_event!(org_a, %{title: "A-only event"})
    seed_event!(org_b, %{title: "B-only event"})

    ics_a = get(build_conn(), "/calendar.ics?org=#{org_a.id}").resp_body
    assert ics_a =~ "A-only event"
    refute ics_a =~ "B-only event", "the export leaked another org's event — org scoping is the boundary"

    ics_b = get(build_conn(), "/calendar.ics?org=#{org_b.id}").resp_body
    assert ics_b =~ "B-only event"
    refute ics_b =~ "A-only event"
  end

  test "a recurring event exports ONE VEVENT carrying an RRULE (Recurrence.cast_rule mapping)" do
    tenant = create_org!("Phase6 ICS Recurring")

    seed_event!(tenant, %{
      title: "Phase6 Weekly Standup",
      recurrence: %{"freq" => "weekly", "interval" => 1, "count" => 3}
    })

    ics = get(build_conn(), "/calendar.ics?org=#{tenant.id}").resp_body |> assert_parseable_vcalendar!()

    # One VEVENT, not one per occurrence — the standard shape every calendar
    # client expands itself.
    assert length(String.split(ics, "BEGIN:VEVENT")) == 2
    assert ics =~ "RRULE:FREQ=WEEKLY;INTERVAL=1;COUNT=3"
  end

  # ── INV-1: the vaulted attendee, three proofs ───────────────────────────────

  test "attendees is vaulted at rest, CLEAR on the tenant plane, MASKED on the operator plane (INV-1)" do
    tenant = create_org!("Phase6 ICS Masking")
    seed_event!(tenant)

    # (0) AT REST — the domain column holds an opaque vt_* token, never plaintext.
    assert [raw] = raw_attendees(tenant.id)
    assert is_binary(raw), "expected the vault token as text, got: #{inspect(raw)}"
    assert String.starts_with?(raw, "vt_"), "the attendee column must hold a vault token"
    refute raw =~ @secret_addr, "the plaintext attendee leaked into the domain row"
    refute raw =~ "sample.invalid"

    # (1) GREEN — the tenant's own plane resolves the address in the clear.
    tenant_ics = export!(tenant_scope(tenant.id)) |> assert_parseable_vcalendar!()
    assert tenant_ics =~ @secret_addr
    assert tenant_ics =~ "ATTENDEE"
    refute tenant_ics =~ mask()

    # (2) RED — the operator plane masks by placeholder: never the plaintext,
    #     never a vt_* token, and no per-address ATTENDEE line at all.
    operator_ics = export!(operator_scope(tenant.id)) |> assert_parseable_vcalendar!()
    assert_masked_dom!(operator_ics, [@secret_addr])
    assert operator_ics =~ "X-SAMEN-ATTENDEES:#{mask()}"
    refute operator_ics =~ "ATTENDEE:mailto:"
    # Non-PII rides along untouched: masking is per-field, not per-feed.
    assert operator_ics =~ "SUMMARY:Phase6 Board Sync"
    assert operator_ics =~ "LOCATION:HQ"

    # (3) SABOTAGE twin A — the SAME event, only the plane differs: tenant goes
    #     CLEAR, so the mask assertion is refutable, not a blanket mask.
    refute operator_ics == tenant_ics
    assert tenant_ics =~ @secret_addr

    # (4) SABOTAGE twin B — the vt_ leak scan IS refutable: a modeled raw-token
    #     render is caught by the same scan `assert_masked_dom!/2` applies.
    leaked = "BEGIN:VEVENT\r\nX-SAMEN-ATTENDEES:#{raw}\r\nEND:VEVENT\r\n"
    assert_leak_detected!(leaked, "vt_")
  end
end
