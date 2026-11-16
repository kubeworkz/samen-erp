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
          %{account_code: "6000", debit_cents: 125_000},
          %{account_code: "2100", credit_cents: 125_000}
        ]
      }

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
  provider that changes a payroll run must correct it through a reversing entry,
  not by reusing its external id.

  Every successful import also lands one `PayrollImport` provenance row with
  the provider/external id, line-set hash, total, entry date, imported-at/by
  and status, linked to the draft. A refused replay under the same identity
  lands (or reuses) a `:conflict` row linked to the existing entry instead of
  overwriting the successful provenance. The hash covers only normalized GL
  lines; no raw register or employee data is stored or hashed.

  A host mount must carry the equivalent partial unique index in its Finance
  migration (the core fixture and `samenerp` host migrations do). The adapter
  does not fall back to a read-then-create guarantee.

  ## Configuration

      config :samen_core, Samen.Hr.PayrollProvider,
        provider: Samen.Hr.Payroll.JournalProvider

      config :samen_core, Samen.Hr.Payroll.JournalProvider,
        entry_module: MyApp.Finance.JournalEntry,
        import_module: MyApp.Finance.PayrollImport,
        mapping_module: MyApp.Finance.PayrollAccountMapping,
        period_module: MyApp.Finance.FiscalPeriod

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

  A host must configure all four or neither; the kernel boot guard
  (`assert_wiring!/0`) refuses a half-wired host.

  `period` is the caller's payroll period label. The journal date is the
  register's explicit `entry_date`; the adapter does not infer one.
  """

  @behaviour Samen.Hr.PayrollProvider

  require Ash.Query

  @source_key_prefix "payroll_register"
  @config_key __MODULE__

  @impl true
  def run_payroll(org_id, %Date{} = _period, opts) when is_binary(org_id) do
    with {:ok, config} <- config(opts),
         {:ok, imported_by} <- imported_by(opts),
         {:ok, report} <- validate(org_id, opts) do
      import_report(config, report, imported_by)
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
    case find_import(import_module, register) do
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
      entry_id: entry.id
    }

    try do
      case import_module
           |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, record} -> {:ok, record}
        {:error, reason} -> recover_import(import_module, register, reason)
      end
    rescue
      error ->
        if unique_payroll_key_violation?(error) do
          recover_import(import_module, register, error)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp recover_import(import_module, register, original_error) do
    if unique_payroll_key_violation?(original_error) do
      case find_import(import_module, register) do
        {:ok, nil} -> {:error, {:payroll_import_failed, original_error}}
        {:ok, existing} -> {:ok, existing}
        {:error, reason} -> {:error, {:payroll_import_lookup_failed, reason}}
      end
    else
      {:error, {:payroll_import_failed, original_error}}
    end
  end

  defp find_import(import_module, register) do
    import_module
    |> Ash.Query.filter(
      org_id == ^register.org_id and provider == ^register.provider and
        external_id == ^register.external_id and
        line_set_hash == ^register.line_set_hash and entry_date == ^register.entry_date
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
