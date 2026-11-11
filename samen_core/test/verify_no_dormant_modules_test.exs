defmodule SamenCore.VerifyNoDormantModulesTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.NoDormantModules

  @project_dir Path.expand("../", __DIR__)

  setup do
    root = Path.join([System.tmp_dir!(), "samen-dormant-#{System.unique_integer([:positive])}"])
    File.rm_rf!(root)
    File.mkdir_p!(root)

    write(root, "samen_core/lib/samen/scopes/live.ex", """
    defmodule Samen.Scopes.Live do
      def blueprint, do: Samen.Scopes.Live.Blueprint
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/blueprint.ex", """
    defmodule Samen.Scopes.Live.Blueprint do
      def helper, do: Samen.Scopes.Live.Helper
      def resource, do: Samen.Scopes.Live.Resource
      def service, do: Samen.Scopes.Live.Service
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/helper.ex", """
    defmodule Samen.Scopes.Live.Helper do
    end

    defmodule Samen.Scopes.Live.Helper.Nested do
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/service.ex", """
    defmodule Samen.Scopes.Live.Service do
      def worker, do: Samen.Scopes.Live.Worker
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/worker.ex", """
    defmodule Samen.Scopes.Live.Worker do
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/resource.ex", """
    defmodule Samen.Scopes.Live.Resource do
      table("liv_resource")
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/report.ex", """
    defmodule Samen.Scopes.Live.Report do
    end
    """)

    write(root, "samen_core/lib/samen/scopes/live/orphan_resource.ex", """
    defmodule Samen.Scopes.Live.OrphanResource do
      table("liv_orphan")
    end
    """)

    write(root, "samen_core/lib/samen/scopes/shelf/thing.ex", """
    defmodule Samen.Scopes.Shelf.Thing do
      table("shf_thing")
    end

    defmodule LocalHelper do
    end
    """)

    write(root, "demo/lib/demo/domain.ex", """
    defmodule Demo.Domain do
      use Samen.Scopes.Live
    end
    """)

    write(root, "demo/priv/repo/migrations/20260101000000_create_live.exs", """
    defmodule Demo.Repo.Migrations.CreateLive do
      use Ecto.Migration

      def change do
        create table(:liv_resource) do
          add :name, :string
        end
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "dormant modules" do
    test "flags only the unreachable, unmigrated, unreferenced modules", %{root: root} do
      violations = NoDormantModules.check(root)
      text = Enum.join(violations, "\n")

      assert text =~ "Samen.Scopes.Live.Report"
      assert text =~ "Samen.Scopes.Live.OrphanResource"
      assert text =~ "Samen.Scopes.Shelf.Thing"

      refute text =~ "Samen.Scopes.Live.Resource"
      refute text =~ "Samen.Scopes.Live.Helper"
      refute text =~ "Samen.Scopes.Live.Helper.Nested"
      refute text =~ "Samen.Scopes.Live.Service"
      refute text =~ "Samen.Scopes.Live.Worker"
      refute text =~ "Samen.Scopes.Live.Blueprint"
      refute text =~ "Samen.Scopes.Live ("
      refute text =~ "LocalHelper"
    end

    test "a blueprint in an unmounted scope does not make its module live", %{root: root} do
      write(root, "samen_core/lib/samen/scopes/shelf/blueprint.ex", """
      defmodule Samen.Scopes.Shelf.Blueprint do
        def thing, do: Samen.Scopes.Shelf.Thing
      end
      """)

      text = NoDormantModules.check(root) |> Enum.join("\n")
      assert text =~ "Samen.Scopes.Shelf.Thing"
    end

    test "a dotted function call is a live reference", %{root: root} do
      write(root, "demo/lib/demo/consumer.ex", """
      defmodule Demo.Consumer do
        def render, do: Samen.Scopes.Live.Report.render()
      end
      """)

      text = NoDormantModules.check(root) |> Enum.join("\n")
      refute text =~ "Samen.Scopes.Live.Report"
    end

    test "a tree with only live modules passes", %{root: root} do
      File.rm!(Path.join(root, "samen_core/lib/samen/scopes/live/report.ex"))
      File.rm!(Path.join(root, "samen_core/lib/samen/scopes/live/orphan_resource.ex"))
      File.rm_rf!(Path.join(root, "samen_core/lib/samen/scopes/shelf"))

      assert NoDormantModules.check(root) == []
    end

    test "the real tree has no dormant modules after the ADR-055 execution" do
      root = Path.expand("../..", __DIR__)

      assert NoDormantModules.check(root) == []
    end

    @tag :exit_code
    test "mix task exits 1 and names a dormant module", %{root: root} do
      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.no_dormant_modules", "--root", root],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit code 1 for a dormant module, got #{exit_code}.\nOutput: #{output}"

      assert output =~ "dormant module"
      assert output =~ "Samen.Scopes.Live.Report"
    end
  end

  defp write(root, path, content) do
    full = Path.join([root | Path.split(path)])
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
