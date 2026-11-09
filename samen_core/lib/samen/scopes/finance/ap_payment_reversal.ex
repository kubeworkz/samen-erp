defmodule Samen.Scopes.Finance.ApPaymentReversal do
  @moduledoc """
  A **dual-controlled reversal of a paid AP payment run**.

  A paid run is immutable. Reversing it is a separate control row:

    * an admin requests the reversal with a reason; that request pays nothing;
    * a DIFFERENT admin approves it;
    * approval locks the reversal and, in ONE repository transaction, voids each
      `ap_payment` journal entry (the ledger's `:void` transition posts the
      linked reversing entry) and returns each bill to `:approved`, so the
      liability is restored and the bills can be paid again;
    * the reversal row becomes `:reversed` with the approver and execution
      evidence. Rejection and cancellation are final and pay nothing.

  Only one reversal may be requested per run (the unique `(org_id, run_id)`
  index), and the service is `(org_id, run_id)`-pinned. The original run's
  status stays `:paid`; the reversal row is the compensating fact.

  ## What a reversal is not

  The void is dated the payment entry's own date, so a payment in a closed
  period is refused by `PeriodGuard`. A closed-period return needs a
  current-period adjustment through the ordinary journal path; this service
  does not silently backdate or rewrite a closed period.
  """

  import Ecto.Query, only: [from: 2]

  alias Samen.Scopes.Finance.ApPaymentReversalRecord, as: Record
  alias Samen.Scopes.Finance.ApPaymentRunRecord

  @type reversal :: Record.t()

  @doc """
  Request a reversal as an admin. Persists `:pending_approval`; pays nothing.

  Options: `:repo`, `:scope`, `:run_id`, `:reason`.
  """
  @spec request(keyword()) :: {:ok, reversal()} | {:error, term()}
  def request(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    run_id = Keyword.get(opts, :run_id)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- admin_id(scope),
         {:ok, run} <- paid_run(repo, org_id, run_id),
         {:ok, reason} <- validate_reason(Keyword.get(opts, :reason)),
         :ok <- absent(repo, org_id, run.id) do
      now = Record.now()

      attrs = %{
        org_id: org_id,
        run_id: run.id,
        reason: reason,
        status: :pending_approval,
        total_cents: run.total_cents,
        bill_count: run.bill_count,
        payments: run.payments,
        requested_by: actor,
        requested_at: now,
        inserted_at: now,
        updated_at: now
      }

      case %Record{} |> Record.request_changeset(attrs) |> repo.insert() do
        {:ok, reversal} -> {:ok, reversal}
        {:error, changeset} -> {:error, changeset_error(changeset)}
      end
    end
  end

  @doc """
  Approve a pending reversal as an admin DISTINCT from its requester.

  Options: `:repo`, `:scope`, `:ap_invoice`, `:reversal_id`.
  """
  @spec approve(keyword()) :: {:ok, reversal()} | {:error, term()}
  def approve(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    reversal_id = Keyword.get(opts, :reversal_id)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- admin_id(scope),
         {:ok, reversal} <- fetch(repo, org_id, reversal_id) do
      case repo.transaction(fn -> execute(repo, ap_invoice, scope, reversal, actor) end) do
        {:ok, done} -> {:ok, done}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Reject a pending reversal as an admin distinct from its requester."
  @spec reject(keyword()) :: {:ok, reversal()} | {:error, term()}
  def reject(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    reversal_id = Keyword.get(opts, :reversal_id)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- admin_id(scope),
         {:ok, reversal} <- fetch(repo, org_id, reversal_id) do
      case repo.transaction(fn -> decide(repo, reversal, actor, :rejected) end) do
        {:ok, done} -> {:ok, done}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Cancel a pending reversal as its requester."
  @spec cancel(keyword()) :: {:ok, reversal()} | {:error, term()}
  def cancel(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    reversal_id = Keyword.get(opts, :reversal_id)

    with {:ok, org_id} <- org_id(scope),
         {:ok, actor} <- actor_id(scope),
         {:ok, reversal} <- fetch(repo, org_id, reversal_id),
         :ok <- requester(reversal, actor) do
      case repo.transaction(fn -> decide(repo, reversal, actor, :cancelled) end) do
        {:ok, done} -> {:ok, done}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The org's reversal for a run, or `{:ok, nil}` when none exists."
  @spec get_for_run(module(), String.t(), String.t()) :: {:ok, reversal() | nil}
  def get_for_run(repo, org_id, run_id) when is_binary(org_id) and is_binary(run_id) do
    {:ok, repo.get_by(Record, org_id: org_id, run_id: run_id)}
  rescue
    Ecto.Query.CastError -> {:ok, nil}
  end

  def get_for_run(_repo, _org_id, _run_id), do: {:ok, nil}

  @doc """
  The org's pending reversals, oldest first, each with its paid run.

  The run is joined inside the query so the queue can show its reference without
  a second read path; both sides are pinned to the same `org_id`.
  """
  @spec list_pending(module(), String.t()) :: [
          %{reversal: reversal(), run: ApPaymentRunRecord.t()}
        ]
  def list_pending(repo, org_id) when is_binary(org_id) do
    from(r in Record,
      join: run in ApPaymentRunRecord,
      on: run.id == r.run_id and run.org_id == r.org_id,
      where: r.org_id == ^org_id and r.status == :pending_approval,
      order_by: [asc: r.requested_at],
      limit: 20,
      select: {r, run}
    )
    |> repo.all()
    |> Enum.map(fn {reversal, run} -> %{reversal: reversal, run: run} end)
  rescue
    _error -> []
  end

  def list_pending(_repo, _org_id), do: []

  @doc """
  How many pending reversals in the org are awaiting a DIFFERENT admin.

  The nav badge is the queue's actionable subset: the caller's own request is
  excluded because the kernel refuses self-approval. Org-pinned and never
  raises, so a navigation render cannot fail on a read error.
  """
  @spec count_awaiting(module(), String.t() | nil, String.t() | nil) :: non_neg_integer()
  def count_awaiting(repo, org_id, actor_id)
      when is_binary(org_id) and is_binary(actor_id) do
    from(r in Record,
      where:
        r.org_id == ^org_id and r.status == :pending_approval and r.requested_by != ^actor_id,
      select: count(r.id)
    )
    |> repo.one()
    |> case do
      total when is_integer(total) -> total
      _ -> 0
    end
  rescue
    _error -> 0
  end

  def count_awaiting(_repo, _org_id, _actor_id), do: 0

  @doc "Whether `actor_id` may approve this pending reversal (a different admin)."
  @spec approvable_by?(reversal(), String.t() | nil) :: boolean()
  def approvable_by?(%Record{status: :pending_approval, requested_by: requested_by}, actor_id) do
    is_binary(actor_id) and actor_id != requested_by
  end

  def approvable_by?(_reversal, _actor_id), do: false

  # -- execution --------------------------------------------------------------

  defp execute(repo, ap_invoice, scope, reversal, actor) do
    with :ok <- lock_pending(repo, reversal.id),
         :ok <- distinct(reversal, actor),
         {:ok, run} <- load_run(repo, reversal.org_id, reversal.run_id),
         :ok <- run_paid(run),
         :ok <- reverse_bills(ap_invoice, scope, reversal) do
      now = Record.now()

      case reversal
           |> Ecto.Changeset.change(
             status: :reversed,
             approved_by: actor,
             approved_at: now,
             executed_at: now,
             updated_at: now
           )
           |> repo.update() do
        {:ok, done} -> done
        {:error, changeset} -> repo.rollback({:update_failed, changeset})
      end
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp decide(repo, reversal, actor, status) do
    with :ok <- lock_pending(repo, reversal.id),
         :ok <- distinct(reversal, actor) do
      now = Record.now()

      attrs =
        case status do
          :rejected ->
            [status: :rejected, rejected_by: actor, rejected_at: now, updated_at: now]

          :cancelled ->
            [status: :cancelled, cancelled_by: actor, cancelled_at: now, updated_at: now]
        end

      case reversal |> Ecto.Changeset.change(attrs) |> repo.update() do
        {:ok, done} -> done
        {:error, changeset} -> repo.rollback({:update_failed, changeset})
      end
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp reverse_bills(ap_invoice, scope, reversal) do
    Enum.reduce_while(reversal.payments, :ok, fn payment, :ok ->
      bill_id = field(payment, :bill_id)

      with true <- is_binary(bill_id),
           {:ok, bill} when not is_nil(bill) <- Ash.get(ap_invoice, bill_id, scope: scope),
           {:ok, _reversed} <-
             bill
             |> Ash.Changeset.for_update(:reverse_payment, %{}, scope: scope)
             |> Ash.update(authorize?: false) do
        {:cont, :ok}
      else
        false ->
          {:halt, {:error, :snapshot_mismatch}}

        {:ok, nil} ->
          {:halt, {:error, {:bill_not_found, bill_id}}}

        {:error, reason} ->
          {:halt, {:error, {:bill_reversal_failed, bill_id, reason}}}
      end
    end)
  end

  # A row lock on the reversal is the race gate for two approvals: the loser
  # sees a decided status and refuses. The trigger is the second belt.
  defp lock_pending(repo, id) do
    case repo.query(
           "SELECT prv_status FROM prv_ap_payment_reversal WHERE prv_id = $1 FOR UPDATE",
           [Ecto.UUID.dump!(id)]
         ) do
      {:ok, %{rows: [["pending_approval"]]}} -> :ok
      {:ok, %{rows: [[_status]]}} -> {:error, :not_pending}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, {:lock_failed, reason}}
    end
  end

  # -- loads ------------------------------------------------------------------

  defp paid_run(repo, org_id, run_id) when is_binary(run_id) do
    case repo.get_by(ApPaymentRunRecord, id: run_id, org_id: org_id) do
      %{status: :paid} = run -> {:ok, run}
      %{status: _other} -> {:error, :run_not_paid}
      nil -> {:error, :run_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :run_not_found}
  end

  defp paid_run(_repo, _org_id, _run_id), do: {:error, :run_id_required}

  defp load_run(repo, org_id, run_id) do
    case repo.get_by(ApPaymentRunRecord, id: run_id, org_id: org_id) do
      nil -> {:error, :run_not_found}
      run -> {:ok, run}
    end
  end

  defp run_paid(%{status: :paid}), do: :ok
  defp run_paid(_run), do: {:error, :run_not_paid}

  defp fetch(repo, org_id, reversal_id) when is_binary(reversal_id) do
    case repo.get_by(Record, id: reversal_id, org_id: org_id) do
      nil -> {:error, :not_found}
      reversal -> {:ok, reversal}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp fetch(_repo, _org_id, _reversal_id), do: {:error, :reversal_id_required}

  defp absent(repo, org_id, run_id) do
    case repo.get_by(Record, org_id: org_id, run_id: run_id) do
      nil -> :ok
      _reversal -> {:error, :already_requested}
    end
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :run_id) do
      :already_requested
    else
      changeset
    end
  end

  # -- validation -------------------------------------------------------------

  defp validate_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      trimmed when byte_size(trimmed) > 1_000 -> {:error, :reason_too_long}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_reason(_reason), do: {:error, :reason_required}

  defp distinct(%Record{requested_by: requester}, actor) do
    if requester == actor, do: {:error, :self_approval}, else: :ok
  end

  defp requester(%Record{requested_by: requester}, actor) do
    if requester == actor, do: :ok, else: {:error, :not_requester}
  end

  # -- actor/values -----------------------------------------------------------

  defp org_id(%Samen.Scope{actor: %{org_id: org_id}}) when is_binary(org_id), do: {:ok, org_id}
  defp org_id(_scope), do: {:error, :org_required}

  defp actor_id(%Samen.Scope{actor: %{id: id}}) when is_binary(id), do: {:ok, id}
  defp actor_id(_scope), do: {:error, :actor_required}

  defp admin_id(%Samen.Scope{actor: %{id: id, role: role}})
       when is_binary(id) and role in [:admin, :owner],
       do: {:ok, id}

  defp admin_id(_scope), do: {:error, :forbidden}

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
