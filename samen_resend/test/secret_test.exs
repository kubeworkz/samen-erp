defmodule SamenResend.SecretTest do
  @moduledoc """
  The 2026-09-30 redaction contract: a credential wrapped in %Secret{} must
  never render its value through ANY dump path (Inspect), and the transport
  must unwrap it explicitly. The interpolation trap is asserted as a RAISE —
  the live transport regression (String.Chars crash on a Secret embedded in
  a string build) must be impossible to reintroduce silently.
  """

  use ExUnit.Case, async: true

  alias SamenResend.Secret

  test "wrap/unwrap round-trips the credential" do
    assert "re_abc" == Secret.wrap("re_abc") |> Secret.unwrap()
  end

  test "unwrap/1 is idempotent at the boundary (plain binary passes through)" do
    assert Secret.unwrap("re_plain") == "re_plain"
  end

  test "wrap/1 rejects empty and non-binary credentials" do
    assert_raise FunctionClauseError, fn -> Secret.wrap("") end
    assert_raise FunctionClauseError, fn -> Secret.wrap(42) end
  end

  test "Inspect renders [REDACTED], never the value" do
    refute inspect(Secret.wrap("re_SUPER_SECRET_123456")) =~ "re_SUPER_SECRET"
    assert inspect(Secret.wrap("re_SUPER_SECRET_123456")) =~ "[REDACTED]"
  end

  test "interpolation RAISES (no String.Chars) instead of silently leaking" do
    assert_raise Protocol.UndefinedError, fn ->
      "Bearer #{Secret.wrap("re_SUPER_SECRET_123456")}"
    end
  end
end
