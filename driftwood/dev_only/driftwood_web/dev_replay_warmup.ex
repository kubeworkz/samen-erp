defmodule DriftwoodWeb.DevReplayWarmup do
  @moduledoc """
  Pre-loads this host's modules before the dev-only `phoenix_replay` dashboard decodes a
  recording (WS-Masked-Replay P0).

  ## Why this exists

  `PhoenixReplay.Storage.Codec.decode/2` first tries `:erlang.binary_to_term(..., [:safe])`.
  Safe decoding refuses atoms the VM has not created yet, and a recording holds module atoms
  (the structs in the recorded assigns). On a fresh dev node those modules may exist on the code
  path without being loaded, so the first decode fails and the codec calls
  `load_available_modules/0` — which runs `:code.ensure_loaded/1` for **every** available module
  on the machine, dependencies included, one synchronous `:code_server` call each.

  Measured on this host (Windows, cold dev node): the first `GET /dev/replay/<id>` took
  **~90 s** and every later one 0.36 s — the difference is that sweep. Touching the app's own
  modules first is a few hundred cheap loads and makes the first `:safe` decode succeed, so the
  sweep never runs.

  ## Scope

  Dev-only by construction: this module lives in `dev_only/`, is compiled only in `:dev`, and is
  plugged only in the dev-replay router's scope. It loads modules; it reads no data and writes
  nothing.
  """

  # The apps whose structs a driftwood recording can name. Deliberately NOT every dependency:
  # pre-loading our own apps is cheap and covers the assigns a tenant/operator page records.
  @apps [:driftwood, :samen_web, :samen_core]
  @flag {__MODULE__, :warmed?}

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    warm!()
    conn
  end

  @doc """
  Load this host's modules once per node. Idempotent and cheap after the first call.
  """
  @spec warm!() :: :ok
  def warm! do
    if :persistent_term.get(@flag, false) do
      :ok
    else
      for app <- @apps,
          modules when is_list(modules) <- [Application.spec(app, :modules)],
          module <- modules do
        :code.ensure_loaded(module)
      end

      :persistent_term.put(@flag, true)
      :ok
    end
  end
end
