defmodule PawChart.DataCase do
  @moduledoc "ExUnit case template for database-backed PawChart tests."
  defmacro __using__(opts) do
    if Keyword.get(opts, :async, false) do
      raise ArgumentError, """
      #{inspect(__CALLER__.module)} must not use #{inspect(__MODULE__)} with async: true.

      DataCase setup checks out a SQL sandbox connection and puts it in shared mode.
      ExUnit's shared sandbox mode is suite-global, so an async DataCase test can
      hand its connection to a concurrent test and crash it when the owner exits.

      Remove `async: true` from the `use #{inspect(__MODULE__)}` call.
      """
    end

    quote do
      use ExUnit.Case, unquote(opts)
      alias PawChart.Repo
      import PawChart.DataCase

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(PawChart.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(PawChart.Repo, {:shared, self()})
        :ok
      end
    end
  end
end
