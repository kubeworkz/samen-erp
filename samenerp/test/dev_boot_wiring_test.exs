defmodule Samenerp.DevBootWiringTest do
  @moduledoc """
  A `mix phx.server` restart must perform the SAME idempotent boot repairs the release
  entrypoint does (`Samenerp.Seeds.seed!/0`): the operator-book tenant mirror and the
  Bridge-B tenant back-references, the policy defaults and the Pages search registration.

  It must NOT re-seed the Pages demo content on every boot — that page is dev sample data
  added by `mix samenerp.seed`, and the release entrypoint never seeds it.

  Both halves are pinned here: the wiring in `mix.exs` (`phx.server` runs `samenerp.boot`
  first) AND the task's effect on a legacy slug-nil operator-book row, so dropping either
  half fails here instead of silently re-breaking "Open account →" on a dev restart.
  """
  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Operator, as: Op

  setup do
    {:ok, %{org: operator_org}} = Samenerp.Seeds.ensure_admin!()
    %{operator_org_id: operator_org.id}
  end

  test "mix phx.server runs the boot repair step before serving" do
    aliases = Mix.Project.config()[:aliases]

    assert aliases[:"phx.server"] == ["samenerp.boot", "phx.server"],
           "mix phx.server no longer boots through the repair task"

    refute "samenerp.seed" in aliases[:"phx.server"],
           "mix phx.server must not run the task that seeds the Pages demo content"

    assert Mix.Task.get("samenerp.boot") == Mix.Tasks.Samenerp.Boot
  end

  test "the boot task stamps a legacy operator-book row and seeds no Pages demo", %{
    operator_org_id: operator_org_id
  } do
    legacy =
      Op.Org
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: operator_org_id, name: "Legacy Boot Account", plan: "free"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert legacy.slug == nil
    refute demo_page_seeded?()

    assert :ok = Mix.Tasks.Samenerp.Boot.run([])

    assert Ash.get!(Op.Org, legacy.id, authorize?: false).slug == legacy.id,
           "the dev boot did not stamp the legacy account's tenant back-reference"

    refute demo_page_seeded?(), "the dev boot re-seeded the Pages demo content"
  end

  defp demo_page_seeded? do
    Samenerp.Docs.Doc
    |> Ash.Query.filter(title == "Welcome to Pages")
    |> Ash.exists?(authorize?: false)
  end
end
