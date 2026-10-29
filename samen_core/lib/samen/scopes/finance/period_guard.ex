defmodule Samen.Scopes.Finance.PeriodGuard do
  @moduledoc """
  The **R10 posting gate** (WS-ACCT Phase 3; ADR-054 D7): an entry may not be
  *posted* into a fiscal period that is closed, and may not be posted into a
  soft-closed period unless it is a journal-only close adjustment.

  ## The three states

    * **`nil` (no period row)** — OPEN. A host that never opens a fiscal period
      behaves exactly as before this phase existed; the guard adds no obligation
      anywhere. This is what keeps every base-system posting (AP, AR, stock,
      sales) unchanged on every mount.
    * **`:open`** — admitted.
    * **`:soft_closed`** — refused when the post carries a **document** source
      anchor, admitted when it does not. The close checklist's Days 1–7 need the
      document window shut before the adjustment window is (design D7): no new
      bills or receipts land, but the close's own journal-only corrections do.
    * **`:closed`** — refused, always. R10 is absolute: no posted entry may be
      dated inside a closed period.

  ## What counts as a document anchor

  `source_key`/`source_id` is the ADR-041 object-ref seam: `"ap_invoice"`,
  `"goods_receipt"`, `"billing_payment"`, … — an upstream DOCUMENT that is
  landing in the ledger. The ledger's own reversal anchor (`"journal_entry"`,
  written by `Samen.Scopes.Finance.VoidGuard`) is **not** a document: it
  corrects an entry the ledger already holds, which is exactly the "journal-only
  adjustment" soft-close exists to admit. Without that distinction a void of any
  soft-closed entry would be refused even though nothing new is arriving.

  ## Where it runs

  On every action that lands a POSTED row, because that is the set R10 quantifies
  over — not on drafts (a draft is not a fact, and a draft dated in a closed
  period can simply never be posted):

    * `JournalEntry.:post` — the ordinary path;
    * `JournalEntry.:create_reversal` — the posted-born internal factory that AP
      approval, the stock-receipt bridge, the sales bridge and VoidGuard all use,
      so one change covers every document posting in the tree;
    * `JournalEntry.:void` — refused up front with a message naming the period,
      rather than surfacing as a reversal-creation failure halfway through the
      action (the reversal is dated the original's date, so it could never land
      in a closed period anyway).

  ## Belt and braces

  The Ash guard is the braces; the migration's trigger is the belt — a posted
  row dated inside a closed period is refused at the DATABASE, marker or no
  marker, so a raw-SQL write cannot forge one either. The read mirror
  (`Samen.Scopes.Finance.PeriodReconcile`) independently detects any row that
  got in below both; the suite's anti-tautology leg forces exactly such a row to
  prove the detector is not decoration.
  """

  use Ash.Resource.Change

  # The ledger's own reversal anchor: an adjustment to a fact already held, not
  # a document landing in the book (see the moduledoc).
  @ledger_internal_sources ["journal_entry"]

  @doc "Source anchors that are ledger adjustments rather than upstream documents."
  def ledger_internal_sources, do: @ledger_internal_sources

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &check(&1, opts))
  end

  defp check(changeset, opts) do
    period_resource = Keyword.fetch!(opts, :period)

    with {:ok, org_id} <- org_id(changeset),
         {:ok, entry_date} <- fetch(changeset, :entry_date),
         {:ok, status} <- period_status(period_resource, org_id, entry_date) do
      case status do
        nil -> changeset
        :open -> changeset
        :soft_closed -> soft_closed(changeset, entry_date)
        :closed -> error(changeset, closed_message(entry_date))
        other -> error(changeset, unknown_status_message(other))
      end
    else
      # No org/date yet (a create changeset still carrying defaults) — nothing
      # to look up; the action's own required attributes refuse it.
      :error -> changeset
      {:period_error, message} -> error(changeset, message)
    end
  end

  defp soft_closed(changeset, entry_date) do
    if document_sourced?(changeset) do
      error(
        changeset,
        "the fiscal period containing #{Date.to_iso8601(entry_date)} is SOFT-CLOSED: " <>
          "documents may no longer land in it (the AP/AR/stock window is shut while the " <>
          "close's journal adjustments stay open). Post the document into an open period, " <>
          "or record a journal-only adjustment (no source document)."
      )
    else
      changeset
    end
  end

  defp document_sourced?(changeset) do
    case fetch(changeset, :source_key) do
      {:ok, key} when is_binary(key) and key != "" ->
        key not in @ledger_internal_sources

      _ ->
        false
    end
  end

  defp closed_message(entry_date) do
    "the fiscal period containing #{Date.to_iso8601(entry_date)} is CLOSED — a posted " <>
      "entry may not be dated inside a closed period (R10). Post into an open period " <>
      "instead: a closed period's figures are a published fact, so a late adjustment " <>
      "belongs in the period that is still open."
  end

  defp unknown_status_message(other) do
    "the fiscal period's status #{inspect(other)} is not one of :open/:soft_closed/:closed — " <>
      "refusing the posting rather than guessing (fail-closed)."
  end

  # ── the period lookup ──────────────────────────────────────────────────────

  defp period_status(period_resource, org_id, %Date{year: year, month: month}) do
    table = AshPostgres.DataLayer.Info.table(period_resource)
    repo = AshPostgres.DataLayer.Info.repo(period_resource, :read)

    org_col = attr_source(period_resource, :org_id)
    year_col = attr_source(period_resource, :year)
    month_col = attr_source(period_resource, :month)
    status_col = attr_source(period_resource, :status)

    sql = """
    SELECT #{status_col}::text FROM #{table}
    WHERE #{org_col} = $1::uuid AND #{year_col} = $2 AND #{month_col} = $3
    LIMIT 1
    """

    case repo.query(sql, [dump_uuid(org_id), year, month]) do
      {:ok, %{rows: [[status]]}} when is_binary(status) -> {:ok, status_atom(status)}
      {:ok, %{rows: []}} -> {:ok, nil}
      # FAIL CLOSED: a period table the guard cannot read is not "open". A
      # broken lookup must refuse the posting rather than wave it through —
      # otherwise a schema drift (or a restore mid-close) silently disables R10.
      {:error, reason} ->
        {:period_error,
         "the fiscal period of #{Date.to_iso8601(%Date{year: year, month: month, day: 1})} " <>
           "could not be read, so the posting is refused rather than guessed: " <>
           "#{inspect(reason)}"}
    end
  end

  defp period_status(_period_resource, _org_id, _date), do: {:ok, nil}

  defp status_atom("closed"), do: :closed
  defp status_atom("soft_closed"), do: :soft_closed
  defp status_atom("open"), do: :open
  defp status_atom(other), do: other

  # ── changeset plumbing ─────────────────────────────────────────────────────

  # The tenant. On `:post`/`:void` the entry's own `org_id` attribute is often
  # `%Ash.NotLoaded{}` (Ash does not return it on the create result), and a
  # change that treated that as "no org" would silently SKIP R10 — so the load
  # below is the difference between a guard and a decoration.
  defp org_id(changeset) do
    case fetch(changeset, :org_id) do
      {:ok, org_id} when is_binary(org_id) ->
        {:ok, org_id}

      _ ->
        case Ash.load(changeset.data, [:org_id], authorize?: false) do
          {:ok, loaded} when is_binary(loaded.org_id) -> {:ok, loaded.org_id}
          _ -> :error
        end
    end
  end

  # Reads the pending change OR the persisted value (the PostGuard/EntryLines
  # posture: on :post nothing is pending, so the stored row decides).
  defp fetch(changeset, name) do
    case Ash.Changeset.get_attribute(changeset, name) do
      %Ash.NotLoaded{} -> from_data(changeset, name)
      nil -> from_data(changeset, name)
      value -> {:ok, value}
    end
  end

  defp from_data(changeset, name) do
    case Map.get(changeset.data, name) do
      nil -> :error
      %Ash.NotLoaded{} -> :error
      value -> {:ok, value}
    end
  end


  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "#{inspect(resource)} has no #{inspect(name)} attribute"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :entry_date, message: message)
  end
end
