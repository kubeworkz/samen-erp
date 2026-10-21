defmodule Mix.Tasks.Samenerp.Seed do
  @shortdoc "Seed the operator org and initial admin account"
  @moduledoc """
  Seed the Samen ERP operator org and initial admin account.

  Creates the well-known operator org and an admin user that can access
  the `/operator/*` control plane.

  Usage:

      mix samenerp.seed

  With custom credentials:

      mix samenerp.seed --email admin@mycompany.com --password mypassword

  Options:

      --email       Admin email (default: admin@samenerp.kubeworkz.io)
      --password    Admin password (default: changeme123456)
      --first-name  Admin first name (default: Admin)
      --last-name   Admin last name (default: User)

  In `MIX_ENV=dev` it also seeds the Pages demo content (`Samenerp.Seeds.seed_notes_pages!/1`):
  one page whose plain blocks are findable through `/pages?q=…` plus the search-index
  registration, so a fresh checkout demonstrates search instead of an empty box. That content is
  dev data, NOT a deploy side effect — the release entrypoint calls `Samenerp.Seeds.seed!()`
  directly, which registers the index but seeds nothing.

  Idempotent — safe to re-run. Short-circuits if already seeded.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)

    case Samenerp.Seeds.seed!(opts) do
      {:ok, :already_seeded} ->
        Mix.shell().info("Operator org already seeded — skipping.")

      {:ok, %{org: org, user: user}} ->
        Mix.shell().info("""

        ✅ Operator org seeded successfully!

        Operator Org: #{org.name} (#{org.id})
        Admin User:   #{user.handle || "admin"} (#{user.id})

        You can now log in at:
          https://samenerp.kubeworkz.io/login

        Default credentials:
          Email:    #{opts[:email] || "admin@samenerp.kubeworkz.io"}
          Password: #{opts[:password] || "changeme123456"}

        ⚠️  Change the default password after first login!

        The admin account has access to the operator control plane at:
          https://samenerp.kubeworkz.io/operator/accounts
        """)
    end

    maybe_seed_pages_demo()
  end

  # DEV ONLY. The Pages surface is mounted and its search index registered by `seed!/0,1`, but a
  # registry with nothing in it answers every `?q=` with the honest empty state — true, and useless
  # as a first impression. This seeds one page (two plain blocks + one vaulted) so `/pages?q=typed`
  # actually returns a block hit. It is gated on `Mix.env() == :dev` rather than on a flag because
  # the release entrypoint never runs this task (it calls `Samenerp.Seeds.seed!()` from an `eval`),
  # so there is no production path that could reach the demo content.
  defp maybe_seed_pages_demo do
    if Mix.env() == :dev do
      page_id = Samenerp.Seeds.seed_notes_pages!()

      Mix.shell().info("""

      📄 Pages demo seeded (dev only):
        Search:  https://samenerp.kubeworkz.io/pages?q=typed
        Page:    https://samenerp.kubeworkz.io/pages/#{page_id}

      One block on that page is vaulted (🔒) — it is deliberately NOT searchable.
      """)
    end
  end

  defp parse_args(args) do
    args
    |> OptionParser.parse(
      switches: [
        email: :string,
        password: :string,
        first_name: :string,
        last_name: :string
      ],
      aliases: [e: :email, p: :password]
    )
    |> elem(0)
  end
end
