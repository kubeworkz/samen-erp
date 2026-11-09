defmodule Samen.Scopes.Finance.ApPaymentRun do
  @moduledoc """
  A **dual-control AP payment run** over the per-bill `ApInvoice.:pay` action.

  A run is requested by one user and approved by a DIFFERENT admin. The request
  persists the exact bill snapshot as `:pending_approval` and pays nothing. The
  approval re-validates that snapshot against the live bills and executes every
  payment in one repository transaction; only then does the run become
  `:paid`. A run can instead be rejected by a different admin, or cancelled by
  its requester, and either decision is final.

  The durable record (`Samen.Scopes.Finance.ApPaymentRunRecord`) stores the
  requester, the approver, both timestamps, the bill snapshot, the total and
  the remittance CSV. Its database trigger refuses a self-approved run, a
  rewritten request snapshot, a second decision and every DELETE, so the audit
  trail survives below the service.

  The cross-bill guarantees a loop of independent payments would not have:

    * all bills must belong to the same vendor;
    * every bill must still be `:approved` when the run is requested AND when
      it is approved (a stale or already-paid bill refuses the whole run);
    * bills that look like the same vendor document entered twice refuse the
      run unless the requester explicitly confirms them (`duplicates/1`);
    * the request's amounts must equal the live bills at approval time;
    * the payments execute inside one repository transaction, so a failure on
      a later bill rolls back the earlier payments;
    * every payment entry carries the same caller-visible run reference.

  ## Example

      {:ok, pending} =
        Samen.Scopes.Finance.ApPaymentRun.request(
          ap_invoice: Samenerp.Erp.ApInvoice,
          repo: Samenerp.Repo,
          scope: requester_scope,
          bill_ids: [bill.id],
          payment_date: ~D[2026-11-08],
          reference: "NOV-AP-01"
        )

      {:ok, paid} =
        Samen.Scopes.Finance.ApPaymentRun.approve(
          ap_invoice: Samenerp.Erp.ApInvoice,
          repo: Samenerp.Repo,
          scope: approver_scope,
          run_id: pending.id
        )

      File.write!("remittance.csv", paid.remittance_csv)
  """

  import Ecto.Query

  alias Samen.Scopes.Finance.ApPaymentRunRecord

  @type run :: ApPaymentRunRecord.t()

  @doc """
  Request a run. Persists a `:pending_approval` record and pays nothing.

  Options:

    * `:ap_invoice` (required) — the mounted `ApInvoice` resource
    * `:repo` (required) — the Ecto repo that owns that resource
    * `:scope` (required) — the `Samen.Scope` requesting the run
    * `:bill_ids` (required) — non-empty list of bill UUIDs, all one vendor
    * `:payment_date` (required) — the `Date` posted as the payment entry date
    * `:reference` — the remittance reference; generated when absent
    * `:memo` — optional note copied into every payment entry
    * `:vendor_name` — optional vendor name printed on the remittance advice
    * `:remittance_address` — optional postal address printed on the advice
    * `:allow_duplicates` — opt in to paying bills `duplicates/1` groups
      together (default `false`: the request refuses them)

  Returns `{:ok, pending_run}` or `{:error, reason}`. A duplicate suspicion is
  `{:error, {:duplicate_bills, ids}}`; an already-used reference is
  `{:error, :reference_taken}`.
  """
  @spec request(keyword()) :: {:ok, run()} | {:error, term()}
  def request(opts) do
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    bill_ids = Keyword.get(opts, :bill_ids)
    payment_date = Keyword.get(opts, :payment_date)
    memo = Keyword.get(opts, :memo)
    vendor_name = normalize_optional_text(Keyword.get(opts, :vendor_name))
    remittance_address = normalize_optional_text(Keyword.get(opts, :remittance_address))
    allow_duplicates = Keyword.get(opts, :allow_duplicates, false)
    reference = normalize_reference(Keyword.get(opts, :reference), payment_date)
    org_id = actor_org_id(scope)

    with :ok <- validate_actor(scope),
         :ok <- validate_org(org_id),
         :ok <- validate_bill_ids(bill_ids),
         :ok <- validate_payment_date(payment_date),
         {:ok, bills} <- load_bills(ap_invoice, bill_ids, scope),
         :ok <- validate_bills(bills, allow_duplicates),
         :ok <- ensure_reference_free(repo, org_id, reference) do
      payments = Enum.map(bills, &snapshot/1)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        org_id: org_id,
        reference: reference,
        vendor_id: hd(bills).vendor_id,
        payment_date: payment_date,
        memo: memo,
        vendor_name: vendor_name,
        remittance_address: remittance_address,
        status: :pending_approval,
        total_cents: Enum.sum(Enum.map(payments, &payment_amount/1)),
        bill_count: length(payments),
        payments: payments,
        requested_by: actor_id(scope),
        requested_at: now
      }

      case %ApPaymentRunRecord{}
           |> ApPaymentRunRecord.changeset(attrs)
           |> repo.insert() do
        {:ok, run} -> {:ok, run}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      end
    end
  end

  @doc """
  Approve a pending run as a distinct admin and execute its payments atomically.

  Returns `{:ok, paid_run}` or one of:

    * `{:error, :forbidden}` — the caller is not an admin/owner
    * `{:error, :self_approval}` — the requester tried to approve their own run
    * `{:error, :not_pending}` — the run was already decided
    * `{:error, :snapshot_mismatch}` — the requested bills/amounts changed
    * `{:error, {:payment_failed, bill_id, reason}}` — a payment refused and
      every earlier payment in the run was rolled back
  """
  @spec approve(keyword()) :: {:ok, run()} | {:error, term()}
  def approve(opts) do
    ap_invoice = Keyword.fetch!(opts, :ap_invoice)
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    run_id = Keyword.get(opts, :run_id)

    with :ok <- validate_admin(scope),
         {:ok, run} <- load_run(repo, scope, run_id) do
      case repo.transaction(fn -> execute_approval(repo, ap_invoice, scope, run) end) do
        {:ok, paid} -> {:ok, paid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reject a pending run as a distinct admin. Pays nothing and is final.
  """
  @spec reject(keyword()) :: {:ok, run()} | {:error, term()}
  def reject(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    run_id = Keyword.get(opts, :run_id)

    with :ok <- validate_admin(scope),
         {:ok, run} <- load_run(repo, scope, run_id) do
      case repo.transaction(fn -> decide_only(repo, scope, run, :rejected) end) do
        {:ok, rejected} -> {:ok, rejected}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Cancel a pending run as its requester. Pays nothing and is final.
  """
  @spec cancel(keyword()) :: {:ok, run()} | {:error, term()}
  def cancel(opts) do
    repo = Keyword.fetch!(opts, :repo)
    scope = Keyword.fetch!(opts, :scope)
    run_id = Keyword.get(opts, :run_id)

    with {:ok, run} <- load_run(repo, scope, run_id),
         :ok <- validate_requester(scope, run) do
      case repo.transaction(fn -> decide_only(repo, scope, run, :cancelled) end) do
        {:ok, cancelled} -> {:ok, cancelled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  List the org's runs, newest first.

  Options: `:status` (one status), `:statuses` (a list), and `:limit` (default
  50).
  """
  @spec list_runs(module(), String.t(), keyword()) :: [run()]
  def list_runs(repo, org_id, opts \\ []) when is_binary(org_id) do
    query =
      ApPaymentRunRecord
      |> where([r], r.org_id == ^org_id)
      |> order_by([r], desc: r.inserted_at)
      |> limit(^Keyword.get(opts, :limit, 50))

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [r], r.status == ^status)
      end

    query =
      case Keyword.get(opts, :statuses) do
        nil -> query
        statuses -> where(query, [r], r.status in ^statuses)
      end

    repo.all(query)
  end

  @doc "Fetch one run pinned to `org_id`."
  @spec get_run(module(), String.t(), String.t()) :: {:ok, run()} | {:error, :not_found}
  def get_run(repo, org_id, id) when is_binary(org_id) and is_binary(id) do
    case repo.get_by(ApPaymentRunRecord, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Render a run's persisted remittance advice as CSV.

  The file is intentionally bank-agnostic: one row per bill with the shared
  run reference, payment date, vendor, bill number, due date and amount in
  cents. It is not a NACHA/ACH file. A paid run carries the exact CSV that was
  stored at approval in `run.remittance_csv`.
  """
  @spec remittance_csv(run()) :: String.t()
  def remittance_csv(run) do
    header =
      "reference,payment_date,vendor_id,bill_number,due_date,amount_cents\n"

    rows =
      Enum.map(run.payments, fn payment ->
        [
          run.reference,
          Date.to_iso8601(run.payment_date),
          run.vendor_id,
          field(payment, :number),
          due_date_text(field(payment, :due_date)),
          payment_amount(payment)
        ]
        |> Enum.map(&csv_cell/1)
        |> Enum.join(",")
      end)

    header <> Enum.join(rows, "\n") <> "\n"
  end

  @doc """
  Bills that look like the same vendor document entered twice.

  Two bills are grouped when they share the vendor, the line total and the bill
  date — the shape a re-keyed invoice takes when only the vendor's number
  differs (`{org, number}` is already unique at the database, so an identical
  number cannot be stored twice). Returns one entry per group, each with the
  shared key and its bills sorted by number; `[]` when nothing looks doubled.

  Detection is over the bills the caller supplies: the payment page passes its
  whole approved list, and `request/1` passes the batch it is about to request.
  A copy that was already paid is outside both sets and is NOT detected here.
  """
  @spec duplicates([map()]) :: [%{key: tuple(), bills: [map()]}]
  def duplicates(bills) when is_list(bills) do
    bills
    |> Enum.reject(&(Map.get(&1, :vendor_id) in [nil, ""]))
    |> Enum.group_by(fn bill ->
      {bill.vendor_id, bill_total(bill), Map.get(bill, :bill_date)}
    end)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {key, group} ->
      %{key: key, bills: Enum.sort_by(group, &to_string(Map.get(&1, :number)))}
    end)
    |> Enum.sort_by(fn %{key: {vendor, total, date}} ->
      {to_string(date), vendor, total}
    end)
  end

  # -- approval execution ------------------------------------------------------

  defp execute_approval(repo, ap_invoice, scope, run) do
    actor = actor_id(scope)

    cond do
      is_nil(actor) ->
        repo.rollback(:no_approver)

      actor == run.requested_by ->
        repo.rollback(:self_approval)

      true ->
        with :ok <- lock_run(repo, run.id),
             {:ok, bills} <- validate_snapshot(ap_invoice, scope, run),
             :ok <- execute_payments(scope, run, bills) do
          now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

          case run
               |> Ecto.Changeset.change(
                 status: :paid,
                 approved_by: actor,
                 approved_at: now,
                 executed_at: now,
                 remittance_csv: remittance_csv(run),
                 updated_at: now
               )
               |> repo.update() do
            {:ok, paid} -> paid
            {:error, changeset} -> repo.rollback({:run_update_failed, changeset})
          end
        else
          {:error, reason} -> repo.rollback(reason)
        end
    end
  end

  defp decide_only(repo, scope, run, status) do
    actor = actor_id(scope)

    cond do
      run.status != :pending_approval ->
        repo.rollback(:not_pending)

      is_nil(actor) ->
        repo.rollback(:no_approver)

      status == :rejected and actor == run.requested_by ->
        repo.rollback(:self_approval)

      status == :cancelled and actor != run.requested_by ->
        repo.rollback(:not_requester)

      true ->
        case lock_run(repo, run.id) do
          :ok ->
            now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

            attrs =
              case status do
                :rejected ->
                  [status: :rejected, rejected_by: actor, rejected_at: now, updated_at: now]

                :cancelled ->
                  [status: :cancelled, cancelled_by: actor, cancelled_at: now, updated_at: now]
              end

            case run |> Ecto.Changeset.change(attrs) |> repo.update() do
              {:ok, updated} -> updated
              {:error, changeset} -> repo.rollback({:run_update_failed, changeset})
            end

          {:error, reason} ->
            repo.rollback(reason)
        end
    end
  end

  defp validate_snapshot(ap_invoice, scope, run) do
    payments = List.wrap(run.payments)

    cond do
      payments == [] ->
        {:error, :snapshot_mismatch}

      length(payments) != run.bill_count ->
        {:error, :snapshot_mismatch}

      Enum.sum(Enum.map(payments, &payment_amount/1)) != run.total_cents ->
        {:error, :snapshot_mismatch}

      length(Enum.uniq(Enum.map(payments, &field(&1, :bill_id)))) != length(payments) ->
        {:error, :snapshot_mismatch}

      true ->
        payments
        |> Enum.reduce_while({:ok, []}, fn payment, {:ok, bills} ->
          bill_id = field(payment, :bill_id)

          case Ash.get(ap_invoice, bill_id, scope: scope) do
            {:ok, nil} ->
              {:halt, {:error, {:bill_not_found, bill_id}}}

            {:error, reason} ->
              {:halt, {:error, {:bill_read_failed, bill_id, reason}}}

            {:ok, bill} ->
              cond do
                bill.status != :approved ->
                  {:halt, {:error, {:not_approved, bill_id}}}

                bill.vendor_id != run.vendor_id ->
                  {:halt, {:error, :mixed_vendors}}

                bill_total(bill) != payment_amount(payment) ->
                  {:halt, {:error, {:snapshot_amount_mismatch, bill_id}}}

                true ->
                  {:cont, {:ok, [bill | bills]}}
              end
          end
        end)
        |> case do
          {:ok, bills} -> {:ok, Enum.reverse(bills)}
          error -> error
        end
    end
  end

  defp execute_payments(scope, run, bills) do
    params = %{payment_date: run.payment_date, reference: run.reference, memo: run.memo}

    Enum.reduce_while(bills, :ok, fn bill, :ok ->
      # `:pay` is system-only (its policy forbids every direct caller). This
      # service is the sanctioned route: the run's request/approve split and
      # the distinct-admin check above ARE the authorization, so the inner
      # action runs without re-authorization — the same posture as every other
      # system cascade (`create_accrual_reversal`, `create_reversal`).
      case bill
           |> Ash.Changeset.for_update(:pay, params, scope: scope)
           |> Ash.update(authorize?: false) do
        {:ok, _paid} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:payment_failed, bill.id, reason}}}
      end
    end)
  end

  # The row lock makes two approvals race safely: the loser sees the decided
  # status and refuses. The trigger is the second belt below this.
  defp lock_run(repo, id) do
    case repo.query(
           "SELECT prn_status FROM prn_ap_payment_run WHERE prn_id = $1 FOR UPDATE",
           [Ecto.UUID.dump!(id)]
         ) do
      {:ok, %{rows: [["pending_approval"]]}} -> :ok
      {:ok, %{rows: [[_status]]}} -> {:error, :not_pending}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, {:lock_failed, reason}}
    end
  end

  # -- request validation ------------------------------------------------------

  defp validate_bill_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &is_binary/1) and Enum.uniq(ids) == ids do
      :ok
    else
      {:error, :bill_ids_must_be_unique_uuids}
    end
  end

  defp validate_bill_ids(_), do: {:error, :bill_ids_required}

  defp validate_payment_date(%Date{}), do: :ok
  defp validate_payment_date(_), do: {:error, :payment_date_required}

  defp validate_actor(scope) do
    if is_binary(actor_id(scope)), do: :ok, else: {:error, :actor_required}
  end

  defp validate_org(org_id) do
    if is_binary(org_id), do: :ok, else: {:error, :org_required}
  end

  defp validate_admin(%Samen.Scope{actor: %{role: role}}) when role in [:admin, :owner], do: :ok
  defp validate_admin(_), do: {:error, :forbidden}

  defp validate_requester(scope, run) do
    if actor_id(scope) == run.requested_by, do: :ok, else: {:error, :not_requester}
  end

  defp load_run(repo, scope, run_id) do
    org_id = actor_org_id(scope)

    cond do
      not is_binary(run_id) -> {:error, :run_id_required}
      not is_binary(org_id) -> {:error, :org_required}
      true -> get_run(repo, org_id, run_id)
    end
  end

  defp load_bills(ap_invoice, bill_ids, scope) do
    bills =
      Enum.reduce_while(bill_ids, [], fn id, acc ->
        case Ash.get(ap_invoice, id, scope: scope) do
          {:ok, nil} -> {:halt, {:error, {:bill_not_found, id}}}
          {:ok, bill} -> {:cont, [bill | acc]}
          {:error, reason} -> {:halt, {:error, {:bill_read_failed, id, reason}}}
        end
      end)

    case bills do
      {:error, _} = error -> error
      bills -> {:ok, Enum.reverse(bills)}
    end
  end

  defp validate_bills([first | rest] = bills, allow_duplicates) do
    cond do
      Enum.any?(bills, &(&1.status != :approved)) ->
        {:error, {:not_approved, Enum.find(bills, &(&1.status != :approved)).id}}

      Enum.any?(rest, &(&1.vendor_id != first.vendor_id)) ->
        {:error, :mixed_vendors}

      not allow_duplicates and duplicates(bills) != [] ->
        ids =
          bills
          |> duplicates()
          |> Enum.flat_map(fn %{bills: group} -> Enum.map(group, & &1.id) end)
          |> Enum.uniq()

        {:error, {:duplicate_bills, ids}}

      true ->
        :ok
    end
  end

  defp ensure_reference_free(repo, org_id, reference) do
    case repo.get_by(ApPaymentRunRecord, org_id: org_id, reference: reference) do
      nil -> :ok
      _run -> {:error, :reference_taken}
    end
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :reference) do
      :reference_taken
    else
      changeset
    end
  end

  # -- run values --------------------------------------------------------------

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(_value), do: nil

  defp snapshot(bill) do
    %{
      "bill_id" => bill.id,
      "number" => bill.number,
      "due_date" => bill.due_date,
      "amount_cents" => bill_total(bill)
    }
  end

  defp bill_total(bill) do
    Samen.Scopes.Finance.ApDuplicates.total(bill)
  end

  defp payment_amount(payment), do: field(payment, :amount_cents) || 0

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp due_date_text(nil), do: ""
  defp due_date_text(%Date{} = date), do: Date.to_iso8601(date)
  defp due_date_text(other), do: to_string(other)

  defp actor_id(%Samen.Scope{actor: %{id: id}}), do: id
  defp actor_id(_), do: nil

  defp actor_org_id(%Samen.Scope{actor: %{org_id: org_id}}), do: org_id
  defp actor_org_id(_), do: nil

  defp normalize_reference(reference, _payment_date)
       when is_binary(reference) and reference != "" do
    reference
  end

  defp normalize_reference(_reference, %Date{} = payment_date) do
    "APRUN-#{Date.to_iso8601(payment_date)}-" <>
      (Ash.UUID.generate() |> binary_part(0, 8) |> String.upcase())
  end

  defp normalize_reference(_reference, _payment_date) do
    "APRUN-" <> (Ash.UUID.generate() |> binary_part(0, 8) |> String.upcase())
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp csv_cell(value), do: to_string(value)
end
