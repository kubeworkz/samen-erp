defmodule Mix.Tasks.Samen.Verify.ReplaySchema do
  @shortdoc "Lane B P1: the masked-replay frame schema and capture vocabulary must stay closed."

  @moduledoc """
  `mix samen.verify.replay_schema` — **the masked-replay schema gate** (ADR-052 §3 R6, Lane B P1).

  ## Why this exists

  A session replay is the one feature whose *storage* is the whole risk: the value it records is
  exactly the value the vault exists to keep out of Postgres. ADR-052 answers that with an
  **allowlist** — a frame can only contain the closed capture vocabulary and a declared set of
  payload keys — and this task is the check that the allowlist is still an allowlist. Without it the
  schema decays the usual way: someone adds a frame kind with no key policy, widens a closed set,
  puts a `vt_` token in the vocabulary, or (the failure that matters) **neuters a refusal in
  `validate/1` so the schema still looks right while nothing is refused any more**.

  So the checks come in two halves, and the second half is the load-bearing one:

    * **declaration** — the schema snapshot (`Samen.Replay.FrameSchema.snapshot/0`) must declare
      at least five frame kinds, a payload key policy for every kind (and no policy for an
      undeclared kind), a non-empty bounded key set wherever the set is closed, a keep-list whose
      entries are bounded keys, `max_payload_bytes/0` positive and within
      `hard_payload_ceiling/0`, no `vt_`/PII-shaped/carrier-like kind, key or keep-list entry;
    * **behaviour** — the REAL `validate/1` is driven with tampered frames (a plaintext string, a
      bare `vt_` token, an unknown kind, a key outside a closed set, an oversized payload) and with
      every keep-listed key carrying a PII-shaped value, and `Samen.Replay.Values.sanitize/2` is
      probed for fail-honesty. **Every one of those must still be refused** — a gate that only reads
      declarations cannot notice a refusal that stopped firing.

  Anti-vacuity: the floors above are asserted (a schema that shrinks below them fails), the
  behavioural probes are paired with a control asserting the vocabulary itself rejects a plaintext
  string, and each declaration check is refutable by feeding `violations/1` a tampered snapshot.

  ## What it is NOT

  It does not prove that a *host* recorded safely: capture itself is P2 (`Samen.Replay.Values.sanitize/2`
  raises `:not_implemented` at P1 — fail-honest, ADR-014) and the recording rules are asserted there.
  This gate is the contract P2's capture has to satisfy, and it fails closed the moment that contract
  is weakened.

  ## Exit code (fail-closed)

  Exits 0 when the schema is clean, 1 otherwise (via `Samen.Verifier.halt_if_violations/3`).
  Sabotage-refutable at `scripts/sabotages/350-*`, which removes a refusal from `validate/1` and
  turns this task red.

  ## Usage

      mix samen.verify.replay_schema
      mix samen.verify.replay_schema --format json
  """

  use Mix.Task

  alias Samen.Replay.FrameSchema

  @task_name "samen.verify.replay_schema"

  # Test seam (red-path exit-code proof), mirroring `samen.verify.sink_schema`'s injected field:
  # the named frame kind is appended to the DECLARATION snapshot with no payload key policy, so
  # the `:kind_coverage` check fires and the subprocess red-path test can prove exit 1 WITHOUT
  # mutating the real schema source. Absent in every non-test invocation.
  @inject_env "SAMEN_REPLAY_SCHEMA_INJECT_KIND_WITHOUT_POLICY"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [Samen.Verifier.format_switch()])

    Mix.Task.run("app.start")

    {format, format_violations} = Samen.Verifier.resolve_format(opts)

    Samen.Verifier.halt_if_violations(
      @task_name,
      format_violations ++ FrameSchema.violations(inject_kind: injected_kind()),
      format: format
    )
  end

  defp injected_kind do
    case System.get_env(@inject_env) do
      nil -> nil
      name -> String.to_atom(name)
    end
  end
end
