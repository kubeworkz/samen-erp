defmodule Samen.Scopes.Finance.PostingMarker do
  @moduledoc """
  The transaction-local posting marker, shared by every Finance posting writer
  (WS-ERP E1 + E2; ADR-049 §2).

  The DB-level belts (the fixture migrations' triggers) refuse any write that
  lands a non-draft state — a posted `JournalEntry`, a line into a posted
  entry, an approved/paid `ApInvoice` — UNLESS the transaction-local
  `samen.finance_posting` marker is present. Only actions carrying a
  marker-arming change can pass those belts, so a raw-SQL fact is structurally
  impossible while the sanctioned cascades stay real writes.

  * `change/2` arms the marker in `before_action` and RESTORES THE PRIOR VALUE
    in `after_action` — the restore is not a blind `'off'` because nested
    postings (`:void`'s inner reversal, E2's Gate re-invocation) run INSIDE an
    already-armed outer transaction, and the inner restore must leave the
    outer arm intact. Production transactions END the GUC at commit/rollback,
    but the SQL sandbox runs whole TESTS in one transaction with no
    savepoint isolation — without the restore the marker would outlive the
    action and the belt would refuse nothing for the rest of the test
    (`'off'` ≡ unset for the belt: the trigger COALESCEs).
  * `arm_now/1` arms the marker mid-transaction for system cascades that build
    their own changesets (E2's posting guards) and are NOT resource actions of
    their own — it returns the PRIOR value for the matching `restore/2`.
  * `guc/0` is the single source of truth for the GUC name (the migration
    triggers repeat it literally — SQL cannot call Elixir).
  """

  use Ash.Resource.Change

  @guc "samen.finance_posting"

  @doc "The GUC name the migration belts check. Single source of truth."
  def guc, do: @guc

  @impl true
  def change(changeset, _opts, _context) do
    repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)
    prior = current(repo)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      if repo, do: repo.query!("SELECT set_config('#{@guc}', 'on', true)", [])

      changeset
    end)
    |> Ash.Changeset.after_action(fn _changeset, result ->
      restore(repo, prior)

      {:ok, result}
    end)
  end

  @doc """
  Arm the marker on `repo` for the CURRENT transaction (transaction-scoped —
  the `true` in `set_config`). For system cascades that are not resource
  actions of their own; returns the PRIOR marker value — pass it to `restore/2`
  (nested arms must restore the prior value, never a blind 'off').
  """
  def arm_now(nil), do: "off"

  def arm_now(repo) do
    prior = current(repo)
    repo.query!("SELECT set_config('#{@guc}', 'on', true)", [])
    prior
  end

  @doc "Restore the marker to `value` ('off' ≡ unset — the belt COALESCEs)."
  def restore(nil, _value), do: :ok

  def restore(repo, value) when is_binary(value) do
    repo.query!("SELECT set_config('#{@guc}', '#{value}', true)", [])
    :ok
  end

  @doc "Read the marker's current value ('off' ≡ unset)."
  def current(nil), do: "off"

  def current(repo) do
    case repo.query!("SELECT current_setting('#{@guc}', true)", []).rows do
      [[value]] when is_binary(value) -> value
      _ -> "off"
    end
  end
end
