defmodule Samen.Scopes.Docs.BlockDeclassify do
  @moduledoc """
  The ONE sanctioned way out of the vault for a `Docs.DocBlock` (ADR-053 §2 D5 / R17).

  ## Why this exists

  `Samen.Scopes.Docs.BlockVault` makes the classification sticky: no governed `:update` may clear
  `text_secure`, so a helper, a seed or a host's own write path can never declassify a block by
  accident. That refusal is deliberate, but it is not a policy of "never" — it is a policy of
  "not as a side effect". Content IS sometimes over-classified, and the people who own the data
  need a way to say so. This change is that way, and it is the only one:

    * it is a NAMED action (`:declassify_text`), never a flag on `:update`;
    * it requires a `reason`, and it writes an audit row
      (`Samen.Scopes.Docs.Audit.text_declassified/5`) in the same transaction — an action that
      cannot record itself FAILS, so no unaudited declassification exists;
    * it accepts NO attributes (`accept []`), so a caller cannot smuggle a `text`/`text_secure`
      value of their choosing: the plaintext that lands in `text` is the plaintext that was IN the
      vault, revealed server-side through the single `Samen.Vault.reveal/3` chokepoint;
    * the role gate lives on the action (`Samen.Policy.RoleAtLeast, role: :admin`), so a `member`
      who can edit the page still cannot change what the page stores at rest.

  ## What it writes

  In `before_action`, inside the action's transaction:

    1. re-read the block org-scoped, with `text_secure` selected (`authorize?: false`: the action's
       own policy already decided the caller may act, and this read is the guard's bookkeeping,
       never a value returned to the caller — the `org_id` filter keeps it tenant-bounded even if
       policy ordering ever changed);
    2. refuse when the block is not vaulted — a second declassify is an error, not a silent no-op;
    3. `Samen.Vault.reveal/3` its `%Samen.Masked{}`, bound to the block's own id as the subject
       (the F4.1 accountability bind), and FAIL CLOSED on `:shredded` / `:unavailable`;
    4. force `text` = that plaintext, `text_secure` = nil, and bump `revision` (a declassify is a
       content write: a stale editor tab's CAS must see a newer revision).

  The revealed value re-enters the tenant free-text chokepoint EXPLICITLY (`scan/1`, the same
  `Samen.PiiReasonScan` the plain column's `FreeTextScan` uses). Depending on before_action hook
  ordering between an action-level change and a resource-level one would be a fragile place to put
  a leak gate, so the guard does not depend on it: a vaulted value that is ITSELF a bare
  email/SSN/phone shape cannot be laundered into the plain column — that content stays vaulted,
  which is the correct answer.

  ## What it does NOT do

  The ciphertext row in `pii_vault` is left in place. The domain column no longer references it
  (nothing reads it after the clear), and it is destroyed with the rest of the subject's PII at
  erasure; deleting it here would be a second, unreviewed mutation on a governance action whose
  only job is to change where the content lives. That residue is named in the ADR rather than
  hidden.

  ## Proof

  `Samen.DocsScopeTest` c11: a `member` is REFUSED by policy and the row stays vaulted; an `admin`
  succeeds (the anti-tautology control), the plaintext is the vault's own, `text_secure` is nil,
  the revision moved, and an `aud_event` row names the block, the actor and the reason while
  carrying no text; a plain block, an operator-plane admin and a bare-email vaulted value are all
  refused, and a BLANK reason is refused in the model (an unrecorded decision is not a decision).
  The editor's half of the story (the admin-only form that collects the reason, and the member /
  operator red paths) is `Samen.Web.NotesDeclassifyUiTest`. Sabotage **376** removes the role gate
  and flips exactly the denial test; **377** makes the audit writer a no-op and flips the audited
  control; **378** drops the surface's role gate and flips the UI red paths.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Masked
  alias Samen.Scopes.Docs.Audit

  @impl true
  def change(changeset, _opts, context) do
    actor = actor_of(context, changeset)
    repo = repo!(changeset)
    reason = Ash.Changeset.get_argument(changeset, :reason)

    cond do
      # A declassify with no reason writes an audit row that does not say anything. The reason is
      # the whole record of WHY a classification was reduced, so a blank one is refused in the
      # model (the surface also validates it, but the API path must not be able to skip it).
      blank?(reason) ->
        Ash.Changeset.add_error(changeset,
          field: :reason,
          message:
            "a declassification must say WHY it is no longer classified — the audit row is the " <>
              "record of the decision, and an empty reason is not a record."
        )

      operator_plane?(actor) ->
        # The classification belongs to the tenant that authored it. An operator (or an
        # impersonation session) may be GRANTED a reveal, but moving tenant content permanently
        # into a plaintext column is a tenant decision — never an operator-side "cleanup".
        Ash.Changeset.add_error(changeset,
          field: :text,
          message:
            "declassify is a tenant-plane action: an operator-plane actor cannot move tenant " <>
              "content out of the vault (a reveal grant is temporary; this is permanent)."
        )

      true ->
        org_id = actor && Map.get(actor, :org_id)

        changeset
        |> Ash.Changeset.before_action(fn cs -> move_out_of_vault(cs, repo, org_id) end)
        |> Ash.Changeset.after_action(fn cs, block -> record(cs, block, repo, org_id, actor) end)
    end
  end

  defp blank?(nil), do: true
  defp blank?(reason) when is_binary(reason), do: String.trim(reason) == ""
  defp blank?(_), do: true

  # ── the vault → plain move ─────────────────────────────────────────────────

  # The acting org comes from the ACTOR (the policy already bound it), never from the record
  # struct: `org_id` may legitimately be `%Ash.NotLoaded{}` on a caller's read, and a guard that
  # depends on what the caller happened to select is not a guard.
  defp move_out_of_vault(changeset, repo, org_id) do
    if is_nil(org_id) do
      Ash.Changeset.add_error(changeset,
        field: :text_secure,
        message: "declassify needs an acting org (an org-less actor cannot move PII out of the vault)"
      )
    else
      with {:ok, fresh} <- fetch_fresh(changeset, org_id),
           {:ok, masked} <- vaulted(fresh),
           {:ok, plaintext} <- reveal(masked, fresh, repo),
           {:ok, plaintext} <- scan(plaintext) do
        changeset
        |> Ash.Changeset.force_change_attribute(:text, plaintext)
        |> Ash.Changeset.force_change_attribute(:text_secure, nil)
        |> Ash.Changeset.force_change_attribute(:revision, (fresh.revision || 1) + 1)
      else
        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :text_secure, message: message)
      end
    end
  end

  # A fresh, org-bounded read WITH the vault column selected: the caller's struct may never have
  # loaded (`%Ash.NotLoaded{}`) or may hold a stale value, and the plaintext we persist must be the
  # vault's CURRENT content, not whatever the caller happened to carry.
  defp fetch_fresh(changeset, org_id) do
    block = changeset.data

    query =
      changeset.resource
      |> Ash.Query.filter(id == ^block.id and org_id == ^org_id)
      |> Ash.Query.ensure_selected([:text_secure])

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} ->
        {:error, "the block no longer exists; nothing was declassified"}

      {:ok, fresh} ->
        {:ok, fresh}

      {:error, reason} ->
        {:error,
         "could not read the block's classification (#{inspect(reason)}); refusing to " <>
           "declassify blind"}
    end
  end

  defp vaulted(%{text_secure: %Masked{} = masked}), do: {:ok, masked}

  defp vaulted(%{text_secure: nil}) do
    {:error,
     "this block is not vaulted: there is nothing to declassify. Write `text` through the " <>
       "ordinary edit action; this action only moves content OUT of `text_secure`."}
  end

  defp vaulted(_other) do
    {:error, "the block's stored classification could not be read; refusing to declassify blind"}
  end

  # The plaintext is about to become an ordinary PLAIN column value, so it re-enters the tenant
  # free-text chokepoint HERE, explicitly: hook ordering between an action-level change and the
  # resource-level `FreeTextScan` is not something a governance rule should depend on. Same
  # scanner, same shape vocabulary as `Samen.Pii.FreeTextScan` — the block simply stays vaulted.
  defp scan(plaintext) do
    case Samen.PiiReasonScan.check(plaintext, "tenant free-text (text)") do
      :ok ->
        {:ok, plaintext}

      {:error, {:pii_shaped_reason, shape}} ->
        {:error,
         "pii-shaped free-text (F3 Unit 6): the block's vaulted text is a bare #{shape}, and " <>
           "declassify writes into the plain `text` column — refused at the write path, the " <>
           "block stays vaulted. See docs/free-text-pii-residue.md."}
    end
  end

  defp reveal(masked, block, repo) do
    case Samen.Vault.reveal(masked, repo, subject_id: to_string(block.id)) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, reason} ->
        {:error,
         "the vault could not yield this block's text (#{inspect(reason)}); nothing was " <>
           "declassified — a shredded or unavailable key fails closed"}
    end
  end

  # ── the audit row (same transaction) ───────────────────────────────────────

  defp record(changeset, block, repo, org_id, actor) do
    case Audit.text_declassified(
           repo,
           org_id,
           block,
           actor_id(actor),
           Ash.Changeset.get_argument(changeset, :reason)
         ) do
      {:ok, _} ->
        {:ok, block}

      {:error, reason} ->
        # FAIL-CLOSED: returning {:error, _} from after_action rolls back the action's
        # transaction — a declassification that cannot be recorded never lands.
        {:error,
         "docs.block.declassified audit failed (write aborted, fail-closed): #{inspect(reason)}"}
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  # `context.actor` is populated when the action's change is registered; the changeset's private
  # actor is the fallback (and the only one available on some internal rebuilds).
  defp actor_of(%{actor: actor}, _changeset) when is_map(actor), do: actor

  defp actor_of(_context, changeset) do
    case get_in(changeset.context, [:private, :actor]) do
      actor when is_map(actor) -> actor
      _ -> nil
    end
  end

  defp operator_plane?(actor) when is_map(actor), do: Map.get(actor, :plane) == :operator
  defp operator_plane?(_), do: false

  defp actor_id(actor) when is_map(actor), do: Map.get(actor, :id)
  defp actor_id(_), do: nil

  defp repo!(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.Scopes.Docs.BlockDeclassify: could not resolve a repo for " <>
              inspect(changeset.resource)
  end
end
