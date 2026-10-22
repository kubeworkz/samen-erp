defmodule Samen.Scopes.Docs.Audit do
  @moduledoc """
  Audit writers for the Docs scope (ADR-053 §2 D5).

  A scope never defines its own audit table. This module writes token-only rows to the existing
  `aud_event` tier (and its `aud_chain` link, via `Samen.AuditChain.Writer`) — append-only,
  partitioned, REVOKE+trigger-guarded.

  ## `docs.block.declassified` — the one record that a block LEFT the vault

  `Samen.Scopes.Docs.BlockDeclassify` moves a vaulted block's plaintext into the plain `text`
  column and clears `text_secure`. That is the single write in the whole scope that REDUCES a
  classification, so it is the one that most needs a row an auditor can find later: who did it,
  to which block, in which revision, and why.

  The `detail` is composed (`event=… field=… revision=… reason=…`), which
  `Samen.AuditChain.Writer` scans with `Samen.PiiReasonScan` before writing — a caller whose
  `reason` is itself a bare email/SSN/phone shape is REFUSED rather than committing that value
  into the non-shreddable chain. The block's TEXT is never part of the row: the subject is the
  block id, the actor is an opaque id, and the revision is a number.
  """

  @doc """
  Emit a `docs.block.declassified` event for `block`.

  `org_id` is the ACTOR's acting org (the policy bound it; never read it off the result struct —
  a non-public attribute is `%Ash.NotLoaded{}` on an update result). `block` must expose `:id` and
  `:revision` (the post-write record). `actor_id` is the acting user's opaque id; `reason` is the
  operator-authored justification the action required.

  Returns `{:ok, _}` or `{:error, reason}` — the caller treats an error as a FAILED action (the
  declassification is rolled back rather than landing unaudited).
  """
  @spec text_declassified(module(), String.t(), map(), String.t() | nil, String.t()) ::
          {:ok, term()} | {:error, term()}
  def text_declassified(repo, org_id, block, actor_id, reason) do
    Samen.AuditChain.Writer.write(repo, %{
      org_id: to_string(org_id),
      event_type: "system",
      subject_id: to_string(block.id),
      actor_id: actor_id,
      correlation_id: org_id,
      detail:
        "docs.block.declassified field=text_secure revision=#{block.revision} " <>
          "reason=#{reason}"
    })
  end
end
