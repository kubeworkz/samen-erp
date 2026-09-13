defmodule Samen.Scopes.Finance.VoidGuard do
  @moduledoc """
  The `:void` transition (WS-ERP E1; ADR-049 §2, decision 2): a void is not a
  deletion or an edit — it POSTS a **reversing entry** (same date, mirrored
  lines: every debit becomes a credit and vice versa) and links the original
  back via `voided_entry_id`. Nothing is ever destroyed or rewritten; the
  ledger's history stays complete and the trial balance stays correct (the
  reversed pair nets to zero).

  Runs in the `:void` action's `before_action` — inside the action's transaction
  (`Samen.Scopes.SalesOps.ConvertLead`'s cross-row-cascade discipline): the
  reversing entry is CREATED FIRST (so its id can be stamped on the original via
  `force_change_attribute(:voided_entry_id)` before the main UPDATE lands), and
  if the reversal fails the whole void rolls back (the original is never left
  voided-without-reversal). Refusing a draft is also an error here — a draft is
  not a fact, so there is nothing to reverse; only `:posted` voids.

  The reversing entry carries `source_key: "journal_entry"` +
  `source_id: <original id>` — the ADR-041 §3.2 object-ref anchor shape, naming
  its upstream without coupling to it — and `voided_entry_id: <original id>`;
  the original's own `voided_entry_id` is force-changed to the reversal's id
  before the main UPDATE lands, so the pair is linked in BOTH directions.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &void/1)
  end

  defp void(changeset) do
    entry = changeset.data
    resource = changeset.resource
    line_resource = line_resource(resource)

    # The caller's record may carry a NotLoaded org_id (a create result passed
    # straight into :void) — resolve it before building the reversal (the
    # ConvertLead discipline).
    org_id =
      case entry.org_id do
        %Ash.NotLoaded{} -> Ash.load!(entry, [:org_id], authorize?: false).org_id
        value -> value
      end

    # A draft is not a fact — there is nothing to reverse. Only a POSTED entry
    # may be voided (PostBalance's line-less/imbalance refusals run before this
    # in the :void action; this is the status condition, not the R1 condition).
    if entry.status != :posted do
      Ash.Changeset.add_error(changeset,
        field: :status,
        message:
          "only a POSTED entry can be voided — a #{entry.status} entry is not a fact to reverse"
      )
    else
      case load_lines(resource, line_resource, entry) do
        {:ok, lines} ->
          case create_reversal(changeset, entry, org_id, lines) do
            {:ok, reversal} ->
              # Persist the ORIGINAL's back-link to its reversal (the reversal
              # row carries voided_entry_id = original; this is the mirror
              # direction) — the main UPDATE lands it in the same transaction.
              Ash.Changeset.force_change_attribute(changeset, :voided_entry_id, reversal.id)

            {:error, reason} ->
              Ash.Changeset.add_error(changeset,
                field: :base,
                message: "the void's reversing entry failed to land: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the void could not read the entry's stored lines: #{inspect(reason)}"
          )
      end
    end
  end

  defp load_lines(resource, line_resource, entry) do
    table = AshPostgres.DataLayer.Info.table(line_resource)
    repo = AshPostgres.DataLayer.Info.repo(line_resource, :read)

    entry_fk = entry_fk_source(line_resource, resource)
    id_source = attr_source(line_resource, :id)
    acct_source = attr_source(line_resource, :account_id)
    debit_source = attr_source(line_resource, :debit_cents)
    credit_source = attr_source(line_resource, :credit_cents)

    sql = """
    SELECT #{id_source}, #{acct_source}, #{debit_source}, #{credit_source}
    FROM #{table} WHERE #{entry_fk} = $1
    """

    case repo.query(sql, [dump_uuid(entry.id)]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [id, acct, debit, credit] ->
           %{id: load_uuid(id), account_id: load_uuid(acct), debit: to_i(debit), credit: to_i(credit)}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_reversal(changeset, entry, org_id, lines) do
    resource = changeset.resource

    reversal_attrs = %{
      org_id: org_id,
      entry_date: entry.entry_date,
      memo: "Reversal of entry #{entry.id}" <> memo_suffix(entry.memo),
      source_key: "journal_entry",
      source_id: entry.id,
      voided_entry_id: entry.id
    }

    line_attrs =
      Enum.map(lines, fn line ->
        # NO org_id here — the lines argument carries account + amounts only;
        # each materialized row's org_id is owned by EntryLines (from the
        # reversal changeset itself).
        %{
          account_id: line.account_id,
          debit_cents: line.credit,
          credit_cents: line.debit
        }
      end)

    resource
    |> Ash.Changeset.for_create(:create_reversal, Map.put(reversal_attrs, :lines, line_attrs),
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  # The line resource is resolved from the entry's has_many (the single source
  # of truth for which line module this entry owns).
  defp line_resource(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :lines))
    |> Map.fetch!(:destination)
  end

  # The line→entry FK source attribute: the line resource's belongs_to whose
  # destination IS the entry resource being voided (resolved at runtime, so the
  # blueprint's storage-prefix discipline stays the single source of truth).
  defp entry_fk_source(line_resource, entry_resource) do
    rel =
      line_resource
      |> Ash.Resource.Info.relationships()
      |> Enum.find(&(&1.type == :belongs_to and &1.destination == entry_resource))

    unless rel do
      raise ArgumentError,
            "Samen.Scopes.Finance.VoidGuard: the line resource #{inspect(line_resource)} " <>
              "must declare a belongs_to whose destination is the entry resource " <>
              "#{inspect(entry_resource)}"
    end

    to_string(attr_source(line_resource, rel.source_attribute))
  end

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
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

  defp load_uuid(bin) when is_binary(bin) and byte_size(bin) == 16 do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> bin
    end
  end

  defp load_uuid(other), do: other

  defp to_i(nil), do: 0
  defp to_i(v) when is_integer(v), do: v
  defp to_i(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_i(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {i, ""} -> i
      _ -> 0
    end
  end
  defp to_i(_), do: 0
end
