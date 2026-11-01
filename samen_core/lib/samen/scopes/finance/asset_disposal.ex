defmodule Samen.Scopes.Finance.AssetDisposal do
  @moduledoc """
  The one-way disposal of an `Asset` (WS-ACCT Phase 8; ADR-054 D9).

  `:dispose` takes a `disposed_on` argument and does exactly two things: it
  records the date and moves `status` to `:disposed`. It deliberately posts NO
  gain/loss entry and NO catch-up depreciation — retiring a costed asset for
  proceeds or scrap is a separate accounting fact (a disposal entry a human
  raises), and inventing a write-off here would put an estimate in the GL under
  the register's name. The run simply stops scheduling from the disposal month
  onward; the months already posted stay posted.

  Refusals, all inside the update's transaction:

    * disposing an already-disposed asset (the transition is one-way; there is
      no `:undispose`, because un-retiring an asset is not a data edit);
    * a disposal dated before `acquired_on` (the asset did not exist yet);
    * a missing date.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    asset = changeset.data
    on = Ash.Changeset.get_argument(changeset, :disposed_on)

    cond do
      asset.status == :disposed ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message:
            "asset #{asset.code} is already disposed (#{Date.to_iso8601(asset.disposed_on)}) — " <>
              "a disposal is one-way; a correction is a journal entry, not an un-disposal"
        )

      is_nil(on) ->
        Ash.Changeset.add_error(changeset,
          field: :disposed_on,
          message: "a disposal must be dated"
        )

      Date.compare(on, asset.acquired_on) == :lt ->
        Ash.Changeset.add_error(changeset,
          field: :disposed_on,
          message:
            "the disposal date (#{Date.to_iso8601(on)}) is before the acquisition " <>
              "(#{Date.to_iso8601(asset.acquired_on)}) — an asset cannot be retired before it exists"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :disposed)
        |> Ash.Changeset.force_change_attribute(:disposed_on, on)
    end
  end
end
