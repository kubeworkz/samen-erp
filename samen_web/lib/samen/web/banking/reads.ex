defmodule Samen.Web.Banking.Reads do
  @moduledoc """
  The framework Banking read layer (WS-ERP E9 host surfaces).

  Every function resolves its resource through `Samen.Web.Mount.resource/2` (never a
  host module) and reads through Ash with the mount's `scope`, so OrgScope policy and
  the bounded-read discipline apply identically on every host.

  NON-PII by construction: the Banking blueprint's PII map is EMPTY (INV-1) — no
  field here is vault-routed, so no PiiResolution pass exists or is needed (the
  `pii_classify` backstop is the leak guard). Every non-page read carries an explicit
  limit; on any read error the caller gets an EMPTY list / nil — never unbounded.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @detail_limit 200
  @entry_limit 100

  @line_fields [
    :id,
    :bank_account_id,
    :posted_at,
    :amount_cents,
    :description,
    :counterparty,
    :reference,
    :status,
    :reconciled_at,
    :import_hash
  ]

  @doc """
  Read ONE keyset page of bank accounts for `scope` — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`), built on `Samen.Web.Reads.page!/3`
  so the read is BOUNDED BY CONSTRUCTION. On any read error the page is EMPTY.
  """
  def accounts_page(mount, scope, state) do
    Mount.resource(mount, BankAccount)
    |> Ash.Query.ensure_selected([:name, :account_id, :statement_balance_cents, :currency, :is_active])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:name])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc "Read ONE bank account by id for `scope`; nil on miss/error (honest absence)."
  def account(mount, scope, id) do
    Mount.resource(mount, BankAccount)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:name, :account_id, :statement_balance_cents, :currency, :is_active, :archived_at])
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> List.first()
  rescue
    _ -> nil
  end

  @doc """
  The account's statement lines — bounded to `#{@detail_limit}` rows, newest first
  (single-parent fan-out, not a hot list). Append-only rows; no PII.
  """
  def statement_lines(mount, scope, bank_account_id) do
    Mount.resource(mount, StatementLine)
    |> Ash.Query.filter(bank_account_id == ^bank_account_id)
    |> Ash.Query.ensure_selected(@line_fields)
    |> Ash.Query.sort(posted_at: :desc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Candidate GL journal entries for a match — read from the host's FINANCE namespace
  (the `:erp_namespace` mount label; the banking namespace has no journal entries),
  bounded, NON-void (ReconcileGuard refuses voided entries, so they are never
  offered), each carrying its `total_cents` (Σ debit − credit over its lines) so the
  amount-strict expectation is VISIBLE before submit. Absent label → `[]` (the
  surface renders the honest empty picker, never a fabricated list).
  """
  def journal_candidates(mount, scope) do
    case Mount.label(mount, :erp_namespace, nil) do
      nil ->
        []

      ns ->
        Module.concat(ns, JournalEntry)
        |> Ash.Query.ensure_selected([:entry_date, :memo, :status])
        |> Ash.Query.load(:lines)
        |> Ash.Query.sort(entry_date: :desc)
        |> Ash.Query.limit(@entry_limit)
        |> Ash.read!(scope: scope)
        |> Enum.reject(&(&1.status == :void))
        |> Enum.map(fn e ->
          total =
            Enum.reduce(e.lines, 0, fn l, acc ->
              acc + (l.debit_cents || 0) - (l.credit_cents || 0)
            end)

          %{id: e.id, entry_date: e.entry_date, memo: e.memo, status: e.status, total_cents: total}
        end)
    end
  rescue
    _ -> []
  end

  @doc """
  The GL account options (Finance `Account` from the `:erp_namespace` mount label)
  for the Rule / BankAccount account selects. Bounded; absent label → `[]`.
  """
  def gl_accounts(mount, scope) do
    case Mount.label(mount, :erp_namespace, nil) do
      nil ->
        []

      ns ->
        Module.concat(ns, Account)
        |> Ash.Query.ensure_selected([:code, :name, :kind])
        |> Ash.Query.sort(code: :asc)
        |> Ash.Query.limit(@detail_limit)
        |> Ash.read!(scope: scope)
        |> Enum.map(&%{id: &1.id, label: "#{&1.code} · #{&1.name}"})
    end
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of auto-categorization rules for `scope` — the `ListLive`
  reads contract. Empty page on error.
  """
  def rules_page(mount, scope, state) do
    Mount.resource(mount, Rule)
    |> Ash.Query.ensure_selected([
      :pattern,
      :account_id,
      :bank_account_id,
      :min_amount_cents,
      :max_amount_cents,
      :priority,
      :is_active
    ])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:pattern])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end
end
