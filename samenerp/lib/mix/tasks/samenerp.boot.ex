defmodule Mix.Tasks.Samenerp.Boot do
  @shortdoc "Run the release boot repairs before the dev server starts"

  @moduledoc """
  The dev-server counterpart of the release entrypoint's boot step.

  `entrypoint.sh` runs `Samenerp.Seeds.seed!/0` from an `eval` BEFORE the release starts, so
  every deploy repairs the operator book (tenant mirror + Bridge-B tenant back-references), the
  policy defaults and the Pages search registration. `mix phx.server` had no equivalent step, so
  a dev restart silently skipped those repairs — a legacy operator-book account stayed
  slug-less and unopenable even though the same restart would have fixed it in production.

  Wired in `mix.exs` as `"phx.server": ["samenerp.boot", "phx.server"]`, so `mix phx.server`
  performs the SAME idempotent repairs (`Samenerp.Seeds.seed!/0`) before serving.

  It deliberately does NOT call `Samenerp.Seeds.seed_notes_pages!/1`: the Pages demo page is
  dev sample data added by `mix samenerp.seed`, not something a server restart should re-seed.
  The release entrypoint never seeds it either, so this task stays at entrypoint parity.

  Idempotent, like `seed!/0,1`: an already-seeded install only runs the backfills.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    case Samenerp.Seeds.seed!() do
      {:ok, :already_seeded} ->
        Mix.shell().info(
          "[samenerp.boot] operator org present — operator book, policies and search index repaired"
        )

      {:ok, %{org: org}} ->
        Mix.shell().info(
          "[samenerp.boot] seeded operator org #{org.id} and repaired the operator book"
        )
    end

    :ok
  end
end
