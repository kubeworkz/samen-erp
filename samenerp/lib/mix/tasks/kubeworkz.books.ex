defmodule Mix.Tasks.Kubeworkz.Books do
  @shortdoc "Open the Kubeworkz books (COA, posting map, cost objects, FY budget)"

  @moduledoc """
  Opens the Kubeworkz set of accounting books for one tenant org — WS-ACCT
  Phase 2 (`Samenerp.Kubeworkz.Books`).

      mix kubeworkz.books --org kubeworkz
      mix kubeworkz.books --org 0f00…-…      # by org uuid

  `--org` takes a tenant org's **slug or id**. It is required on purpose: this
  seed writes a chart of accounts, a posting map and a budget, and opening them
  in the wrong tenant is not a mistake a default can be trusted to avoid. With
  no `--org` the task lists the tenant orgs it can see and refuses.

  Idempotent: a second run creates nothing. Rows that exist but disagree with
  the manual are REPORTED (never overwritten, never re-pointed) so an operator's
  edits survive a re-seed.
  """

  use Mix.Task

  require Ash.Query

  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} = OptionParser.parse(args, strict: [org: :string])

    if invalid != [] do
      Mix.raise("unrecognised option(s): #{inspect(invalid)} — usage: mix kubeworkz.books --org <slug|uuid>")
    end

    if rest != [] do
      Mix.raise("unexpected argument(s): #{inspect(rest)} — usage: mix kubeworkz.books --org <slug|uuid>")
    end

    org = resolve_org!(Keyword.get(opts, :org))

    summary = Books.seed!(org.id)

    Mix.shell().info("Kubeworkz books — #{org.name} (#{org.id})")
    report("chart of accounts", summary.accounts)
    report("posting map", summary.posting_accounts)
    report("cost objects", summary.cost_objects)

    Mix.shell().info(
      "budget            #{summary.budget.year} · " <>
        (if summary.budget.created, do: "created", else: "already open")
    )

    Mix.shell().info(
      "unmapped means    #{Enum.map_join(summary.unmapped, ", ", &to_string/1)} " <>
        "(the manual gives them no single account — see Samenerp.Kubeworkz.Books)"
    )

    for drift <- summary.accounts.drifted ++ summary.posting_accounts.drifted ++
                   summary.cost_objects.drifted do
      Mix.shell().info("DRIFT (left as-is) #{drift}")
    end

    case Books.verify(org.id) do
      {:ok, _} ->
        Mix.shell().info("books are OPEN — verify/1 agrees with the manual")

      {:error, gaps} ->
        Mix.raise("the books did not open cleanly:\n  " <> Enum.join(gaps, "\n  "))
    end
  end

  defp report(label, %{created: created, existing: existing}) do
    Mix.shell().info(
      String.pad_trailing(label, 17) <> "created #{created}, already open #{existing}"
    )
  end

  # The tenant org named by slug or id. The operator seat is not a tenant
  # workspace (Samenerp.Directory's own exclusion), so its books are not
  # opened by this task either.
  defp resolve_org!(nil) do
    Mix.raise(
      "--org is required (a tenant slug or uuid). This host's tenant orgs:\n" <>
        Enum.map_join(tenant_orgs(), "\n", fn org -> "  #{org.id}  #{org.name}  #{org.slug || "—"}" end)
    )
  end

  defp resolve_org!(name_or_id) do
    orgs = tenant_orgs()

    case Enum.find(orgs, fn org -> org.id == name_or_id or org.slug == name_or_id end) do
      nil ->
        Mix.raise(
          "no tenant org matches #{inspect(name_or_id)}. This host's tenant orgs:\n" <>
            Enum.map_join(orgs, "\n", fn org -> "  #{org.id}  #{org.name}  #{org.slug || "—"}" end)
        )

      org ->
        org
    end
  end

  defp tenant_orgs do
    operator = operator_org_id()

    Op.Org
    |> Ash.Query.filter((is_nil(plan) or plan != "operator") and id != ^operator)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp operator_org_id, do: Samenerp.Seeds.operator_org_id()
end
