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
          %{account_id: salary_expense_id, debit_cents: 125_000},
          %{account_id: payroll_payable_id, credit_cents: 125_000}
        ]
      }

  Every line names a same-org `Finance.Account` and exactly one non-zero
  integer-cents side. The register must balance. No `gross`, `net`, `tax`,
  `hours` or `rate` fields are read — if the external provider supplied them,
  they are not used as arithmetic inputs here. The register is the external
  system's result, not a prompt for us to compute one.

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
        import_module: MyApp.Finance.PayrollImport

  The `import_module` is the Finance scope's `PayrollImport` resource. It
  stores the durable provenance row (provider, external id, normalized
  line-set hash, total, timestamp, importer, status and linked draft entry).
  A mount that has not wired this module fails honest with
  `{:error, :not_configured}`. The provider can also be passed explicitly:

      Samen.Hr.PayrollProvider.run_payroll(org_id, period,
        provider: Samen.Hr.Payroll.JournalProvider,
        entry_module: MyApp.Finance.JournalEntry,
        import_module: MyApp.Finance.PayrollImport,
        imported_by: "u:controller",
        register: register
      )

  A host must configure all three or neither; the kernel boot guard
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
    with {:ok, entry_module} <- entry_module(opts),
         {:ok, import_module} <- import_module(opts),
         {:ok, imported_by} <- imported_by(opts),
         {:ok, raw_register} <- register(opts),
         {:ok, register} <- normalize(raw_register, org_id) do
      import_register(entry_module, import_module, register, imported_by)
    end
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

  defp import_register(entry_module, import_module, register, imported_by) do
    case find_existing(entry_module, register) do
      {:ok, nil} -> create_draft(entry_module, import_module, register, imported_by)
      {:ok, entry} -> existing_result(entry, register, import_module, imported_by)
      {:error, reason} -> {:error, reason}
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
  Refuse a half-wired payroll importer at host boot.

  The reference importer is opt-in in three parts: `Samen.Hr.PayrollProvider`
  must select this module, and this module must have both an `entry_module`
  and an `import_module`. A partial opt-in is a silent no-op/miswire, so all
  three must be present or none. A custom payroll provider does not need this
  module's wiring; setting it alongside a different provider is also rejected
  as stale config.
  """
  @spec assert_wiring!() :: :ok
  def assert_wiring! do
    provider = Samen.Hr.PayrollProvider.provider()
    entry_module = configured_entry_module()
    import_module = configured_import_module()

    cond do
      provider == __MODULE__ and (is_nil(entry_module) or is_nil(import_module)) ->
        raise """
        payroll miswired: Samen.Hr.PayrollProvider selects
        #{inspect(__MODULE__)} but #{inspect(@config_key)} is missing
        #{missing_wiring(entry_module, import_module)}.
        Configure all three or neither:
          config :samen_core, Samen.Hr.PayrollProvider,
            provider: Samen.Hr.Payroll.JournalProvider
          config :samen_core, Samen.Hr.Payroll.JournalProvider,
            entry_module: MyApp.Finance.JournalEntry,
            import_module: MyApp.Finance.PayrollImport
        """

      provider != __MODULE__ and (not is_nil(entry_module) or not is_nil(import_module)) ->
        raise """
        payroll miswired: #{inspect(@config_key)} configures
        #{stale_wiring(entry_module, import_module)} but
        Samen.Hr.PayrollProvider selects #{inspect(provider)}. Configure all
        three or neither:
          config :samen_core, Samen.Hr.PayrollProvider,
            provider: Samen.Hr.Payroll.JournalProvider
          config :samen_core, Samen.Hr.Payroll.JournalProvider,
            entry_module: MyApp.Finance.JournalEntry,
            import_module: MyApp.Finance.PayrollImport
        """

      true ->
        :ok
    end
  end

  defp missing_wiring(nil, _import_module), do: ":entry_module"
  defp missing_wiring(_entry_module, nil), do: ":import_module"
  defp missing_wiring(_entry_module, _import_module), do: "wiring"

  defp stale_wiring(entry_module, nil), do: ":entry_module #{inspect(entry_module)}"
  defp stale_wiring(nil, import_module), do: ":import_module #{inspect(import_module)}"

  defp stale_wiring(entry_module, import_module) do
    ":entry_module #{inspect(entry_module)} and :import_module #{inspect(import_module)}"
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
           source_key: source_key(provider, external_id),
           line_set_hash: line_set_hash(lines)
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
      lines when is_list(lines) and lines != [] -> normalize_lines(lines)
      _ -> {:error, {:invalid_payroll_register, :lines}}
    end
  end

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
         {:ok, account_id} <- line_string(line, :account_id, index, :account_id_required),
         {:ok, debit_cents} <- amount(line, :debit_cents, index),
         {:ok, credit_cents} <- amount(line, :credit_cents, index),
         :ok <- one_side(debit_cents, credit_cents, index),
         {:ok, line_memo} <- line_memo(line, index),
         {:ok, dimension_refs} <- dimension_refs(line, index) do
      {:ok,
       %{
         account_id: account_id,
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

  defp find_existing(entry_module, register) do
    case entry_module
         |> Ash.Query.filter(org_id == ^register.org_id and source_key == ^register.source_key)
         |> Ash.Query.limit(1)
         |> Ash.read_one(authorize?: false) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:payroll_journal_lookup_failed, reason}}
    end
  end

  defp existing_result(entry, register, import_module, imported_by) do
    case Ash.load(entry, [:lines], authorize?: false) do
      {:ok, loaded} ->
        existing_total = Enum.sum(Enum.map(loaded.lines, & &1.debit_cents))

        matched? =
          existing_total == register.total_cents and loaded.entry_date == register.entry_date and
            same_lines?(loaded.lines, register.lines)

        status = if matched?, do: :imported, else: :conflict

        with {:ok, _record} <-
               record_import(import_module, register, loaded, status, imported_by) do
          if matched? do
            {:ok, result(loaded, existing_total)}
          else
            {:error, :payroll_register_conflict}
          end
        end

      {:error, reason} ->
        {:error, {:payroll_journal_lookup_failed, reason}}
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
      {:ok, nil} -> {:error, {:payroll_journal_failed, original_error}}
      {:ok, entry} -> existing_result(entry, register, import_module, imported_by)
      {:error, reason} -> {:error, reason}
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
