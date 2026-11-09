defmodule Samen.BankingRecognizeTest do
  use ExUnit.Case, async: true

  alias Samen.Scopes.Banking.Recognize

  test "ranks a posted cash-leg candidate using total_cents and a DateTime statement date" do
    line = %{
      amount_cents: -5_000,
      posted_at: ~U[2026-10-01 00:00:00Z],
      description: "Coffee Shop"
    }

    entry = %{
      status: :posted,
      total_cents: -5_000,
      entry_date: ~D[2026-10-01],
      memo: "Coffee Shop"
    }

    assert [candidate] = Recognize.find_candidates(line, [entry])
    assert candidate.confidence == 1.0
    assert candidate.amount_cents == -5_000
    assert candidate.reason == "Exact amount match on same date"
  end

  test "falls back to summing entry lines when total_cents is absent" do
    line = %{
      amount_cents: -5_000,
      posted_at: ~U[2026-10-01 00:00:00Z],
      description: "Coffee Shop"
    }

    entry = %{
      status: :posted,
      entry_date: ~D[2026-10-01],
      memo: "Coffee Shop",
      lines: [%{debit_cents: 0, credit_cents: 5_000}]
    }

    assert [candidate] = Recognize.find_candidates(line, [entry])
    assert candidate.confidence == 1.0
  end
end
