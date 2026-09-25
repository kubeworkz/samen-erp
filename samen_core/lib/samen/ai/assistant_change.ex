defmodule Samen.AI.AssistantChange do
  @moduledoc """
  Write-time governance for `Samen.AI.Assistant`'s create / rename actions
  (docs/plans/ai-assistant-openclaw-lite.md §6, P1 → P2):

    1. Refuses a `system_prompt` that carries a `vt_` vault-token sentinel,
       fail-closed — `vt_` is never a legitimate system instruction the same
       way it isn't for `Samen.AI.PromptChange`.
    2. Validates `name` against the bounded assistant-identifier shape
       (`~r/\\A[a-z0-9][a-z0-9_.\\-]*\\z/`, the `Samen.AI.Agent` precedent), so
       the identifier is a namespace-safe label rather than free text.
    3. Validates `model_id` is either absent or a bounded model id shape
       (letter/digit + `:`, `_`, `.`, `/`, `-` — a non-authoritative horizon
       string, not a tenant-data envelope).
    4. Validates `tools` against the CLOSED `Samen.AI.ToolSurface` tenant registry
       (P2) — only opted-in, surface-admitted tools may be declared; an unknown
       or off-surface name refuses fail-closed (the same five-way narrowing the
       agent loop enforces at run start, surfaced at write time so a scaffolded
       assistant can never declare a tool the loop would reject as `:invalid_tools`).
  """

  use Ash.Resource.Change

  require Logger

  @vt_sentinel "vt_"
  @name_pattern ~r/\A[a-z0-9][a-z0-9_.\-]*\z/
  @model_pattern ~r/\A[a-zA-Z0-9_.\-:\/]+\z/

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &prepare/1)
  end

  defp prepare(changeset) do
    with {:ok, system_prompt} <- require_field(changeset, :system_prompt),
         :ok <- refuse_vt(system_prompt),
         {:ok, name} <- require_field(changeset, :name),
         :ok <- validate_name(name),
         :ok <- validate_model(changeset),
         :ok <- validate_tools(changeset) do
      changeset
    else
      {:error, field, reason} ->
        Ash.Changeset.add_error(changeset, field: field, message: reason)
    end
  end

  defp require_field(changeset, field) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, val} when is_binary(val) and val != "" -> {:ok, val}
      _ ->
        # Also accept an already-set data value (an update that does not re-set
        # :name still carries the data's name — re-require the field from the
        # persisted data so a :rename cannot bypass the shape check).
        val = Ash.Changeset.get_attribute(changeset, field)

        if is_binary(val) and val != "" do
          {:ok, val}
        else
          {:error, field, "missing required #{field}"}
        end
    end
  end

  defp refuse_vt(str) when is_binary(str) do
    if String.contains?(str, @vt_sentinel) do
      Logger.warning(
        "Samen.AI.AssistantChange: refused a system_prompt carrying a vt_ vault-token sentinel"
      )

      {:error, :system_prompt,
       "system_prompt must not contain a vt_ vault-token sentinel (INV-7)"}
    else
      :ok
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name) do
      :ok
    else
      {:error, :name,
       "assistant name must match #{inspect(@name_pattern)} (bounded identifier, not free text)"}
    end
  end

  defp validate_model(changeset) do
    case Ash.Changeset.fetch_change(changeset, :model_id) do
      :error ->
        # :model_id is not being set this write (e.g. a :rename that only
        # touches :title). Accept whatever is already stored.
        :ok

      {:ok, nil} ->
        :ok

      {:ok, val} when is_binary(val) and val == "" ->
        :ok

      {:ok, val} when is_binary(val) ->
        if String.length(val) <= 300 and Regex.match?(@model_pattern, val) do
          :ok
        else
          {:error, :model_id,
           "model_id must be a bounded model identifier (letters/digits/._-:/, ≤300 chars)"}
        end

      {:ok, _} ->
        {:error, :model_id, "model_id must be a model identifier string or nil"}
    end
  end

  defp validate_tools(changeset) do
    case Ash.Changeset.fetch_change(changeset, :tools) do
      :error ->
        :ok

      {:ok, tools} when is_list(tools) ->
        validate_tools_value(tools)

      {:ok, _} ->
        {:error, :tools, "tools must be a list of tool name strings (closed enum, :tenant surface)"}
    end
  end

  defp validate_tools_value(tools) do
    allowed = MapSet.new(Samen.AI.ToolSurface.names(:tenant))

    cond do
      Enum.any?(tools, &(not is_binary(&1))) ->
        {:error, :tools, "every tool must be a string (closed enum, :tenant surface)"}

      Enum.any?(tools, &String.contains?(&1, @vt_sentinel)) ->
        {:error, :tools, "tools must not contain a vt_ vault-token sentinel (INV-7)"}

      (bad = Enum.reject(tools, &MapSet.member?(allowed, &1))) != [] ->
        {:error, :tools,
         "tools contains invalid tool(s) #{inspect(bad)} — must be one of #{inspect(MapSet.to_list(allowed) |> Enum.sort())} (:tenant surface, opted-in)"}

      length(tools) != length(Enum.uniq(tools)) ->
        {:error, :tools, "tools must not contain duplicates"}

      true ->
        :ok
    end
  end
end
