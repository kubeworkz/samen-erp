defmodule Samen.Hr.PayrollWiringTest do
  use ExUnit.Case, async: false

  alias Samen.Hr.Payroll.JournalProvider
  alias Samen.Hr.PayrollProvider

  setup do
    journal_previous = Application.get_env(:samen_core, JournalProvider)
    provider_previous = Application.get_env(:samen_core, PayrollProvider)

    on_exit(fn ->
      restore(JournalProvider, journal_previous)
      restore(PayrollProvider, provider_previous)
    end)

    Application.delete_env(:samen_core, JournalProvider)
    Application.delete_env(:samen_core, PayrollProvider)

    :ok
  end

  test "accepts no payroll wiring" do
    assert :ok = JournalProvider.assert_wiring!()
  end

  test "accepts a complete reference wiring" do
    Application.put_env(:samen_core, PayrollProvider, provider: JournalProvider)

    Application.put_env(:samen_core, JournalProvider,
      entry_module: __MODULE__,
      import_module: __MODULE__
    )

    assert :ok = JournalProvider.assert_wiring!()
  end

  test "refuses an entry module without selecting the reference provider" do
    Application.put_env(:samen_core, JournalProvider, entry_module: __MODULE__)

    assert_raise RuntimeError, ~r/payroll miswired/, fn ->
      JournalProvider.assert_wiring!()
    end
  end

  test "refuses the reference provider without an entry module" do
    Application.put_env(:samen_core, PayrollProvider, provider: JournalProvider)

    assert_raise RuntimeError, ~r/:entry_module/, fn ->
      JournalProvider.assert_wiring!()
    end
  end

  test "refuses the reference provider without an import module" do
    Application.put_env(:samen_core, PayrollProvider, provider: JournalProvider)
    Application.put_env(:samen_core, JournalProvider, entry_module: __MODULE__)

    assert_raise RuntimeError, ~r/:import_module/, fn ->
      JournalProvider.assert_wiring!()
    end
  end

  test "refuses stale entry-module config beside a custom provider" do
    Application.put_env(:samen_core, PayrollProvider, provider: __MODULE__)
    Application.put_env(:samen_core, JournalProvider, entry_module: __MODULE__)

    assert_raise RuntimeError, ~r/payroll miswired/, fn ->
      JournalProvider.assert_wiring!()
    end
  end

  test "refuses stale import-module config beside a custom provider" do
    Application.put_env(:samen_core, PayrollProvider, provider: __MODULE__)
    Application.put_env(:samen_core, JournalProvider, import_module: __MODULE__)

    assert_raise RuntimeError, ~r/payroll miswired/, fn ->
      JournalProvider.assert_wiring!()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, value), do: Application.put_env(:samen_core, key, value)
end
