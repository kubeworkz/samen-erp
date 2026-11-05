defmodule Samen.Scopes.Finance.GrantReconcile do
  @moduledoc """
  R11 — the grant ↔ fund reconciliation (WS-ACCT Phase 11; ADR-054 R11).

  Per grant, `Samen.Scopes.Finance.GrantCompliance.statement/3` derives:

    * the schedule's recognized revenue (Σ recognitions);
    * the fund's income-account movement over POSTED, fund-dimensioned lines;
    * the approved claims;
    * the incurred allowable cost across the grant's term.

  The invariant holds when the first three agree and recognized revenue never
  exceeds incurred cost. `divergences/3` is the non-vacuity arm: a single
  mismatch is returned with its `issues`, never folded into an org-wide
  "balanced" boolean. A divergence is a broken grant spine, not a rounding
  opinion.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.GrantCompliance

  @doc "Every grant's R11 state. `opts`: `:grant` plus the statement modules."
  def states(org_id, repo, opts) do
    grant_mod = Keyword.fetch!(opts, :grant)

    grants =
      grant_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(award_ref: :asc)
      |> Ash.read!(authorize?: false)

    {:ok, Enum.map(grants, &GrantCompliance.statement(&1, repo, opts))}
  end

  @doc "The grants whose three R11 legs disagree."
  def divergences(org_id, repo, opts) do
    with {:ok, states} <- states(org_id, repo, opts) do
      {:ok, Enum.reject(states, & &1.balanced?)}
    end
  end

  @doc "`{:ok, true | false, divergences}` — the R11 verdict and its evidence."
  def reconciled?(org_id, repo, opts) do
    case divergences(org_id, repo, opts) do
      {:ok, []} -> {:ok, true, []}
      {:ok, divergences} -> {:ok, false, divergences}
    end
  end
end
