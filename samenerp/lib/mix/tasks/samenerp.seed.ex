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
