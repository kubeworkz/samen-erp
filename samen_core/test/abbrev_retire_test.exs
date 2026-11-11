defmodule Samen.Abbrev.RetirementTest do
  use ExUnit.Case, async: true

  alias Samen.Abbrev.Retirement

  setup do
    root =
      Path.join(System.tmp_dir!(), "samen-abbrev-retire-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "demo/lib/demo"))
    File.mkdir_p!(Path.join(root, "demo/priv/repo/migrations"))

    write(root, "demo/lib/demo/live.ex", """
    defmodule Demo.Live do
    end
    """)

    registry = Path.join(root, "abbrev_registry.json")

    File.write!(
      registry,
      Jason.encode!(
        %{
          "$comment" => "PERMANENT abbrevs",
          "abbrevs" => %{
            "aaa" => "Demo.Live",
            "bbb" => "Demo.Dead",
            "ccc" => "Demo.Other"
          },
          "hosts" => %{"host" => %{"ddd" => "Demo.Dead"}}
        },
        pretty: true
      ) <> "\n"
    )

    manifest = Path.join(root, "retire.tsv")
    File.write!(manifest, "Demo.Dead\tdmb_dead\nDemo.Missing\t\n")

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, registry: registry, manifest: manifest}
  end

  describe "plan/3" do
    test "finds every row for a deleted owner and reports missing rows", %{
      root: root,
      registry: registry
    } do
      assert {:ok, plan} =
               Retirement.plan(root, registry, [
                 %{owner: "Demo.Dead", table: "dmb_dead"},
                 %{owner: "Demo.Missing", table: nil}
               ])

      assert Enum.map(plan.retire, & &1.abbrev) |> Enum.sort() == ["bbb", "ddd"]
      assert Enum.map(plan.missing, & &1.owner) == ["Demo.Missing"]
    end

    test "refuses an owner that still has a source module", %{root: root, registry: registry} do
      write(root, "demo/lib/demo/dead.ex", """
      defmodule Demo.Dead do
      end
      """)

      assert {:error, violations} =
               Retirement.plan(root, registry, [%{owner: "Demo.Dead", table: "dmb_dead"}])

      assert Enum.any?(violations, &(&1 =~ "still has a defmodule"))
    end

    test "refuses a table created by any app migration", %{root: root, registry: registry} do
      write(root, "demo/priv/repo/migrations/20260101000000_create_dead.exs", """
      defmodule Demo.Repo.Migrations.CreateDead do
        use Ecto.Migration

        def change do
          create table(:dmb_dead) do
            add :name, :string
          end
        end
      end
      """)

      assert {:error, violations} =
               Retirement.plan(root, registry, [%{owner: "Demo.Dead", table: "dmb_dead"}])

      assert Enum.any?(violations, &(&1 =~ "is created by a migration"))
    end

    test "refuses a migration that references the owner module", %{
      root: root,
      registry: registry
    } do
      write(root, "demo/priv/repo/migrations/20260101000000_create_other.exs", """
      defmodule Demo.Repo.Migrations.CreateOther do
        use Ecto.Migration

        def change do
          create table(:other_table)
        end

        def resources, do: [Demo.Dead]
      end
      """)

      assert {:error, violations} =
               Retirement.plan(root, registry, [%{owner: "Demo.Dead", table: "dmb_dead"}])

      assert Enum.any?(violations, &(&1 =~ "migration references"))
    end

    test "refuses a schema.dict entry naming the owner", %{root: root, registry: registry} do
      File.write!(
        Path.join(root, "demo/schema.dict.json"),
        Jason.encode!(%{"resource" => "Demo.Dead"})
      )

      assert {:error, violations} =
               Retirement.plan(root, registry, [%{owner: "Demo.Dead", table: "dmb_dead"}])

      assert Enum.any?(violations, &(&1 =~ "schema.dict.json"))
    end

    test "refuses a target with no table evidence", %{root: root, registry: registry} do
      assert {:error, violations} =
               Retirement.plan(root, registry, [%{owner: "Demo.Dead", table: nil}])

      assert Enum.any?(violations, &(&1 =~ "no table evidence"))
    end
  end

  describe "apply!/2 and the mix task" do
    test "apply removes all rows, preserves unrelated rows and the comment", %{
      root: root,
      registry: registry
    } do
      assert {:ok, plan} =
               Retirement.plan(root, registry, [%{owner: "Demo.Dead", table: "dmb_dead"}])

      assert Retirement.apply!(registry, plan) == 2

      raw = File.read!(registry)
      decoded = Jason.decode!(raw)

      refute raw =~ "Demo.Dead"
      assert decoded["$comment"] == "PERMANENT abbrevs"
      assert decoded["abbrevs"]["aaa"] == "Demo.Live"
      assert decoded["abbrevs"]["ccc"] == "Demo.Other"
      assert decoded["hosts"]["host"] == %{}
    end

    test "the task is read-only by default and writes with --apply", %{
      root: root,
      registry: registry,
      manifest: manifest
    } do
      before = File.read!(registry)

      Mix.Tasks.Samen.Abbrev.Retire.run([
        "--manifest",
        manifest,
        "--registry",
        registry,
        "--root",
        root
      ])

      assert File.read!(registry) == before

      Mix.Tasks.Samen.Abbrev.Retire.run([
        "--manifest",
        manifest,
        "--registry",
        registry,
        "--root",
        root,
        "--apply"
      ])

      refute File.read!(registry) =~ "Demo.Dead"
      assert Jason.decode!(File.read!(registry))["abbrevs"]["aaa"] == "Demo.Live"
    end
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
