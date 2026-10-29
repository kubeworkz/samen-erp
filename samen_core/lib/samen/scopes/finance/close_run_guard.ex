defmodule Samen.Scopes.Finance.CloseRunGuard do
  @moduledoc """
  The `CloseRun` checklist lifecycle (WS-ACCT Phase 3; ADR-054 D7):

    * `op: :seed` — on `:start`, copies `Samen.Scopes.Finance.ClosePhases.seeded/0`
      onto the row and stamps `started_at`. The phases are never caller input:
      the doc's ten are the checklist, and a caller inventing an eleventh would
      be editing the close policy through a create argument.
    * `op: :complete_phase` — the `:complete_phase` action's `phase` argument
      (a key from `ClosePhases.keys/0`) gets `done_at`. An UNKNOWN key is
      refused fail-honest rather than appended (a typo must not silently create
      a phase nobody checks); re-completing an already-done phase is a no-op, so
      a retried click is not an error.
    * `op: :finish` — `:in_progress → :completed`, one-way (the
      `PeriodTransition` posture), and only when EVERY phase is done. A run
      marked complete with a phase outstanding would be a close certificate that
      certifies nothing.

  A completed run is final: `:complete_phase` and `:finish` both refuse on it, so
  the checklist cannot be rewritten after the close it describes was signed.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    op = Keyword.fetch!(opts, :op)
    Ash.Changeset.before_action(changeset, &apply_op(&1, op))
  end

  defp apply_op(changeset, :seed) do
    changeset
    |> Ash.Changeset.force_change_attribute(:phases, Samen.Scopes.Finance.ClosePhases.seeded())
    |> Ash.Changeset.force_change_attribute(:started_at, now())
  end

  defp apply_op(changeset, :complete_phase) do
    key = Ash.Changeset.get_argument(changeset, :phase)
    phases = phases(changeset)

    cond do
      current_status(changeset) == :completed ->
        error(changeset, "this close run is COMPLETED — its checklist is a signed fact and " <>
          "cannot be edited. Start the next period's run instead.")

      Samen.Scopes.Finance.ClosePhases.fetch(key) == nil ->
        error(changeset, "unknown close phase #{inspect(key)} — the checklist is the source " <>
          "manual's ten phases (see Samen.Scopes.Finance.ClosePhases.keys/0)")

      true ->
        Ash.Changeset.force_change_attribute(changeset, :phases, mark_done(phases, key))
    end
  end

  defp apply_op(changeset, :finish) do
    phases = phases(changeset)

    cond do
      current_status(changeset) == :completed ->
        error(changeset, "illegal close-run transition: the run is already COMPLETED " <>
          "(the run is one-way — in_progress → completed)")

      pending(phases) != [] ->
        error(changeset, "the close run cannot be completed while #{length(pending(phases))} " <>
          "phase(s) are still open: #{Enum.join(pending(phases), ", ")}. Complete every phase " <>
          "or leave the run in progress — a close certificate with phases outstanding would " <>
          "certify nothing.")

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :completed)
        |> Ash.Changeset.force_change_attribute(:completed_at, now())
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp mark_done(phases, key) do
    Enum.map(phases, fn phase ->
      if get(phase, "key") == key and get(phase, "done_at") == nil do
        put(phase, "done_at", DateTime.to_iso8601(now()))
      else
        phase
      end
    end)
  end

  defp pending(phases) do
    phases
    |> Enum.filter(&(get(&1, "done_at") == nil))
    |> Enum.map(&get(&1, "key"))
  end

  defp phases(changeset) do
    case Ash.Changeset.get_attribute(changeset, :phases) do
      list when is_list(list) -> list
      _ -> Map.get(changeset.data, :phases) || []
    end
  end

  defp current_status(changeset) do
    case Ash.Changeset.get_attribute(changeset, :status) do
      %Ash.NotLoaded{} -> Map.get(changeset.data, :status)
      nil -> Map.get(changeset.data, :status)
      status -> status
    end
  end

  # The stored maps come back from jsonb with STRING keys; the seeded ones are
  # string-keyed too, so one accessor covers both.
  defp get(phase, key) when is_map(phase) do
    Map.get(phase, key) || Map.get(phase, safe_atom(key))
  end

  defp get(_phase, _key), do: nil

  defp put(phase, key, value) when is_map(phase) do
    phase
    |> Map.put(key, value)
    |> Map.drop([safe_atom(key)])
  end

  defp safe_atom("key"), do: :key
  defp safe_atom("done_at"), do: :done_at
  defp safe_atom(_), do: :__never__

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
