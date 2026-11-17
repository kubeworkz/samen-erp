defmodule Samen.Hr.Payroll.JournalProvider do
  @moduledoc """
  A reference `Samen.Hr.PayrollProvider` that **imports** a payroll register
  produced by an external payroll system. It does not calculate payroll:
  gross/net pay, tax, withholding, rates, proration and deductions stay in the
  provider that computed the register. This module only carries the provider's
  balanced journal lines into the host's ledger.

  ## The register contract

      %{
        provider: "acme_payroll",
        external_id: "run-2026-09",
        entry_date: ~D[2026-09-30],
        memo: "September 2026 payroll",       # optional
        lines: [
          %{account_code: "6000", debit_cents: 125_000, memo: "employee_ref: emp_1042"},
          %{account_code: "2100", credit_cents: 125_000}
        ]
      }

  `memo` and each line's `memo` are plaintext and unvaulted once they reach the
  journal. They are therefore scanned by `Samen.Hr.Payroll.MemoScan` before any
  write: obvious employee names, bank details, tax identifiers and name-shaped
  phrases in a name-taking context refuse the import. Memos should carry opaque
  references (for example `employee_ref: emp_1042`), and cost-object identity
  belongs in the line's ids-only `dimension_refs`, never in memo prose.

  Every line names a provider account CODE and exactly one non-zero integer-cents
  side. Codes are resolved through the host's per-provider
  `Finance.PayrollAccountMapping` before a line reaches the journal; the register
  itself never carries a host UUID, so the same payload is portable across
  environments. The register must balance and have a positive total. No `gross`,
  `net`, `tax`, `hours` or `rate` fields are read — if the external provider
  supplied them, they are not used as arithmetic inputs here. The register is the
  external system's result, not a prompt for us to compute one.

  ## Preflight — no writes

  `validate/2` runs the same checks as an import without writing anything:

    * mapping coverage for every line's external code;
    * the mapped account exists and belongs to the same org;
    * neither the header memo nor any line memo carries an obvious PII shape
      or a name-shaped phrase in a name-taking context
      (`Samen.Hr.Payroll.MemoScan`);
    * a new draft's entry date is not in a closed (or document-refusing
      soft-closed) fiscal period;
    * the existing anchor is `:duplicate` (same date/lines/total) or
      `:conflict` (different); and
    * the register is structurally valid and has a positive, balanced total.

  It returns `{:ok, report}` with `status: :ready | :duplicate | :conflict`, or
  `{:error, {:payroll_preflight_failed, errors}}` / the structural
  `{:error, {:invalid_payroll_register, reason}}` shape. A duplicate is safe to
  replay; a conflict is reported without writing a conflict provenance row
  (only `run_payroll/3` records that row).

  ## A draft, not an ungated posting

  The imported entry is a normal `:draft` created through the host's
  `JournalEntry.:create` action. The adapter never calls `:post`; a person (or
  the host's separately authorized automation) still submits it through the
  ordinary `:post` door, including R1, R6, R10 and any `JournalApprovalPolicy`.
  This is the `JournalTemplate` posture: an importer must not become a second,
  ungated posting path.

  ## Idempotency

  The entry is anchored `source_key: "payroll_register:<provider>:<external_id>"`
  (both components URL-encoded, so an id containing `:` cannot collide with
  another provider). The anchor is backed by a partial unique index on
  `(org_id, source_key)` for `payroll_register:*` keys, so the database is the
  arbiter. Re-importing the same external run returns the existing entry when
  its entry date, lines and total match; a changed date, total or line set for
  the same anchor is refused as `:payroll_register_conflict`. A concurrent
  insert that loses the race is re-read and returned (or refused as a
  conflict), so two importers cannot create two drafts. The anchor is also
  visible to a reviewer, so a duplicated external run is easy to spot. A
  provider that changes a payroll run uses `amend_payroll/3`: the current
  posted entry is voided through the journal's governed reversal path, the
  replacement becomes a new draft under a revision source key, and the new
  `PayrollImport` row points at the prior one. The external id is never reused
  for a different posting, and posted journal facts are never mutated.

  ## Amendments

  `amend_payroll/3` targets the latest `:imported` provenance row for the
  provider/external id. It refuses an unchanged register and a target whose
  entry is still `:draft`; a posted target is voided through the normal
  `JournalEntry.:void` action (which creates the linked reversal and keeps any
  approval/period guards), then the replacement is imported as a new draft.
  If the original was already voided and the replacement exists, a retry
  completes the `supersedes_id` link instead of writing twice. The original
  import row is retained as `:superseded` for the audit chain.

  Every successful import also lands one `PayrollImport` provenance row with
  the provider/external id, line-set hash, total, entry date, imported-at/by
  and status, linked to the draft. A refused replay under the same identity
  lands (or reuses) a `:conflict` row linked to the existing entry instead of
  overwriting the successful provenance. That conflict row is retained as
  history if a later amendment successfully imports the same line set, and is
  marked `:superseded` so the close precondition does not keep blocking on a
  resolved conflict; the database keeps separate partial identities for
  `:imported` and `:conflict` rows. The hash covers only normalized GL lines;
  no raw register or employee data is stored or hashed.

  A host mount must carry the equivalent partial unique indexes in its Finance
  migration (the core fixture and `samenerp` host migrations do). The adapter
  does not fall back to a read-then-create guarantee.

  ## Configuration

      config :samen_core, Samen.Hr.PayrollProvider,
        provider: Samen.Hr.Payroll.JournalProvider

      config :samen_core, Samen.Hr.Payroll.JournalProvider,
        entry_module: MyApp.Finance.JournalEntry,
        import_module: MyApp.Finance.PayrollImport,
        mapping_module: MyApp.Finance.PayrollAccountMapping,
        period_module: MyApp.Finance.FiscalPeriod,
        settlement_module: MyApp.Finance.PayrollSettlement

  The `import_module` is the Finance scope's `PayrollImport` resource. It
  stores the durable provenance row (provider, external id, normalized
  line-set hash, total, timestamp, importer, status and linked draft entry).
  The `mapping_module` is the Finance scope's `PayrollAccountMapping`; the
  `period_module` is its `FiscalPeriod` (R10). A mount that has not wired all
  four fails honest with `{:error, :not_configured}`. The provider can also be
  passed explicitly:

      Samen.Hr.PayrollProvider.run_payroll(org_id, period,
        provider: Samen.Hr.Payroll.JournalProvider,
        entry_module: MyApp.Finance.JournalEntry,
        import_module: MyApp.Finance.PayrollImport,
        mapping_module: MyApp.Finance.PayrollAccountMapping,
        period_module: MyApp.Finance.FiscalPeriod,
        imported_by: "u:controller",
        register: register
      )

  A host must configure the four core modules or neither; the kernel boot
  guard (`assert_wiring!/0`) refuses a half-wired host. `settlement_module`
  is additionally required by `amend_payroll/3`; without it amendment refuses
  fail-honest rather than voiding a register it cannot check for a settlement.

  `period` is the caller's payroll period label. The journal date is the
  register's explicit `entry_date`; the adapter does not infer one.
  """

  @behaviour Samen.Hr.PayrollProvider

  require Ash.Query

  @source_key_prefix "payroll_register"
  @config_key __MODULE__

  alias Samen.Hr.Payroll.MemoScan

  @impl true
  def run_payroll(org_id, %Date{} = _period, opts) when is_binary(org_id) do
    with {:ok, config} <- config(opts),
         {:ok, imported_by} <- imported_by(opts),
         {:ok, report} <- validate(org_id, opts) do
      import_report(config, report, imported_by)
    end
  end

  @doc """
  Amend one provider register through the governed reversal path.

  The latest `:imported` provenance row for this provider/external id is the
  amendment target. Its entry must be `:posted` (or already `:void` from a
  partially completed amendment); a `:draft` target is refused because it has
  not entered the ledger yet. A register with any `PayrollSettlement` in its
  import chain is refused before the void, because voiding only the register
  entry would strand the settlement's cash leg. A posted target is voided with
  the journal's normal `:void` action, which creates the linked reversal and
  preserves any approval/period guards. The replacement is then imported as a
  new `:draft` with a revision source key and a distinct `PayrollImport` row
  whose `supersedes_id` points at the prior import. The provider/external id
  stays the same.

  A retry after the original was voided but before the replacement landed finds
  the existing replacement and completes the supersedes link. Re-amending an
  unchanged register, or trying to amend a draft target, refuses without
  writing.
  """
  @impl true
  @spec amend_payroll(binary(), Date.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def amend_payroll(org_id, %Date{} = _period, opts) when is_binary(org_id) do
    with {:ok, config} <- amend_config(opts),
         {:ok, imported_by} <- imported_by(opts),
         {:ok, report} <- validate(org_id, opts),
         :ok <- period_check(config.period_module, org_id, report.entry_date, :ready) do
      amend_locked(config, report, imported_by)
    end
  end

  # The settlement actions lock the PayrollImport row before they read the
  # register or write a settlement. Amendment must hold the SAME locks across
  # its settlement check, void, replacement and supersede writes, or a
  # settlement can commit between the check and the void and leave cash legs
  # against a voided register. The whole amendment is one transaction so an
  # error after the void rolls the void and replacement back together.
  defp amend_locked(config, report, imported_by) do
    repo = repo!(config.import_module)

    case repo.transaction(fn ->
           with {:ok, import_ids} <- lock_import_ids(config.import_module, report),
                {:ok, latest} <- latest_import(config.import_module, report),
                :ok <-
                  ensure_no_settlement_rows(
                    config.settlement_module,
                    report.org_id,
                    import_ids
                  ) do
             result =
               if same_register?(latest.entry, report) do
                 settle_unchanged_amendment(config, latest, report)
               else
                 revision = revision_register(report, latest.id)
                 amend_import(config, latest, revision, imported_by)
               end

             case result do
               {:ok, _amendment} = ok -> ok
               {:error, reason} -> repo.rollback(reason)
             end
           else
             {:error, reason} -> repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write-free preflight for one provider register.

  Resolves every line's `account_code` through the host's per-provider
  `PayrollAccountMapping`, verifies the mapped accounts are same-org, checks a
  new draft's entry date against the closed/soft-closed fiscal period, and
  reports whether the provider/external-id anchor is `:ready`, an exact
  `:duplicate`, or a `:conflict`. No journal, provenance or conflict row is
  written — this is safe to call before deciding whether to import.

  Returns `{:ok, report}` for `:ready`/`:duplicate`/`:conflict`, or an error
  tuple for malformed registers, missing/cross-org mappings, closed periods,
  or unreadable lookups.
  """
  @impl true
  @spec validate(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(org_id, opts) when is_binary(org_id) do
    with {:ok, config} <- config(opts),
         {:ok, raw_register} <- register(opts),
         {:ok, register} <- normalize(raw_register, org_id),
         {:ok, resolved} <- resolve_accounts(register, config, org_id) do
      build_report(resolved, config, org_id)
    end
  end

  def validate(_org_id, _opts), do: {:error, :invalid_org_id}

  defp amend_config(opts) do
    with {:ok, config} <- config(opts),
         {:ok, settlement_module} <- settlement_module(opts) do
      {:ok, Map.put(config, :settlement_module, settlement_module)}
    end
  end

  defp config(opts) do
    with {:ok, entry_module} <- entry_module(opts),
         {:ok, import_module} <- import_module(opts),
         {:ok, mapping_module} <- mapping_module(opts),
         {:ok, period_module} <- period_module(opts),
         {:ok, account_module} <- account_module(mapping_module) do
      {:ok,
       %{
         entry_module: entry_module,
         import_module: import_module,
         mapping_module: mapping_module,
         period_module: period_module,
         account_module: account_module
       }}
    end
  end

  defp import_report(config, %{status: :ready} = report, imported_by) do
    create_draft(config.entry_module, config.import_module, report, imported_by)
  end

  defp import_report(config, %{status: :duplicate, existing_entry: entry} = report, imported_by) do
    existing_result(entry, report, config.import_module, imported_by, :imported)
  end

  defp import_report(config, %{status: :conflict, existing_entry: entry} = report, imported_by) do
    existing_result(entry, report, config.import_module, imported_by, :conflict)
  end

  defp latest_import(import_module, report) do
    import_module
    |> Ash.Query.filter(
      org_id == ^report.org_id and provider == ^report.provider and
        external_id == ^report.external_id and status == :imported
    )
    |> Ash.Query.sort(imported_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(entry: [:lines])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :payroll_import_not_found}
      {:ok, import} -> {:ok, import}
      {:error, reason} -> {:error, {:payroll_import_lookup_failed, reason}}
    end
  end

  # The amendment only touches the register entry, so any settlement already
  # attached to this provider/external-id chain would keep its cash movement
  # while the payable side is reversed. Refuse before the void instead of
  # pretending a register-level correction can reverse a payment batch.
  #
  # Lock every provenance row in the provider/external-id chain, not just the
  # latest: an older `:imported` row can still be the target of a settlement
  # prepare while an amendment is in flight. Sorting gives concurrent
  # amendments a stable lock order.
  defp lock_import_ids(import_module, report) do
    import_module
    |> Ash.Query.filter(
      org_id == ^report.org_id and provider == ^report.provider and
        external_id == ^report.external_id
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.select([:id])
    |> Ash.Query.lock(:for_update)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, imports} -> {:ok, Enum.map(imports, & &1.id)}
      {:error, reason} -> {:error, {:payroll_import_lookup_failed, reason}}
    end
  end

  defp repo!(resource) do
    AshPostgres.DataLayer.Info.repo(resource, :mutate) ||
      AshPostgres.DataLayer.Info.repo(resource) ||
      raise ArgumentError,
            "payroll amendment requires a Postgres repo for #{inspect(resource)}"
  end

  defp ensure_no_settlement_rows(settlement_module, org_id, import_ids) do
    settlement_module
    |> Ash.Query.filter(org_id == ^org_id and payroll_import_id in ^import_ids)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, []} -> :ok
      {:ok, [_settlement]} -> {:error, :payroll_settlement_exists}
      {:error, reason} -> {:error, {:payroll_settlement_lookup_failed, reason}}
    end
  end

  # A retry can reach this branch after the replacement import landed but the
  # predecessor's `:superseded` write did not. The replacement is already the
  # latest active import, so finish the chain and return the existing result
  # rather than reporting a false "unchanged" error.
  defp settle_unchanged_amendment(config, latest, report) do
    case latest.supersedes_id do
      nil ->
        {:error, :payroll_register_unchanged}

      predecessor_id ->
        with {:ok, predecessor} <- import_with_entry(config.import_module, predecessor_id),
             :ok <- resolve_conflict_imports(config.import_module, report),
             :ok <- supersede_import_chain(config.import_module, predecessor.id) do
          total = Enum.sum(Enum.map(latest.entry.lines, & &1.debit_cents))
          {:ok, amendment_result(result(latest.entry, total), predecessor)}
        end
    end
  end

  defp import_with_entry(import_module, import_id) do
    import_module
    |> Ash.Query.filter(id == ^import_id)
    |> Ash.Query.load(entry: [:lines])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :payroll_import_not_found}
      {:ok, import} -> {:ok, import}
      {:error, reason} -> {:error, {:payroll_import_lookup_failed, reason}}
    end
  end

  defp revision_register(report, supersedes_id) do
    report
    |> Map.put(:source_key, revision_source_key(report))
    |> Map.put(:supersedes_id, supersedes_id)
  end

  defp revision_source_key(report) do
    base = source_key(report.provider, report.external_id)
    "#{base}:revision:#{report.line_set_hash}:#{Date.to_iso8601(report.entry_date)}"
  end

  defp amend_import(config, latest, revision, imported_by) do
    case find_existing(config.entry_module, revision) do
      {:ok, nil} ->
        amend_new_target(config, latest, revision, imported_by)

      {:ok, existing_entry} ->
        settle_existing_revision(config, latest, existing_entry, revision, imported_by)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp amend_new_target(config, latest, revision, imported_by) do
    case latest.entry.status do
      :draft ->
        {:error, :payroll_register_not_posted}

      status when status in [:posted, :void] ->
        with {:ok, _voided} <- maybe_void(latest.entry, imported_by),
             {:ok, result} <-
               create_draft(config.entry_module, config.import_module, revision, imported_by),
             :ok <- resolve_conflict_imports(config.import_module, revision),
             :ok <- supersede_import_chain(config.import_module, latest.id) do
          {:ok, amendment_result(result, latest)}
        end

      status ->
        {:error, {:payroll_amendment_invalid_status, status}}
    end
  end

  defp settle_existing_revision(config, latest, existing_entry, revision, imported_by) do
    with {:ok, loaded} <- Ash.load(existing_entry, [:lines], authorize?: false) do
      cond do
        not same_register?(loaded, revision) ->
          {:error, :payroll_register_conflict}

        loaded.status == :void ->
          {:error, :payroll_register_already_voided}

        loaded.status in [:draft, :posted] ->
          # The entry can exist from a partial attempt that failed before its
          # provenance row landed. Recording is idempotent; it either reuses
          # the replacement row or creates the missing one before the chain is
          # marked superseded.
          with {:ok, _record} <-
                 record_import(config.import_module, revision, loaded, :imported, imported_by),
               :ok <- resolve_conflict_imports(config.import_module, revision),
               :ok <- supersede_import_chain(config.import_module, latest.id) do
            total = Enum.sum(Enum.map(loaded.lines, & &1.debit_cents))
            {:ok, amendment_result(result(loaded, total), latest)}
          end

        true ->
          {:error, {:payroll_amendment_invalid_status, loaded.status}}
      end
    end
  end

  defp maybe_void(%{status: :void}, _imported_by), do: {:ok, nil}

  defp maybe_void(entry, imported_by) do
    actor = if imported_by, do: %{id: imported_by}, else: nil

    case entry
         |> Ash.Changeset.for_update(:void, %{}, actor: actor, authorize?: false)
         |> Ash.update(authorize?: false) do
      {:ok, voided} -> {:ok, voided}
      {:error, reason} -> {:error, {:payroll_amendment_void_failed, reason}}
    end
  end

  defp supersede_import_chain(import_module, import_id) do
    supersede_import_chain(import_module, import_id, MapSet.new())
  end

  defp supersede_import_chain(_import_module, nil, _seen), do: :ok

  defp supersede_import_chain(import_module, import_id, seen) do
    if MapSet.member?(seen, import_id) do
      :ok
    else
      case Ash.get(import_module, import_id, authorize?: false) do
        {:ok, import} ->
          with :ok <- mark_import_superseded(import) do
            supersede_import_chain(
              import_module,
              import.supersedes_id,
              MapSet.put(seen, import.id)
            )
          end

        {:error, reason} ->
          {:error, {:payroll_import_lookup_failed, reason}}
      end
    end
  end

  # The old hard-stop path could leave a `:conflict` row for exactly the line
  # set the amendment now imports. Retain the row for history, but mark it
  # superseded so the close precondition does not keep blocking on a conflict
  # the amendment has already resolved.
  defp resolve_conflict_imports(import_module, register) do
    import_module
    |> Ash.Query.filter(
      org_id == ^register.org_id and provider == ^register.provider and
        external_id == ^register.external_id and
        line_set_hash == ^register.line_set_hash and entry_date == ^register.entry_date and
        status == :conflict
    )
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} ->
        Enum.reduce_while(rows, :ok, fn row, :ok ->
          case mark_import_superseded(row) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, {:payroll_import_lookup_failed, reason}}
    end
  end

  defp mark_import_superseded(%{status: :superseded}), do: :ok

  defp mark_import_superseded(import) do
    case import
         |> Ash.Changeset.for_update(:supersede, %{}, authorize?: false)
         |> Ash.update(authorize?: false) do
      {:ok, _superseded} -> :ok
      {:error, reason} -> {:error, {:payroll_import_supersede_failed, reason}}
    end
  end

  defp amendment_result(result, latest) do
    result
    |> Map.put(:superseded_entry_id, latest.entry.id)
    |> Map.put(:superseded_import_id, latest.id)
  end

  defp entry_module(opts) do
    case Keyword.get(opts, :entry_module) || configured_entry_module() do
      nil -> {:error, :not_configured}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_entry_module}
    end
  end

  defp import_module(opts) do
    case Keyword.get(opts, :import_module) || configured_import_module() do
      nil -> {:error, :not_configured}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_import_module}
    end
  end

  defp mapping_module(opts) do
    case Keyword.get(opts, :mapping_module) || configured_mapping_module() do
      nil -> {:error, :not_configured}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_mapping_module}
    end
  end

  defp period_module(opts) do
    case Keyword.get(opts, :period_module) || configured_period_module() do
      nil -> {:error, :not_configured}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_period_module}
    end
  end

  defp settlement_module(opts) do
    case Keyword.get(opts, :settlement_module) || configured_settlement_module() do
      nil -> {:error, :payroll_settlement_not_configured}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_settlement_module}
    end
  end

  defp account_module(mapping_module) do
    with true <- Code.ensure_loaded?(mapping_module),
         %{destination: destination} when is_atom(destination) <-
           mapping_relationship(mapping_module) do
      {:ok, destination}
    else
      _ -> {:error, :invalid_mapping_module}
    end
  end

  defp mapping_relationship(module) do
    Ash.Resource.Info.relationship(module, :account)
  rescue
    _ -> nil
  end

  defp imported_by(opts) do
    case Keyword.get(opts, :imported_by) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :invalid_imported_by}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :invalid_imported_by}
    end
  end

  @doc """
  The host's configured journal-entry module, or nil when the importer is not
  wired. This is the `entry_module` half of the opt-in; the provider half is
  `Samen.Hr.PayrollProvider` selecting `Samen.Hr.Payroll.JournalProvider`.
  """
  @spec configured_entry_module() :: module() | nil
  def configured_entry_module do
    case Application.get_env(:samen_core, @config_key, []) do
      %{entry_module: entry_module} -> entry_module
      config when is_list(config) -> Keyword.get(config, :entry_module)
      _ -> nil
    end
  end

  @doc """
  The host's configured `PayrollImport` module, or nil when the record is not
  wired. This is the durable-provenance half of the reference importer's
  opt-in.
  """
  @spec configured_import_module() :: module() | nil
  def configured_import_module do
    case Application.get_env(:samen_core, @config_key, []) do
      %{import_module: import_module} -> import_module
      config when is_list(config) -> Keyword.get(config, :import_module)
      _ -> nil
    end
  end

  @doc """
  The host's configured `PayrollAccountMapping` module, or nil when the
  preflight/import mapping is not wired.
  """
  @spec configured_mapping_module() :: module() | nil
  def configured_mapping_module do
    case Application.get_env(:samen_core, @config_key, []) do
      %{mapping_module: mapping_module} -> mapping_module
      config when is_list(config) -> Keyword.get(config, :mapping_module)
      _ -> nil
    end
  end

  @doc """
  The host's configured `FiscalPeriod` module, or nil when the closed-period
  preflight is not wired.
  """
  @spec configured_period_module() :: module() | nil
  def configured_period_module do
    case Application.get_env(:samen_core, @config_key, []) do
      %{period_module: period_module} -> period_module
      config when is_list(config) -> Keyword.get(config, :period_module)
      _ -> nil
    end
  end

  @doc """
  The host's configured `PayrollSettlement` module, or nil when the amendment
  cash-leg guard is not wired. Amendment refuses fail-honest without it.
  """
  @spec configured_settlement_module() :: module() | nil
  def configured_settlement_module do
    case Application.get_env(:samen_core, @config_key, []) do
      %{settlement_module: settlement_module} -> settlement_module
      config when is_list(config) -> Keyword.get(config, :settlement_module)
      _ -> nil
    end
  end

  @doc """
  Refuse a half-wired payroll importer at host boot.

  The reference importer is opt-in in four parts: `Samen.Hr.PayrollProvider`
  must select this module, and this module must have an `entry_module`, an
  `import_module`, a `mapping_module` and a `period_module`. A partial opt-in
  is a silent no-op/miswire, so all four must be present or none. A custom
  payroll provider does not need this module's wiring; setting it alongside a
  different provider is also rejected as stale config.
  """
  @spec assert_wiring!() :: :ok
  def assert_wiring! do
    provider = Samen.Hr.PayrollProvider.provider()
    entry_module = configured_entry_module()
    import_module = configured_import_module()
    mapping_module = configured_mapping_module()
    period_module = configured_period_module()

    wired? =
      not is_nil(entry_module) or not is_nil(import_module) or not is_nil(mapping_module) or
        not is_nil(period_module)

    complete? =
      not is_nil(entry_module) and not is_nil(import_module) and not is_nil(mapping_module) and
        not is_nil(period_module)

    cond do
      provider == __MODULE__ and not complete? ->
        raise """
        payroll miswired: Samen.Hr.PayrollProvider selects
        #{inspect(__MODULE__)} but #{inspect(@config_key)} is missing
        #{missing_wiring(entry_module, import_module, mapping_module, period_module)}.
        Configure all four or neither:
          config :samen_core, Samen.Hr.PayrollProvider,
            provider: Samen.Hr.Payroll.JournalProvider
          config :samen_core, Samen.Hr.Payroll.JournalProvider,
            entry_module: MyApp.Finance.JournalEntry,
            import_module: MyApp.Finance.PayrollImport,
            mapping_module: MyApp.Finance.PayrollAccountMapping,
            period_module: MyApp.Finance.FiscalPeriod
        """

      provider != __MODULE__ and wired? ->
        raise """
        payroll miswired: #{inspect(@config_key)} configures
        #{stale_wiring(entry_module, import_module, mapping_module, period_module)} but
        Samen.Hr.PayrollProvider selects #{inspect(provider)}. Configure all
        four or neither:
          config :samen_core, Samen.Hr.PayrollProvider,
            provider: Samen.Hr.Payroll.JournalProvider
          config :samen_core, Samen.Hr.Payroll.JournalProvider,
            entry_module: MyApp.Finance.JournalEntry,
            import_module: MyApp.Finance.PayrollImport,
            mapping_module: MyApp.Finance.PayrollAccountMapping,
            period_module: MyApp.Finance.FiscalPeriod
        """

      true ->
        :ok
    end
  end

  defp missing_wiring(nil, _import_module, _mapping_module, _period_module), do: ":entry_module"
  defp missing_wiring(_entry_module, nil, _mapping_module, _period_module), do: ":import_module"

  defp missing_wiring(_entry_module, _import_module, nil, _period_module),
    do: ":mapping_module"

  defp missing_wiring(_entry_module, _import_module, _mapping_module, nil),
    do: ":period_module"

  defp missing_wiring(_entry_module, _import_module, _mapping_module, _period_module),
    do: "wiring"

  defp stale_wiring(entry_module, import_module, mapping_module, period_module) do
    [
      entry_module && ":entry_module #{inspect(entry_module)}",
      import_module && ":import_module #{inspect(import_module)}",
      mapping_module && ":mapping_module #{inspect(mapping_module)}",
      period_module && ":period_module #{inspect(period_module)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp register(opts) do
    case Keyword.get(opts, :register) do
      nil -> {:error, :payroll_register_required}
      %{} = register -> {:ok, register}
      _ -> {:error, :invalid_payroll_register}
    end
  end

  defp normalize(register, org_id) do
    with {:ok, provider} <- required_string(register, :provider, :provider_required),
         {:ok, external_id} <-
           required_string(register, :external_id, :external_id_required),
         {:ok, entry_date} <- entry_date(register),
         {:ok, lines} <- lines(register),
         {:ok, memo} <- memo(register, provider, external_id),
         :ok <- MemoScan.check(memo, :memo),
         :ok <- balanced(lines) do
      total_cents = Enum.sum(Enum.map(lines, & &1.debit_cents))

      if total_cents > 0 do
        {:ok,
         %{
           org_id: org_id,
           provider: provider,
           external_id: external_id,
           entry_date: entry_date,
           memo: memo,
           lines: lines,
           total_cents: total_cents,
           source_key: source_key(provider, external_id)
         }}
      else
        {:error, {:invalid_payroll_register, :zero_total}}
      end
    end
  end

  defp required_string(map, key, reason) do
    case fetch(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_payroll_register, reason}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid_payroll_register, reason}}
    end
  end

  defp entry_date(register) do
    case fetch(register, :entry_date) do
      %Date{} = date ->
        {:ok, date}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, {:invalid_payroll_register, :entry_date}}
        end

      _ ->
        {:error, {:invalid_payroll_register, :entry_date}}
    end
  end

  defp memo(register, provider, external_id) do
    case fetch(register, :memo) do
      nil -> {:ok, "Payroll register #{provider}/#{external_id}"}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, {:invalid_payroll_register, :memo}}
    end
  end

  defp lines(register) do
    case fetch(register, :lines) do
      lines when is_list(lines) and lines != [] ->
        if Enum.all?(lines, &zero_line?/1) do
          {:error, {:invalid_payroll_register, :zero_total}}
        else
          normalize_lines(lines)
        end

      _ ->
        {:error, {:invalid_payroll_register, :lines}}
    end
  end

  defp zero_line?(line) when is_map(line) do
    fetch(line, :debit_cents) in [nil, 0] and fetch(line, :credit_cents) in [nil, 0]
  end

  defp zero_line?(_line), do: false

  defp normalize_lines(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      case normalize_line(line, index) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_line(line, index) do
    with true <- is_map(line),
         {:ok, account_code} <- line_string(line, :account_code, index, :account_code_required),
         {:ok, debit_cents} <- amount(line, :debit_cents, index),
         {:ok, credit_cents} <- amount(line, :credit_cents, index),
         :ok <- one_side(debit_cents, credit_cents, index),
         {:ok, line_memo} <- line_memo(line, index),
         :ok <- MemoScan.check(line_memo, {:line_memo, index}),
         {:ok, dimension_refs} <- dimension_refs(line, index) do
      {:ok,
       %{
         account_code: account_code,
         debit_cents: debit_cents,
         credit_cents: credit_cents,
         memo: line_memo,
         dimension_refs: dimension_refs
       }}
    else
      false -> {:error, {:invalid_payroll_register, {:line_not_a_map, index}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp line_string(line, key, index, reason) do
    case fetch(line, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_payroll_register, {reason, index}}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid_payroll_register, {reason, index}}}
    end
  end

  defp amount(line, key, index) do
    case fetch(line, key) do
      nil -> {:ok, 0}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_payroll_register, {:amount, index, key}}}
    end
  end

  defp one_side(debit_cents, credit_cents, index) do
    case {debit_cents > 0, credit_cents > 0} do
      {true, false} -> :ok
      {false, true} -> :ok
      _ -> {:error, {:invalid_payroll_register, {:one_non_zero_side, index}}}
    end
  end

  defp line_memo(line, index) do
    case fetch(line, :memo) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, {:invalid_payroll_register, {:memo, index}}}
    end
  end

  defp dimension_refs(line, index) do
    case fetch(line, :dimension_refs) do
      nil -> {:ok, %{}}
      %{} = refs -> {:ok, refs}
      _ -> {:error, {:invalid_payroll_register, {:dimension_refs, index}}}
    end
  end

  defp balanced(lines) do
    debits = Enum.sum(Enum.map(lines, & &1.debit_cents))
    credits = Enum.sum(Enum.map(lines, & &1.credit_cents))

    if debits == credits do
      :ok
    else
      {:error, {:invalid_payroll_register, {:unbalanced, debits, credits}}}
    end
  end

  @doc """
  The SHA-256 hex digest of the NORMALIZED GL lines. The fingerprint sorts
  line order and dimension-map keys, and includes only account ids, unsigned
  debit/credit cents, line memos and bounded dimension refs. It never includes
  raw employee data because this adapter never receives or stores any.
  """
  @spec line_set_hash([map()]) :: String.t()
  def line_set_hash(lines) do
    lines
    |> line_fingerprint()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp resolve_accounts(register, config, org_id) do
    codes = register.lines |> Enum.map(& &1.account_code) |> Enum.uniq()

    with {:ok, mappings} <-
           load_mappings(config.mapping_module, org_id, register.provider, codes),
         :ok <- ensure_mapping_coverage(mappings, codes, register.provider),
         {:ok, accounts} <- load_accounts(config.account_module, mappings),
         :ok <- ensure_same_org(accounts, mappings, org_id) do
      lines =
        Enum.map(register.lines, fn line ->
          line
          |> Map.delete(:account_code)
          |> Map.put(:account_id, Map.fetch!(mappings, line.account_code))
        end)

      {:ok,
       register
       |> Map.put(:lines, lines)
       |> Map.put(:line_set_hash, line_set_hash(lines))}
    end
  end

  defp load_mappings(mapping_module, org_id, provider, codes) do
    case mapping_module
         |> Ash.Query.filter(
           org_id == ^org_id and provider == ^provider and external_code in ^codes
         )
         |> Ash.read(authorize?: false) do
      {:ok, rows} ->
        case Enum.find(Enum.group_by(rows, & &1.external_code), fn {_code, matches} ->
               length(matches) > 1
             end) do
          nil ->
            {:ok, Map.new(rows, &{&1.external_code, &1.account_id})}

          {code, _matches} ->
            preflight_error(:mapping_ambiguous, %{provider: provider, external_code: code})
        end

      {:error, reason} ->
        preflight_error(:mapping_lookup_failed, %{reason: reason})
    end
  end

  defp ensure_mapping_coverage(mappings, codes, provider) do
    case Enum.reject(codes, &Map.has_key?(mappings, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         {:payroll_preflight_failed,
          Enum.map(missing, &%{code: :mapping_missing, provider: provider, external_code: &1})}}
    end
  end

  defp load_accounts(account_module, mappings) do
    account_ids = mappings |> Map.values() |> Enum.uniq()

    case account_module
         |> Ash.Query.filter(id in ^account_ids)
         |> Ash.Query.select([:id, :org_id])
         |> Ash.read(authorize?: false) do
      {:ok, accounts} -> {:ok, Map.new(accounts, &{&1.id, &1.org_id})}
      {:error, reason} -> preflight_error(:account_lookup_failed, %{reason: reason})
    end
  end

  defp ensure_same_org(accounts, mappings, org_id) do
    errors =
      Enum.flat_map(mappings, fn {external_code, account_id} ->
        case Map.fetch(accounts, account_id) do
          :error ->
            [%{code: :account_missing, external_code: external_code, account_id: account_id}]

          {:ok, ^org_id} ->
            []

          {:ok, other_org_id} ->
            [
              %{
                code: :account_cross_org,
                external_code: external_code,
                account_id: account_id,
                account_org_id: other_org_id
              }
            ]
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:payroll_preflight_failed, errors}}
    end
  end

  defp build_report(register, config, org_id) do
    with {:ok, status, entry} <- existing_status(config.entry_module, register),
         :ok <- period_check(config.period_module, org_id, register.entry_date, status) do
      {:ok,
       %{
         status: status,
         org_id: org_id,
         provider: register.provider,
         external_id: register.external_id,
         entry_date: register.entry_date,
         memo: register.memo,
         lines: register.lines,
         total_cents: register.total_cents,
         source_key: register.source_key,
         line_set_hash: register.line_set_hash,
         existing_entry: entry,
         existing_entry_id: entry && entry.id
       }}
    end
  end

  defp existing_status(entry_module, register) do
    case find_existing(entry_module, register) do
      {:ok, nil} ->
        {:ok, :ready, nil}

      {:ok, entry} ->
        case Ash.load(entry, [:lines], authorize?: false) do
          {:ok, loaded} ->
            status = if same_register?(loaded, register), do: :duplicate, else: :conflict
            {:ok, status, loaded}

          {:error, reason} ->
            {:error, {:payroll_journal_lookup_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_register?(entry, register) do
    Enum.sum(Enum.map(entry.lines, & &1.debit_cents)) == register.total_cents and
      entry.entry_date == register.entry_date and same_lines?(entry.lines, register.lines)
  end

  defp period_check(period_module, org_id, %Date{year: year, month: month} = entry_date, :ready) do
    case period_module
         |> Ash.Query.filter(org_id == ^org_id and year == ^year and month == ^month)
         |> Ash.Query.limit(1)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        :ok

      {:ok, %{status: :open}} ->
        :ok

      {:ok, %{status: :soft_closed}} ->
        preflight_error(:period_soft_closed, %{entry_date: entry_date})

      {:ok, %{status: :closed}} ->
        preflight_error(:period_closed, %{entry_date: entry_date})

      {:ok, %{status: other}} ->
        preflight_error(:period_status_unknown, %{entry_date: entry_date, status: other})

      {:error, reason} ->
        preflight_error(:period_lookup_failed, %{entry_date: entry_date, reason: reason})
    end
  end

  defp period_check(_period_module, _org_id, _entry_date, _status), do: :ok

  defp preflight_error(code, details) do
    {:error, {:payroll_preflight_failed, [Map.put(details, :code, code)]}}
  end

  defp find_existing(entry_module, register) do
    case entry_module
         |> Ash.Query.filter(org_id == ^register.org_id and source_key == ^register.source_key)
         |> Ash.Query.limit(1)
         |> Ash.read_one(authorize?: false) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:payroll_journal_lookup_failed, reason}}
    end
  end

  defp existing_result(entry, register, import_module, imported_by, status) do
    existing_total = Enum.sum(Enum.map(entry.lines, & &1.debit_cents))

    with {:ok, _record} <- record_import(import_module, register, entry, status, imported_by) do
      if status == :imported do
        {:ok, result(entry, existing_total)}
      else
        {:error, :payroll_register_conflict}
      end
    end
  end

  defp same_lines?(existing_lines, register_lines) do
    line_fingerprint(existing_lines) == line_fingerprint(register_lines)
  end

  defp line_fingerprint(lines) do
    lines
    |> Enum.map(
      &{
        &1.account_id,
        &1.debit_cents,
        &1.credit_cents,
        &1.memo,
        dimension_fingerprint(&1.dimension_refs)
      }
    )
    |> Enum.sort()
  end

  defp dimension_fingerprint(%Ash.NotLoaded{}), do: :not_loaded

  defp dimension_fingerprint(refs) when is_map(refs) do
    refs
    |> Enum.map(fn {key, value} -> {canonical_key(key), canonical_value(value)} end)
    |> Enum.sort()
  end

  defp dimension_fingerprint(_), do: :none

  defp canonical_key(key) when is_atom(key) or is_binary(key), do: to_string(key)
  defp canonical_key(key), do: inspect(key)

  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_value(value), do: value

  defp create_draft(entry_module, import_module, register, imported_by) do
    attrs = %{
      org_id: register.org_id,
      entry_date: register.entry_date,
      memo: register.memo,
      source_key: register.source_key,
      lines: register.lines
    }

    actor = if imported_by, do: %{id: imported_by}, else: nil

    try do
      case entry_module
           |> Ash.Changeset.for_create(:create, attrs, actor: actor, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} ->
          with {:ok, _record} <-
                 record_import(import_module, register, entry, :imported, imported_by) do
            {:ok, result(entry, register.total_cents)}
          end

        {:error, reason} ->
          recover_create_error(entry_module, import_module, register, imported_by, reason)
      end
    rescue
      error ->
        if unique_payroll_key_violation?(error) do
          recover_existing(entry_module, import_module, register, imported_by, error)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  # The partial unique index is the guarantee; this path is the losing side of
  # a race (or a retry that reaches the insert after an earlier winner). Re-read
  # the winner and apply the same fingerprint check as the retry path.
  defp recover_create_error(entry_module, import_module, register, imported_by, reason) do
    if unique_payroll_key_violation?(reason) do
      recover_existing(entry_module, import_module, register, imported_by, reason)
    else
      {:error, {:payroll_journal_failed, reason}}
    end
  end

  defp recover_existing(entry_module, import_module, register, imported_by, original_error) do
    case find_existing(entry_module, register) do
      {:ok, nil} ->
        {:error, {:payroll_journal_failed, original_error}}

      {:ok, entry} ->
        case Ash.load(entry, [:lines], authorize?: false) do
          {:ok, loaded} ->
            status = if same_register?(loaded, register), do: :imported, else: :conflict
            existing_result(loaded, register, import_module, imported_by, status)

          {:error, reason} ->
            {:error, {:payroll_journal_lookup_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_import(import_module, register, entry, status, imported_by) do
    case find_import(import_module, register, status) do
      {:ok, nil} ->
        create_import(import_module, register, entry, status, imported_by)

      {:ok, existing} ->
        {:ok, existing}

      {:error, reason} ->
        {:error, {:payroll_import_lookup_failed, reason}}
    end
  end

  defp create_import(import_module, register, entry, status, imported_by) do
    attrs = %{
      org_id: register.org_id,
      provider: register.provider,
      external_id: register.external_id,
      line_set_hash: register.line_set_hash,
      total_cents: register.total_cents,
      entry_date: register.entry_date,
      imported_at: DateTime.utc_now() |> DateTime.truncate(:second),
      imported_by: imported_by,
      status: status,
      entry_id: entry.id,
      supersedes_id: Map.get(register, :supersedes_id)
    }

    try do
      case import_module
           |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, record} -> {:ok, record}
        {:error, reason} -> recover_import(import_module, register, status, reason)
      end
    rescue
      error ->
        if unique_payroll_key_violation?(error) do
          recover_import(import_module, register, status, error)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp recover_import(import_module, register, status, original_error) do
    if unique_payroll_key_violation?(original_error) do
      case find_import(import_module, register, status) do
        {:ok, nil} -> {:error, {:payroll_import_failed, original_error}}
        {:ok, existing} -> {:ok, existing}
        {:error, reason} -> {:error, {:payroll_import_lookup_failed, reason}}
      end
    else
      {:error, {:payroll_import_failed, original_error}}
    end
  end

  # Match the same status the caller is recording. A conflict row is retained
  # as history when a later amendment imports the same line set successfully;
  # the database has separate partial unique indexes for the two states.
  defp find_import(import_module, register, import_status) do
    import_module
    |> Ash.Query.filter(
      org_id == ^register.org_id and provider == ^register.provider and
        external_id == ^register.external_id and
        line_set_hash == ^register.line_set_hash and entry_date == ^register.entry_date and
        status == ^import_status
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp unique_payroll_key_violation?(%Postgrex.Error{
         postgres: %{code: :unique_violation}
       }),
       do: true

  defp unique_payroll_key_violation?(%Ecto.ConstraintError{type: :unique}), do: true

  defp unique_payroll_key_violation?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &unique_payroll_key_violation?/1)

  defp unique_payroll_key_violation?(%{error: error}),
    do: unique_payroll_key_violation?(error)

  defp unique_payroll_key_violation?(error) do
    message =
      cond do
        is_binary(error) -> error
        is_map(error) -> Exception.message(error)
        true -> ""
      end

    String.contains?(message, "unique_violation") or
      String.contains?(message, "unique_constraint") or
      String.contains?(message, "Ecto.ConstraintError") or
      String.contains?(message, "sje_payroll_register_source_key_unique") or
      String.contains?(message, "ecj_payroll_register_source_key_unique")
  rescue
    _ -> false
  end

  defp result(entry, total_cents) do
    %{journal_entry_id: entry.id, total_cents: total_cents}
  end

  defp source_key(provider, external_id) do
    "#{@source_key_prefix}:#{URI.encode_www_form(provider)}:#{URI.encode_www_form(external_id)}"
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
