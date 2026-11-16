defmodule Samen.Hr.PayrollProvider do
  @moduledoc """
  The payroll adapter boundary (WS-ERP E7; design §5 — "Payroll: fail-honest
  by construction"). WS-ERP ships NO payroll calculation engine: tax and
  withholding are jurisdiction-specific, and half-claimed payroll is the worst
  kind of lie.

  A host brings a provider by implementing this behaviour and registering it:

      config :samen_core, Samen.Hr.PayrollProvider, provider: MyApp.Payroll

  or by passing `provider: MyApp.Payroll` in `opts` (opts win over config, the
  `Samen.Automation.Remind` convention). The DEFAULT implementation is
  `Samen.Hr.PayrollProvider.NotConfigured`, whose `run_payroll/3` returns
  `{:error, :not_configured}` — a caller that asks WS-ERP to compute payroll
  gets an honest refusal, never a fabricated number.

  ## The contract

      @callback run_payroll(org_id :: binary(), period :: Date.t(), opts :: keyword()) ::
                  {:ok, %{journal_entry_id: binary(), total_cents: pos_integer()}}
                  | {:error, :not_configured | term()}

  A REAL provider journals its results through the Finance scope — the GL
  records payroll *postings*; it never *computes* them. `EmploymentEvent
  :comp_changed` rows carry the comp facts a provider (or a human journaling
  through Finance) consumes.

  ## Reference integration (import, never calculate)

  `Samen.Hr.Payroll.JournalProvider` is the shipped reference adapter. The
  external payroll system supplies a balanced register of GL lines; the adapter
  validates it and lands a **draft** `JournalEntry` through the host's normal
  `:create` action. It reads no hours, rates, gross, net, tax or deduction
  fields and calls no `:post` — the host's journal approval/posting path stays
  the only door into the ledger. Re-importing the same
  `provider`/`external_id` returns the existing entry; a changed entry date,
  total or line set is refused. The anchor is backed by a partial unique index,
  so concurrent importers converge on one draft instead of duplicating it. A
  new host mount must carry the equivalent partial unique index in its Finance
  migration.

      config :samen_core, Samen.Hr.PayrollProvider,
        provider: Samen.Hr.Payroll.JournalProvider

      config :samen_core, Samen.Hr.Payroll.JournalProvider,
        entry_module: MyApp.Finance.JournalEntry

  Those two halves are an all-or-nothing opt-in: the kernel boot guard
  (`Samen.Hr.Payroll.JournalProvider.assert_wiring!/0`) refuses a host that
  sets only one. A provider-specific adapter that computes or fetches payroll
  remains the host's choice; the reference adapter is deliberately not one.

  ## Declared-not-built (the honest-claims discipline)

  The default's refusal is pinned by a test (`Samen.HrScopeTest`): calling
  through the unwired seam refuses `{:error, :not_configured}`. This is the
  ADR-014 adapter-posture shape: the boundary is real, the default is
  fail-honest, and nothing pretends to compute what it does not.
  """

  @callback run_payroll(org_id :: binary(), period :: Date.t(), opts :: keyword()) ::
              {:ok, %{journal_entry_id: binary(), total_cents: pos_integer()}}
              | {:error, :not_configured | term()}

  @doc """
  The configured provider module, or the `NotConfigured` default. Opts win over
  config (the test/caller override seam).
  """
  @spec provider(keyword()) :: module()
  def provider(opts \\ []) do
    case Keyword.fetch(opts, :provider) do
      {:ok, mod} ->
        mod

      :error ->
        case Application.get_env(:samen_core, __MODULE__, []) do
          %{provider: mod} ->
            mod

          kw when is_list(kw) ->
            Keyword.get(kw, :provider, Samen.Hr.PayrollProvider.NotConfigured)

          _ ->
            Samen.Hr.PayrollProvider.NotConfigured
        end
    end
  end

  @doc """
  Run payroll for `org_id` over `period` through the configured provider. The
  default (unwired) seam refuses `{:error, :not_configured}` — fail-honest.
  """
  @spec run_payroll(binary(), Date.t(), keyword()) ::
          {:ok, %{journal_entry_id: binary(), total_cents: pos_integer()}}
          | {:error, :not_configured | term()}
  def run_payroll(org_id, %Date{} = period, opts \\ []) do
    provider(opts).run_payroll(org_id, period, opts)
  end

  defmodule NotConfigured do
    @moduledoc """
    The default `Samen.Hr.PayrollProvider`: **refuses everything** with
    `{:error, :not_configured}`. WS-ERP computes no payroll — a host brings a
    provider, or journals comp expense through the Finance scope manually.
    Fail-honest by construction (design §5): the worst answer a payroll system
    can give is a confident wrong number; this seam refuses to give any number
    at all until a host deliberately installs one.
    """

    @behaviour Samen.Hr.PayrollProvider

    @impl true
    def run_payroll(_org_id, _period, _opts), do: {:error, :not_configured}
  end
end
