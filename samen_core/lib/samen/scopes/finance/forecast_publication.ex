defmodule Samen.Scopes.Finance.ForecastPublication do
  @moduledoc """
  The lifecycle guard for a `ForecastVersion` (WS-ACCT Phase 14; ADR-054 D11).

  `:publish` is the only transition out of `:draft`, and it is one-way. Once a
  version is published it has **no** update, archive or delete path: a
  re-forecast is a NEW version (`:roll`), never an edit to the version a
  reader may already have used. `:archive` exists only for a draft that is
  abandoned before publication; a published version stays published forever,
  which is what makes the append-only promise enforceable rather than a
  convention.

  The check runs as a changeset change (before attribute validation), so the
  `status` column is never caller input and a second publish cannot slip
  through.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    op = Keyword.fetch!(opts, :op)
    status = changeset.data.status

    case {op, status} do
      {:publish, :draft} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :published)
        |> Ash.Changeset.force_change_attribute(:published_at, now())

      {:archive, :draft} ->
        Ash.Changeset.force_change_attribute(changeset, :status, :archived)

      {:publish, :published} ->
        error(
          changeset,
          "this forecast version is already PUBLISHED — publication is one-way. " <>
            "Roll a new version instead of editing a published forecast."
        )

      {:publish, :archived} ->
        error(
          changeset,
          "an archived draft cannot be published; create a new forecast version instead"
        )

      {:archive, :published} ->
        error(
          changeset,
          "a PUBLISHED forecast version is immutable and cannot be archived. " <>
            "Roll a new version; the published record stays as it was read."
        )

      {:archive, _} ->
        error(changeset, "only a draft forecast version can be archived")
    end
  end

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :status, message: message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
