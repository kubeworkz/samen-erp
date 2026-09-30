defmodule Samen.Delivery.RedactTest do
  @moduledoc """
  Layer-2 credential scrub (2026-09-30 incident): delivery error terms must
  never carry a credential-shaped string into a Logger line or crash report.
  """

  use ExUnit.Case, async: true

  alias Samen.Delivery.Redact

  describe "scrub/1 — credential-shaped strings" do
    test "redacts a Resend-shaped key embedded in an error message (token-level: prose survives)" do
      assert Redact.scrub("Bearer re_abc123def456ghij") == "Bearer [REDACTED]"
      assert Redact.scrub("key was re_abc123def456ghij in config") ==
               "key was [REDACTED] in config"
    end

    test "redacts other distinctive ESP prefixes (token-level)" do
      assert Redact.scrub("sig whsec_Ab12Cd34Ef56Gh78 rejected") == "sig [REDACTED] rejected"
      assert Redact.scrub("key sk_live_abc123def456") == "key [REDACTED]"
      assert Redact.scrub("aws AKIAIOSFODNN7EXAMPLE denied") == "aws [REDACTED] denied"
    end

    test "does NOT redact word-interior collisions (the \\b anchor)" do
      # "pre_shared…": the "re_" inside is not at a word boundary.
      assert Redact.scrub("pre_shared_secret_mismatch") == "pre_shared_secret_mismatch"
      # "task_…": the "sk_" inside is not at a word boundary.
      assert Redact.scrub("task_skipping_inline_change") == "task_skipping_inline_change"
      # Honest prose with a short key-ish tail survives.
      assert Redact.scrub("failed to re_authenticate the session") ==
               "failed to re_authenticate the session"
    end

    test "short tails under the entropy floor survive" do
      assert Redact.scrub("re_auth flow") == "re_auth flow"
    end
  end

  describe "scrub/1 — structural recursion" do
    test "scrubs deep inside tuples, maps, and lists (token-level)" do
      term = {:resend_error, 422, %{"debug" => ["x re_abc123def456ghij y"], "status" => 422}}

      assert Redact.scrub(term) ==
               {:resend_error, 422, %{"debug" => ["x [REDACTED] y"], "status" => 422}}
    end

    test "leaves atoms, numbers, and unknown structs untouched" do
      assert Redact.scrub(:timeout) == :timeout
      assert Redact.scrub(422) == 422
      assert Redact.scrub(~U[2026-09-30 00:00:00Z]) == ~U[2026-09-30 00:00:00Z]
    end

    test "does not mutate the input term" do
      term = %{"k" => "re_abc123def456ghij"}
      Redact.scrub(term)
      assert term["k"] == "re_abc123def456ghij"
    end
  end
end
