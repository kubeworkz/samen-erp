defmodule Samen.Scopes.Inventory.ReleaseWo do
  @moduledoc """
  The WorkOrder release cascade (WS-ERP E6; design §4): on `:release`, the
  referenced BOM is SNAPSHOT-FROZEN into the order — per BomLine, the
  component item and its EXPANDED per-WO quantity
  (ceil(qty_per × (1 + scrap_pct/100) × wo_qty) — and the BOM's version —
  written into the order's bounded `bom_snapshot` jsonb and `bom_version`.

  Why a snapshot at all: WIP never re-prices. From release onward, the
  order's economics are the frozen bill — a later BOM edit (a new version)
  cannot reach an in-flight order, and `:complete` posts against the
  snapshot, never a live read. The unit COSTS are deliberately NOT
  captured here: the facade prices consumption at completion time (the
  rollup's moving average then — the same read-your-writes discipline as
  the E5 bridge).

  The run is fail-honest BEFORE any flip: a BOM with no lines (cannot
  happen through the sanctioned path, but a data error is still refused),
  and the cost-snapshot feasibility note is deferred to `:complete` (the
  moving average is read THERE, fail-honest).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    org_id = resolve_org(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_release(changeset, org_id, opts)
    end)
  end

  defp do_release(changeset, org_id, opts) do
    bom_line_resource = Keyword.fetch!(opts, :bom_line)
    bom_resource = Keyword.fetch!(opts, :bom)
    wo = changeset.data

    with {:ok, lines} <- bom_lines(bom_line_resource, org_id, wo),
         # The AUDIT stamp is the BOM's CURRENT version — read off the
         # referenced bill (the snapshot jsonb is the binding contract).
         {:ok, bom_version} <- bom_version(bom_resource, wo) do
      snapshot =
        Enum.map(lines, fn line ->
          per_unit = ceil(line.qty_per * (1 + line.scrap_pct / 100) * wo.qty)

          %{
            "component_item_id" => line.item_id,
            "qty_per" => line.qty_per,
            "qty" => per_unit
          }
        end)

      # before_action hooks return the BARE changeset. The cascade owns its
      # flip (the ProduceWo discipline — the cascade stamps its own state).
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :released)
      |> Ash.Changeset.force_change_attribute(:bom_snapshot, snapshot)
      |> Ash.Changeset.force_change_attribute(:bom_version, bom_version)
      |> Ash.Changeset.force_change_attribute(
        :released_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the work order cannot be released: #{format(reason)}"
        )
    end
  end

  defp bom_version(bom_resource, wo) do
    case Ash.get(bom_resource, wo.bom_id, authorize?: false) do
      {:ok, bom} -> {:ok, bom.version}
      {:error, reason} -> {:error, {:bom_read_failed, reason}}
    end
  end

  defp bom_lines(bom_line_resource, org_id, wo) do
    require Ash.Query

    case bom_line_resource
         |> Ash.Query.filter(bom_id == ^wo.bom_id and org_id == ^org_id)
         |> Ash.read(authorize?: false) do
      {:ok, []} -> {:error, :no_lines}
      {:ok, lines} -> {:ok, Enum.sort_by(lines, & &1.id)}
      {:error, reason} -> {:error, {:lines_read_failed, reason}}
    end
  end

  defp format(:no_lines),
    do: "the BOM carries no lines — a bill without components is a data error"

  defp format({:bom_read_failed, reason}),
    do: "the referenced BOM could not be read for the version stamp: #{inspect(reason)}"

  defp format({:lines_read_failed, reason}),
    do: "the BOM's line read failed: #{inspect(reason)}"

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp resolve_org(changeset) do
    require Ash.Query

    case Ash.Changeset.get_attribute(changeset, :org_id) do
      value when is_binary(value) ->
        value

      _ ->
        changeset.resource
        |> Ash.Query.filter(id == ^changeset.data.id)
        |> Ash.Query.select(:org_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, %{org_id: org_id}} -> org_id
          other -> raise "the WO's org could not be resolved: #{inspect(other)}"
        end
    end
  end
end
