defmodule Samenerp.DataCase do
  @moduledoc "ExUnit case template for database-backed Samenerp tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Samenerp.Repo
      import Samenerp.DataCase
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Samenerp.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Samenerp.Repo, {:shared, self()})
    :ok
  end
end
