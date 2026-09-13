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
  non-draft row UNLESS the transaction-local marker
  (`Samen.Scopes.Finance.PostingMarker`, shared with the E2 document posting
  guards) is present — which only the actions carrying THIS change can set. A
  raw-SQL posted row is refused; a raw-SQL edit of a posted row is refused.

  Paired with `Samen.Scopes.Finance.PostBalance` (the persisted-lines R1
  re-check that runs before this write on `:post`/`:void`) and
  `Samen.Scopes.Finance.VoidGuard` (the linked reversing entry).
  """
  use Ash.Resource.Change

  alias Samen.Scopes.Finance.PostingMarker

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    status =
      case action do
        :void -> :void
        _ -> :posted
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The marker's PRIOR value, read at changeset-build time and restored after
    # the write — the shared `PostingMarker` change owns the arm/restore pair
    # with the nested-posting-safe prior-value semantics (E2's document posting
    # guards use the same module). At build time no other writer of this GUC
    # can be in flight: the only nested action (:void's inner
    # :create_reversal) is BUILT during the outer action's before_action —
    # i.e. after the outer arm — so its own build-time read sees the armed
    # outer marker and restores it faithfully.
    changeset
    |> PostingMarker.change([], %{})
    |> Ash.Changeset.before_action(fn changeset ->
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

      changeset
      |> Ash.Changeset.force_change_attribute(:status, status)
      |> Ash.Changeset.force_change_attribute(:posted_at, now)
    end)
  end
end
