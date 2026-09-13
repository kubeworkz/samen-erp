defmodule Samen.Scopes.Finance.PostGuard do
  @moduledoc """
  The posting write (WS-ERP E1; ADR-049 §2): stamps `status` + `posted_at` as a
  SYSTEM-level attribute write — never caller-supplied.

  * `:post`            → `status: :posted`
  * `:void`            → `status: :void`
  * `:create_reversal` → `status: :posted` (VoidGuard's internal factory)

  The draft-edit (`:update`) action's inputs CANNOT carry `status`/`posted_at`
  (they are not accepted there), so the only route to `:posted` is `:post`, the
  only route to `:void` is `:void`. The transitions are ONE-WAY: `:post` runs
  only on a `:draft` row and `:void` only on a `:posted` row (a re-post or a
  void-of-a-void is refused — the state machine has no backward edges).

  DB-level immutability is the migration's trigger (belt over this braces): the
  entry table refuses an INSERT of a non-draft row and an UPDATE/DELETE of a
  non-draft row UNLESS this change's transaction-local marker
  (`samen.finance_posting`, set via `set_config(..., true)` — transaction-
  scoped, auto-cleared at commit/rollback) is present — which only the actions
  carrying THIS change can set. A raw-SQL posted row is refused; a raw-SQL edit
  of a posted row is refused.

  Paired with `Samen.Scopes.Finance.PostBalance` (the persisted-lines R1
  re-check that runs before this write on `:post`/`:void`) and
  `Samen.Scopes.Finance.VoidGuard` (the linked reversing entry).
  """
  use Ash.Resource.Change

  @guc "samen.finance_posting"

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    status =
      case action do
        :void -> :void
        _ -> :posted
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

    # The marker's PRIOR value, read at changeset-build time and restored after
    # the write (see the after_action below for why the restore is not a blind
    # 'off'). At build time no other writer of this GUC can be in flight: the
    # only nested action (:void's inner :create_reversal) is BUILT during the
    # outer action's before_action — i.e. after the outer arm — so its own
    # build-time read sees the armed outer marker and restores it faithfully.
    prior = guc_value(repo)

    Ash.Changeset.before_action(changeset, fn changeset ->
      # One-way state machine: :post leaves :draft, :void leaves :posted. A
      # re-post (posted_at would move on an immutable fact) and a
      # void-of-a-void are refused here, before any row is written.
      # get_attribute/2 (not changeset.data) — on the :create_reversal CREATE
      # changeset `data` carries no cast status; the safe accessor reads data
      # OR the pending change/default.
      current_status = Ash.Changeset.get_attribute(changeset, :status) || :draft

      legal? =
        case action do
          :void -> current_status == :posted
          :post -> current_status == :draft
          _ -> true
        end

      unless legal? do
        Ash.Changeset.add_error(changeset,
          field: :status,
          message:
            "illegal #{action} transition: the entry is #{current_status} — :post runs on a " <>
              ":draft and :void on a :posted entry (one-way state machine)"
        )
      end

      # Transaction-local marker: the DB trigger's ONLY escape hatch for a
      # non-draft INSERT/UPDATE, and it exists solely on the actions carrying
      # this change. Transaction-scoped (the `true` in set_config).
      if repo, do: repo.query!("SELECT set_config('#{@guc}', 'on', true)", [])

      changeset
      |> Ash.Changeset.force_change_attribute(:status, status)
      |> Ash.Changeset.force_change_attribute(:posted_at, now)
    end)
    # Restore the PRIOR marker on the success path: production transactions
    # END the GUC at commit/rollback, but the SQL sandbox runs whole TESTS in
    # one transaction (no savepoint isolation) — without a restore the marker
    # would outlive the action and the belt would refuse nothing for the rest
    # of the test. Restoring the prior value (NOT blindly 'off') is load-
    # bearing for :void: its inner :create_reversal runs INSIDE the outer arm,
    # so the inner restore must leave the outer marker armed for the void's
    # own non-draft UPDATE. ('off' ≡ unset for the belt — it COALESCEs.)
    |> Ash.Changeset.after_action(fn _changeset, result ->
      if repo, do: repo.query!("SELECT set_config('#{@guc}', '#{prior}', true)", [])

      {:ok, result}
    end)
  end

  defp guc_value(nil), do: "off"

  defp guc_value(repo) do
    case repo.query!("SELECT current_setting('#{@guc}', true)", []).rows do
      [[value]] when is_binary(value) -> value
      _ -> "off"
    end
  end
end
