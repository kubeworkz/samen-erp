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

  ## Declared-not-built (the honest-claims discipline)

  The default's refusal is pinned by a test (`Samen.Hr.PayrollTest`): calling
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
          %{provider: mod} -> mod
          kw when is_list(kw) -> Keyword.get(kw, :provider, Samen.Hr.PayrollProvider.NotConfigured)
          _ -> Samen.Hr.PayrollProvider.NotConfigured
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
