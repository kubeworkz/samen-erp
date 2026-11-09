defmodule Samen.Web.DataCaseAsyncLintTest do
  @moduledoc """
  Guard: a test module that uses a host `DataCase` template must be synchronous.

  The host DataCase templates (`Samen.WebTest.DataCase`, `Demo.DataCase`, and the
  verticals' equivalents) call
  `Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})` in `setup`. ExUnit's
  shared sandbox mode is suite-global, not scoped to the test process: an async
  DataCase test exposes its connection to every concurrently running test. When the
  DataCase test finishes, its owner exits and a concurrent test can crash with
  `DBConnection.Holder.checkout` / `"owner ... exited"`.

  Sync tests run after the async phase, so their shared owner cannot be torn down
  from under another test. This lint walks every `*_test.exs` under every app's
  `test/` tree and fails, with file and line, on any `use ...DataCase, async: true`.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @test_glob Path.join(@repo_root, "*/test/**/*_test.exs")

  # Non-vacuity floors: a broken glob or a matcher that stops seeing DataCase uses
  # must fail loudly instead of green-lighting an empty sweep.
  @min_test_files 50
  @min_data_case_uses 20
  @required_data_case_modules [Samen.WebTest.DataCase, Demo.DataCase]

  test "every test module using a DataCase is synchronous" do
    files = test_files()
    assert length(files) >= @min_test_files, "sweep saw only #{length(files)} test files"

    uses = Enum.flat_map(files, &scan_file!/1)

    assert length(uses) >= @min_data_case_uses,
           "sweep saw only #{length(uses)} DataCase uses"

    for module <- @required_data_case_modules do
      assert Enum.any?(uses, &(&1.module == module)),
             "sweep did not see any test using #{inspect(module)}"
    end

    offenders = Enum.filter(uses, & &1.async)

    assert offenders == [], """
    A test module using a shared-sandbox DataCase is marked async:

    #{Enum.map_join(offenders, "\n", &offender_line/1)}

    DataCase setup sets Ecto's sandbox mode to {:shared, self()}. An async DataCase
    test can lend its connection to a concurrent test; when the DataCase test exits,
    the other test crashes with a DBConnection owner-exit error. Remove `async: true`
    (ExUnit defaults to false) from these test modules.
    """
  end

  test "the detector flags an async DataCase use" do
    source = """
    defmodule Fixture.AsyncDataCase do
      use Samen.WebTest.DataCase, async: true
    end
    """

    assert [%{module: Samen.WebTest.DataCase, async: true}] =
             scan_source!(source, "fixture/async_data_case_test.exs")
  end

  test "the detector ignores sync DataCase uses and async non-DataCase tests" do
    source = """
    defmodule Fixture.SyncDataCase do
      use Samen.WebTest.DataCase, async: false
    end

    defmodule Fixture.AsyncPlainCase do
      use ExUnit.Case, async: true
    end
    """

    assert [%{module: Samen.WebTest.DataCase, async: false}] =
             scan_source!(source, "fixture/sync_data_case_test.exs")
  end

  test "the detector reads the AST, not comments or string literals" do
    source = """
    # use Samen.WebTest.DataCase, async: true
    defmodule Fixture.DocOnly do
      @moduledoc "use Samen.WebTest.DataCase, async: true"
    end
    """

    assert scan_source!(source, "fixture/doc_only_test.exs") == []
  end

  defp test_files, do: Path.wildcard(@test_glob)

  defp scan_file!(path), do: path |> File.read!() |> scan_source!(path)

  defp scan_source!(source, file) do
    ast = Code.string_to_quoted!(source, file: file)

    {_ast, uses} =
      Macro.prewalk(ast, [], fn
        {:use, meta, [{:__aliases__, _, parts}, opts]} = node, acc ->
          if Enum.all?(parts, &is_atom/1) do
            module = Module.concat(parts)

            if data_case_module?(module) do
              async =
                is_list(opts) and Keyword.keyword?(opts) and
                  Keyword.get(opts, :async, false) == true

              {node, [%{file: file, line: meta[:line], module: module, async: async} | acc]}
            else
              {node, acc}
            end
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(uses)
  end

  defp data_case_module?(module) do
    module |> Module.split() |> List.last() == "DataCase"
  end

  defp offender_line(%{file: file, line: line, module: module}) do
    "  #{Path.relative_to(file, @repo_root)}:#{line} uses #{inspect(module)} with async: true"
  end
end
