defmodule Driftwood.ReplayDevOnlyTest do
  use ExUnit.Case, async: true

  # WS-Masked-Replay P0 gate (docs/ws-masked-replay/build-plan.md).
  #
  # The `phoenix_replay` probe records RAW assigns and form values. On this foundry a tenant
  # LiveView's assigns are already PII-resolved plaintext, so the probe is acceptable only as a
  # dev tool and must be structurally impossible to reach in a deployed environment. These are
  # the three absences that make that true, plus the positive control that it IS enabled in dev
  # (an "always off" config would pass the first three tests and deliver nothing).

  test "the phoenix_replay dependency is absent from a non-dev build" do
    assert Application.spec(:phoenix_replay) == nil
  end

  test "the dev-only dashboard router is not compiled outside :dev" do
    refute Code.ensure_loaded?(DriftwoodWeb.DevReplayRouter)
  end

  test "the route table contains no replay route" do
    paths = DriftwoodWeb.Router.__routes__() |> Enum.map(& &1.path)

    assert paths != [], "an empty route table would make the assertion below vacuous"
    refute Enum.any?(paths, &String.starts_with?(&1, "/dev/replay"))
  end

  test "the probe is enabled by dev config alone" do
    assert File.read!("config/dev.exs") =~ "dev_replay_dashboard: true"

    for path <- ~w(config/config.exs config/test.exs config/prod.exs) do
      contents = File.read!(path)

      refute contents =~ "dev_replay_dashboard",
             "#{path} must not switch the engine-only replay probe on"

      refute contents =~ "phoenix_replay",
             "#{path} must not configure a dev-only dependency"
    end
  end
end
