defmodule Samen.Scopes.Finance.ApprovalPolicyApproval do
  @moduledoc """
  The approved side of a generic `ApprovalPolicy` update.

  `Samen.Approvals.Gate` re-invokes a gated action with no arguments, so a
  policy change's proposed threshold, auto-approval flag, ordered steps,
  account scope and period scope ride in the approval's `subject_ref`. This
  handler reapplies exactly those values after a distinct admin approves. The
  approval row remains the durable record of what was requested and decided.
  """

  @behaviour Samen.Approvals.Handler

  @allowed [:threshold_cents, :auto_approve_below, :steps, :account_ids, :period_keys]

  @impl Samen.Approvals.Handler
  def on_approve(approval, _ctx) do
    with {:ok, {resource, :update}} <- parse_kind(approval.kind),
         {:ok, {record_id, attrs}} <- parse_subject_ref(approval.subject_ref),
         {:ok, record} <- Ash.get(resource, record_id, authorize?: false) do
      record
      |> Ash.Changeset.for_update(:update, attrs,
        authorize?: false,
        context: %{
          approval_ok: true,
          approval_id: approval.id,
          approved_by: approval.decided_by
        }
      )
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, updated} ->
          {:ok, %{executed: "update", record_id: to_string(updated.id)}}

        {:error, reason} ->
          {:error, {:gate_action_failed, reason}}
      end
    end
  end

  @doc false
  def subject_ref(changeset) do
    attrs =
      Map.new(@allowed, fn name ->
        {name, proposed_attribute(changeset, name)}
      end)

    encoded =
      attrs
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    "samen:#{Samen.Info.abbrev(changeset.resource)}:#{changeset.data.id}:#{encoded}"
  end

  defp proposed_attribute(changeset, name) do
    case Ash.Changeset.get_attribute(changeset, name) do
      %Ash.NotLoaded{} -> Map.get(changeset.data, name)
      value -> value
    end
  end

  defp parse_kind(kind) do
    case String.split(kind, ":", parts: 2) do
      [module, "update"] ->
        {:ok, {String.to_existing_atom(module), :update}}

      _ ->
        {:error, {:bad_kind, kind}}
    end
  rescue
    ArgumentError -> {:error, {:bad_kind, kind}}
  end

  defp parse_subject_ref(ref) do
    case String.split(ref, ":", parts: 4) do
      ["samen", _abbrev, record_id, encoded] ->
        with {:ok, binary} <- Base.url_decode64(encoded, padding: false),
             attrs when is_map(attrs) <- :erlang.binary_to_term(binary, [:safe]) do
          {:ok, {record_id, Map.take(attrs, @allowed)}}
        else
          _ -> {:error, {:bad_subject_ref, ref}}
        end

      _ ->
        {:error, {:bad_subject_ref, ref}}
    end
  end
end
