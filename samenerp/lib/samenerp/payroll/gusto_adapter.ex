defmodule Samenerp.Payroll.GustoAdapter do
  @moduledoc """
  The ONE provider-specific payroll adapter: Gusto, as the design partner.

  This is deliberately a **host-local design-partner adapter**, not a provider
  framework and not a package-per-vendor family. A second partner is the trigger
  to extract a shared adapter package; until then, one adapter with one honest
  mapping is cheaper and safer than a provider menu.

  ## Transport (the shared contract authenticates the relay)

  Gusto's native webhook is a refs-only event (`uuid`, `event_type`,
  `entity_uuid`, `timestamp`) signed with `X-Gusto-Signature` over the raw body.
  This adapter does **not** add a second signature scheme. The design partner's
  relay verifies the native Gusto signature against the Gusto verification
  token, fetches the payroll object, and submits it through the SAME signed
  provider-ingestion contract every connector uses (`Samen-Ingest-Signature`,
  timestamp, idempotency key, schema version, bounded retries). That keeps one
  security/audit posture instead of a vendor-specific bypass.

  ## Envelope payload

  The shared contract envelope carries:

      {
        "schema_version": 1,
        "event_id": "<gusto event uuid>",
        "event_type": "payroll.paid",
        "occurred_at": "<gusto event timestamp>",
        "payload": { "payroll": <Gusto payroll object, totals + refs only> }
      }

  `Samen.Ingest.Provider.redact_payload/1` runs BEFORE persistence and keeps
  only `payroll_uuid`, `check_date`, the pay-period bounds and the five
  provider-computed money totals. Employee compensations, names, emails, SSNs,
  bank details, tax-line names and benefit detail never reach the store.

  ## Mapping (no payroll arithmetic)

  Gusto's own totals satisfy:

      company_debit = net_pay_debit + tax_debit + reimbursement_debit + child_support_debit

  The adapter asserts that invariant and refuses an unbalanced payload. It then
  emits one `Samen.Hr.Payroll.JournalProvider` register under provider `"gusto"`:

    * DEBIT  `gusto:company_debit`         — total provider-computed company cost
    * CREDIT `gusto:net_pay`               — net pay debit
    * CREDIT `gusto:tax_debit`             — tax debit
    * CREDIT `gusto:reimbursement_debit`   — reimbursement debit (omitted when zero)
    * CREDIT `gusto:child_support_debit`   — child-support debit (omitted when zero)

  The host's payroll account mapping (`Samenerp.Erp.PayrollAccountMapping`)
  resolves those five external codes to its own accounts. `run_payroll/3` still
  lands a **draft** and runs the existing mapping/preflight/period/duplicate
  checks; this adapter never posts and never computes gross, net, tax, hours or
  rates.

  Only `payroll.paid` imports. Other Gusto lifecycle events are acknowledged
  as a no-op (`:ok`) and remain in the audit store with their `event_type` —
  stored but not dispatched. They never produce a fabricated import.

  ## Host wiring (one design partner, one org)

      config :samen_core, Samen.Ingest,
        repo: Samenerp.Repo,
        providers: %{
          "gusto" =>
            {Samenerp.Payroll.GustoAdapter,
             %{
               secret: System.fetch_env!("GUSTO_INGEST_SECRET"),
               org_id: System.fetch_env!("GUSTO_ORG_ID"),
               schema_versions: [1],
               max_attempts: 8
             }}
        }

  The secret is the design partner relay's shared signing secret, NOT Gusto's
  webhook verification token. Multi-org routing is deliberately out of scope
  for the first partner.
  """

  @behaviour Samen.Ingest.Provider

  alias Samen.Ingest.Contract.Envelope

  @provider "gusto"
  @imported_by "provider:gusto"

  @total_keys ~w(
    company_debit
    net_pay_debit
    tax_debit
    reimbursement_debit
    child_support_debit
  )

  @money ~r/^(\d+)(?:\.(\d{1,2}))?$/

  # ---------------------------------------------------------------------------
  # Ingestion adapter callbacks

  @impl true
  def redact_payload(%{"payroll" => payroll}) when is_map(payroll) do
    %{
      "payroll" =>
        payroll
        |> strings(["payroll_uuid", "check_date"], 200)
        |> Map.put("pay_period", strings(payroll["pay_period"], ["start_date", "end_date"], 40))
        |> Map.put("totals", strings(payroll["totals"], @total_keys, 40))
    }
  end

  def redact_payload(_payload), do: %{}

  @impl true
  def handle(%Envelope{event_type: "payroll.paid"} = envelope, opts) do
    with {:ok, org_id} <- org_id(Keyword.get(opts, :config) || %{}),
         {:ok, period, register} <- build_register(envelope.payload) do
      import_register(org_id, period, register)
    else
      {:error, reason} -> {:discard, reason}
    end
  end

  # Every other Gusto lifecycle event is intentionally stored but not dispatched.
  def handle(%Envelope{}, _opts), do: :ok

  # ---------------------------------------------------------------------------
  # Redaction — scalar allowlist only

  defp strings(map, keys, max) when is_map(map) do
    for {key, value} <- Map.take(map, keys),
        is_binary(value),
        byte_size(value) <= max,
        into: %{},
        do: {key, value}
  end

  defp strings(_value, _keys, _max), do: %{}

  # ---------------------------------------------------------------------------
  # Register construction

  defp org_id(config) do
    case Map.get(config, :org_id) do
      org when is_binary(org) and org != "" -> {:ok, org}
      _ -> {:error, :org_not_configured}
    end
  end

  defp build_register(%{"payroll" => %{} = payroll}) do
    with {:ok, external_id} <- payroll_uuid(payroll),
         {:ok, entry_date} <- check_date(payroll),
         {:ok, period} <- pay_period(payroll, entry_date),
         {:ok, totals} <- totals(payroll["totals"]),
         {:ok, lines} <- lines(totals) do
      {:ok, period,
       %{
         provider: @provider,
         external_id: external_id,
         entry_date: entry_date,
         lines: lines
       }}
    end
  end

  defp build_register(_payload), do: {:error, :malformed_payload}

  defp payroll_uuid(payroll) do
    case payroll["payroll_uuid"] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :payroll_uuid_required}
          uuid -> {:ok, uuid}
        end

      _ ->
        {:error, :payroll_uuid_required}
    end
  end

  defp check_date(%{"check_date" => value}) when is_binary(value) do
    parse_date(value, :check_date_invalid)
  end

  defp check_date(_payroll), do: {:error, :check_date_invalid}

  defp pay_period(%{"pay_period" => %{"start_date" => value}}, _fallback)
       when is_binary(value) do
    parse_date(value, :pay_period_invalid)
  end

  defp pay_period(_payroll, fallback), do: {:ok, fallback}

  defp parse_date(value, error) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, error}
    end
  end

  defp totals(%{} = raw) do
    Enum.reduce_while(@total_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case cents(raw[key]) do
        {:ok, amount} -> {:cont, {:ok, Map.put(acc, key, amount)}}
        :error -> {:halt, {:error, :totals_invalid}}
      end
    end)
  end

  defp totals(_raw), do: {:error, :totals_missing}

  defp lines(totals) do
    debit = totals["company_debit"]

    credits = [
      {"gusto:net_pay", totals["net_pay_debit"]},
      {"gusto:tax_debit", totals["tax_debit"]},
      {"gusto:reimbursement_debit", totals["reimbursement_debit"]},
      {"gusto:child_support_debit", totals["child_support_debit"]}
    ]

    credit_total = credits |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    cond do
      debit <= 0 ->
        {:error, :totals_non_positive}

      credit_total != debit ->
        {:error, :totals_unbalanced}

      true ->
        credit_lines =
          for {code, amount} <- credits, amount > 0 do
            %{account_code: code, credit_cents: amount}
          end

        {:ok, [%{account_code: "gusto:company_debit", debit_cents: debit} | credit_lines]}
    end
  end

  # Exact decimal-string to integer cents; no float arithmetic. Amounts with
  # more than two decimals are refused rather than rounded silently.
  defp cents(value) when is_binary(value) and byte_size(value) <= 40 do
    case Regex.run(@money, String.trim(value)) do
      [_, whole] ->
        {:ok, String.to_integer(whole) * 100}

      [_, whole, fraction] ->
        {:ok,
         String.to_integer(whole) * 100 +
           String.to_integer(String.pad_trailing(fraction, 2, "0"))}

      _ ->
        :error
    end
  end

  defp cents(_value), do: :error

  # ---------------------------------------------------------------------------
  # The existing draft-import path

  defp import_register(org_id, period, register) do
    case Samen.Hr.PayrollProvider.run_payroll(org_id, period,
           register: register,
           imported_by: @imported_by
         ) do
      {:ok, %{journal_entry_id: _entry_id}} ->
        :ok

      {:error, :not_configured} ->
        {:discard, :payroll_not_configured}

      {:error, :payroll_register_conflict} ->
        {:discard, :payroll_register_conflict}

      {:error, {:payroll_preflight_failed, _errors}} ->
        {:discard, :payroll_preflight_failed}

      {:error, {:invalid_payroll_register, _reason}} ->
        {:discard, :invalid_payroll_register}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
