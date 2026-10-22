defmodule Samen.Scopes.Docs.BlockVault do
  @moduledoc """
  The **one-way door** on a block's vault column (ADR-053 §2 D5 / §5 "the PII pair is per block").

  A `Docs.DocBlock` carries the `text` / `text_secure` pair: `text` is plain (and `FreeTextScan`-
  guarded), `text_secure` is a `pii_attribute` (`vault: :pii_block_text`). The classification is a
  DECLARED choice at the write site — which column the caller writes — and this module makes the
  declared choice **irreversible from inside the model**: an update may never clear `text_secure`.

  ## Why the MODEL, not the write helper

  `Samen.Web.Notes.Writes.update_text/5` reads the row and puts an ordinary edit of a 🔒 block back
  in the vault. That is the right UX, but a helper is a convention, not a guarantee: a new write
  path, a seed, or a host calling `Ash.update/2` directly would otherwise be free to null the vault
  column, leaving authored content unclassified at rest (plaintext for whoever scans the table, a
  `••••` render for everyone, and no error anywhere). The invariant lives here, so it holds for
  EVERY governed write — including one nobody has written yet.

  ## The rule

    * **clearing `text_secure` on a row that currently holds a vaulted value is REFUSED**
      (`field: :text_secure`), whether the caller also writes `text` or not. That is the
      declassification shape, and it is a data-governance decision — it deserves its own named,
      audited, policy-bearing action, never a side effect of an edit. That action is
      `DocBlock.:declassify_text` (`Samen.Scopes.Docs.BlockDeclassify`, R17): a DIFFERENT action,
      admin-gated, reason-bearing and audited. This guard keeps `:update` shut;
    * **a vaulted block may not gain a plain `text` either** — the vault column is its ONLY text,
      so a plaintext twin (which the read seam would ignore while it sits unclassified at rest) is
      refused too;
    * **re-writing `text_secure` is always allowed** — that is how vaulted content is edited, and
      it can only keep the classification. `text: nil` alongside it is the one-text rule, not a
      downgrade;
    * **a write that touches neither text column is untouched** (`position`, `revision`, `checked`,
      `metadata`, `type`), so ordering churn and the CAS never pay for a read they do not need;
    * **a changeset with no original data cannot clear the vault either**: `:unknown` fails CLOSED,
      because a clear that cannot be proven safe is a declassification, not a no-op.

  A `%Ash.NotLoaded{}` classification maps to `:unknown` too, but Ash gets there first: it will not
  attribute a `text_secure: nil` change to a column it never loaded (the write is dropped as a no-op
  against the struct default — pinned by c10), so a caller that never selected the column cannot
  null it by accident. That is the layer BENEATH this guard, and it is why the `:unknown` clause's
  reachable case is the atomic one. The read seam always selects the column
  (`Samen.Web.Notes.Writes.@block_select`), so the guard is the last line, not the only one.

  ## How it is enforced

  `change/3` is an `Ash.Changeset` change installed by
  `Samen.Scopes.Docs.Blueprint.define_doc_block/6`, on UPDATE only (a create cannot declassify
  anything). It is the same installation point and the same shape as
  `Samen.Scopes.Docs.BlockShape`: the refusal happens on the governed write path, in the model,
  never only in a UI. `:update` already declares `require_atomic? false` for `BlockShape`, so the
  stored row is available to the guard.

  Proof: `Samen.DocsScopeTest` c10 — the clear and the twin are refused, the row is still
  vault-routed at rest, a no-data clear is refused, re-vaulting and a plain block's ordinary edit
  both still succeed (the anti-tautology controls), and sabotage 375 (the stored classification
  reads as `:plain`) flips every red path.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    classification = stored_classification(changeset)

    cond do
      clears_vault?(changeset, classification) ->
        Ash.Changeset.add_error(changeset,
          field: :text_secure,
          message:
            "`text_secure` cannot be cleared: a vaulted block stays vaulted. Write `text_secure` " <>
              "to change its text; write `text` only on a block that is not vaulted. Declassifying " <>
              "content is a data-governance action, not an edit."
        )

      writes_plain_twin?(changeset, classification) ->
        Ash.Changeset.add_error(changeset,
          field: :text_secure,
          message:
            "a vaulted block has no plain `text`: the vault column is its only text. Write " <>
              "`text_secure` to change it (a block is never both vaulted and plain)."
        )

      true ->
        changeset
    end
  end

  # Only an explicit `text_secure: nil` is a candidate for declassification. A change to ANY
  # non-nil value (a new vaulted value, or the same one) is the edit path and is always allowed.
  defp clears_vault?(changeset, classification) do
    match?({:ok, nil}, Ash.Changeset.fetch_change(changeset, :text_secure)) and
      classification in [:vaulted, :unknown]
  end

  # A plaintext twin on a block whose vault we can SEE holds a value: the plain column would carry
  # unclassified content the read seam never shows (it prefers `text_secure`). Unknown is not
  # enough here — unlike a clear, a plain write is the ordinary path and cannot be blanket-refused.
  defp writes_plain_twin?(changeset, classification) do
    case Ash.Changeset.fetch_change(changeset, :text) do
      {:ok, text} when not is_nil(text) -> classification == :vaulted
      _ -> false
    end
  end

  # `:unknown` covers BOTH "the column was not selected on the read" (`%Ash.NotLoaded{}`) and "the
  # changeset has no original data" (an atomic upgrade). A CLEAR on unknown is refused; a plain
  # write is not (see `writes_plain_twin?/2`).
  defp stored_classification(changeset) do
    case Ash.Changeset.fetch_data(changeset, :text_secure) do
      {:ok, nil} -> :plain
      {:ok, %Ash.NotLoaded{}} -> :unknown
      {:ok, _vaulted_value} -> :vaulted
      :error -> :unknown
    end
  end
end
