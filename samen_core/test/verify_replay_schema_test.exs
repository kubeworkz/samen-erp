defmodule Mix.Tasks.Samen.Verify.ReplaySchemaTest do
  @moduledoc """
  Lane B P1 — end-to-end exit-code tests for the masked-replay schema gate
  (`mix samen.verify.replay_schema`).

  The declaration and behavioural checks are unit-tested in `replay_frame_schema_test.exs`; this
  file proves the FAIL-CLOSED behaviour at the PROCESS boundary (`:erlang.halt/1`) — the only way
  to observe the real exit code — via `System.cmd/3` in a child OS process.

  The red path seeds a frame kind with no payload key policy through the task's documented test
  seam (`SAMEN_REPLAY_SCHEMA_INJECT_KIND_WITHOUT_POLICY`), so it exercises the WHOLE pipeline —
  declaration check → violation record → FAIL report → exit 1 — without mutating the real schema.
  A task that exited 0 whatever it found would pass the green case and fail here, which is the
  point of asserting both sides.
  """
  use ExUnit.Case, async: false

  @project_dir File.cwd!()

  @tag :exit_code
  test "exits 0 on the real schema" do
    {output, exit_code} =
      System.cmd("mix", ["samen.verify.replay_schema"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "Expected exit 0 on the clean schema, got #{exit_code}.\nOutput: #{output}"
    assert output =~ "OK", "Expected the OK banner, got: #{output}"
  end

  @tag :exit_code
  test "RED PATH: exits 1 with a frame kind that has no payload key policy" do
    {output, exit_code} =
      System.cmd("mix", ["samen.verify.replay_schema"],
        cd: @project_dir,
        env: [
          {"MIX_ENV", "test"},
          {"SAMEN_REPLAY_SCHEMA_INJECT_KIND_WITHOUT_POLICY", "ghost_kind"}
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 1,
           "Expected exit 1 on an uncovered frame kind, got #{exit_code}.\nOutput: #{output}"

    assert output =~ "FAIL", "Expected the FAIL report, got: #{output}"
    assert output =~ "ghost_kind", "Expected the offending kind in output, got: #{output}"
    assert output =~ "payload key policy", "Expected the kind-coverage diagnostic, got: #{output}"
  end

  @tag :exit_code
  test "RED PATH: refuses an unsupported --format rather than quietly printing text" do
    {output, exit_code} =
      System.cmd("mix", ["samen.verify.replay_schema", "--format", "yaml"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 1, "Expected exit 1 on --format yaml, got #{exit_code}.\nOutput: #{output}"
    assert output =~ "--format" and output =~ "yaml"
  end
end
