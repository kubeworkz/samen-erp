defmodule Samen.Scopes.Finance.CollectionCadence do
  @moduledoc """
  Per-org collection dunning cadence settings.

  A missing row means the default cadence: every escalation stage is enabled,
  with the same intervals as `ArCollections.stage_days/1` (`notice` 14 days,
  `final_notice` 21, `collections` 30). The opening reminder is the case's
  first stage; this row configures the *automated escalation* stages that the
  daily `CollectionDunningWorker` appends after it.

  The resource is host-mounted; this module is the kernel's read/projection
  seam. Reads span every org because the dunning sweep is a system job, but
  each row is keyed by the org id and only that org's cases use it.
  """

  require Ash.Query

  defstruct org_id: nil,
            notice_enabled: true,
            final_notice_enabled: true,
            collections_enabled: true,
            notice_days: 14,
            final_notice_days: 21,
            collections_days: 30

  @type t :: %__MODULE__{
          org_id: String.t() | nil,
          notice_enabled: boolean(),
          final_notice_enabled: boolean(),
          collections_enabled: boolean(),
          notice_days: pos_integer(),
          final_notice_days: pos_integer(),
          collections_days: pos_integer()
        }

  @doc "The cadence used when an org has no row."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc """
  Load the cadence rows for `org_ids`, keyed by org id.

  Missing orgs are simply absent; callers fall back to `defaults/0`.
  """
  @spec for_orgs(module() | nil, [String.t()]) :: %{optional(String.t()) => t()}
  def for_orgs(_resource, []), do: %{}
  def for_orgs(nil, _org_ids), do: %{}

  def for_orgs(resource, org_ids) do
    resource
    |> Ash.Query.filter(org_id in ^org_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.org_id, from_record(&1)})
  end

  @doc "Whether the automated stage is enabled for this cadence."
  @spec enabled?(atom(), t()) :: boolean()
  def enabled?(:notice, %__MODULE__{notice_enabled: enabled}), do: enabled
  def enabled?(:final_notice, %__MODULE__{final_notice_enabled: enabled}), do: enabled
  def enabled?(:collections, %__MODULE__{collections_enabled: enabled}), do: enabled
  def enabled?(_stage, _cadence), do: false

  @doc """
  The next enabled escalation stage after `stage`, or nil when the org has
  disabled every remaining stage. Disabled stages are skipped, not treated as
  a hard stop: an org that disables `:notice` still reaches an enabled
  `:final_notice`. `:collections` is the final rung and repeats itself while
  enabled; the case stays open until a person resolves it.
  """
  @spec next_stage(atom(), t()) :: atom() | nil
  def next_stage(:collections, cadence) do
    if enabled?(:collections, cadence), do: :collections
  end

  def next_stage(stage, cadence) when stage in [:reminder, :notice, :final_notice] do
    [:reminder, :notice, :final_notice, :collections]
    |> Enum.drop_while(&(&1 != stage))
    |> Enum.drop(1)
    |> Enum.find(&enabled?(&1, cadence))
  end

  def next_stage(_stage, _cadence), do: nil

  @doc "The configured interval for the stage just recorded."
  @spec interval_days(atom(), t()) :: pos_integer()
  def interval_days(:notice, %__MODULE__{notice_days: days}), do: days
  def interval_days(:final_notice, %__MODULE__{final_notice_days: days}), do: days
  def interval_days(:collections, %__MODULE__{collections_days: days}), do: days

  @doc "The next contact date after `stage`, counted from `today`."
  @spec next_action_on(atom(), Date.t(), t()) :: Date.t()
  def next_action_on(stage, %Date{} = today, cadence) do
    Date.add(today, interval_days(stage, cadence))
  end

  defp from_record(row) do
    %__MODULE__{
      org_id: row.org_id,
      notice_enabled: row.notice_enabled,
      final_notice_enabled: row.final_notice_enabled,
      collections_enabled: row.collections_enabled,
      notice_days: row.notice_days,
      final_notice_days: row.final_notice_days,
      collections_days: row.collections_days
    }
  end
end
