defmodule Samen.Web.AI.AssistantReads do
  @moduledoc """
  The TENANT-plane read seam behind `Samen.Web.AI.AssistantLive` (OpenClaw-lite P1).

  Every read here is org-scoped from the TRUSTED mount scope (never from params) and
  the ONE vault-routed value — `Samen.AI.AssistantConversation.transcript`
  (`pii do vault(:pii_transcript) … end`) — is resolved through
  `Samen.Api.PiiResolution` **on the actor's plane**, exactly like
  `Samen.Web.AI.AgentReads`. Nothing here hand-masks and nothing branches on plane:
  the resolver is the gate (ADR-042).

  ## The vault-routed field

  `AssistantConversation.transcript` is JSON of the bounded turn list
  `%{"turns" => [%{"role" => role, "content" => content, ...}, …]}` stored inside
  the DEK envelope keyed on the conversation's own id (`pii_asc_transcript` at the
  DB layer, `Samen.Vault.Change.resolve_subject_id/1` per-row crypto-shred unit).
  The domain column holds a `vt_*` token; the read presents `%Samen.Masked{}` on an
  operator plane without a grant; the reveal path is the single
  `Samen.Vault.reveal/3` chokepoint bound to `subject_id: conversation.id`.
  Every other column is token/count/bounded-label only (ids, names, counts,
  timestamps) — no sample values outside the envelope, so they need no resolution.

  ## Org-scope pins (deny-by-default, drop-filter-flips-a-test)

  Every list/get here filters `org_id == ^org_id` from the TRUSTED scope, never
  from params. Dropping any filter would let a caller render another org's
  assistant or thread. Conversation reads additionally filter by `assistant_id`
  where applicable, so a thread of one assistant cannot be surfaced under another.
  """

  require Ash.Query

  alias Samen.AI.Assistant
  alias Samen.AI.AssistantConversation
  alias Samen.Web.Mount

  # ---------------------------------------------------------------------------
  # Assistants
  # ---------------------------------------------------------------------------

  @doc """
  This org's assistants, newest first (bounded labels only — no vault field).

  ORG-SCOPE PIN: `org_id == ^org_id` comes from the trusted scope. Dropping it
  would let a tenant list another org's assistants.
  """
  @spec list_assistants(Mount.t(), String.t() | nil, keyword()) :: [map()]
  def list_assistants(_mount, nil, _opts), do: []

  def list_assistants(_mount, org_id, opts) when is_binary(org_id) do
    Assistant
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(Keyword.get(opts, :limit, 20))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  ONE assistant, org-scoped. Returns `{:ok, assistant}` or
  `{:error, :not_found}` for a foreign org (no existence oracle — RP-AG-10).
  """
  @spec get_assistant(Mount.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_assistant(_mount, nil, _id), do: {:error, :not_found}

  def get_assistant(_mount, org_id, id) when is_binary(org_id) and is_binary(id) do
    Assistant
    |> Ash.Query.filter(org_id == ^org_id and id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def get_assistant(_mount, _org_id, _id), do: {:error, :not_found}

  @doc """
  ONE assistant by name, org-scoped (the `name` is a bounded identifier, not
  free text). Same oracle discipline as `get_assistant/3`.
  """
  @spec get_assistant_by_name(Mount.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_assistant_by_name(_mount, nil, _name), do: {:error, :not_found}

  def get_assistant_by_name(_mount, org_id, name)
      when is_binary(org_id) and is_binary(name) do
    Assistant
    |> Ash.Query.filter(org_id == ^org_id and name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, row}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Conversations
  # ---------------------------------------------------------------------------

  @doc """
  This org's conversations under one assistant, newest first (token-only columns;
  the vault `transcript` is NOT selected in the list — decode only on get).

  ORG-SCOPE PIN: `org_id == ^org_id` and `assistant_id == ^assistant_id` are
  both from trusted state. Dropping either cross-scopes.
  """
  @spec list_conversations(Mount.t(), String.t() | nil, String.t() | nil, keyword()) :: [map()]
  def list_conversations(_mount, nil, _assistant_id, _opts), do: []
  def list_conversations(_mount, _org_id, nil, _opts), do: []

  def list_conversations(_mount, org_id, assistant_id, opts)
      when is_binary(org_id) and is_binary(assistant_id) do
    AssistantConversation
    |> Ash.Query.filter(org_id == ^org_id and assistant_id == ^assistant_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  All conversations in the org (assistant-agnostic), newest first. Used for the
  unified inbox / recent list. Still org-scoped.
  """
  @spec list_all_conversations(Mount.t(), String.t() | nil, keyword()) :: [map()]
  def list_all_conversations(_mount, nil, _opts), do: []

  def list_all_conversations(_mount, org_id, opts) when is_binary(org_id) do
    AssistantConversation
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(last_message_at: :desc)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  ONE conversation, with its transcript RESOLVED on the mount's plane.

  Returns `{:ok, %{conversation: resolved, turns: [turn], title: title}}` or
  `{:error, :not_found}` for a foreign org (no existence oracle).

  `turns` are `%{"role" => role, "content" => content, ...}` maps decoded from
  the JSON envelope. On a masked plane each turn's content is individually
  `%Samen.Masked{}`-aware via the envelope decode below — the whole transcript
  is either clear or a single `Masked` wrapper, never a half-masked mix (the
  envelope is one vault field). The template renders what it is handed.
  """
  @spec get_conversation(Mount.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_conversation(_mount, nil, _conv_id), do: {:error, :not_found}

  def get_conversation(mount, org_id, conv_id)
      when is_binary(org_id) and is_binary(conv_id) do
    AssistantConversation
    |> Ash.Query.filter(org_id == ^org_id and id == ^conv_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} ->
        [resolved] =
          Samen.Api.PiiResolution.resolve([row], AssistantConversation, actor_of(mount, org_id),
            repo: mount.repo
          )

        turns = decode_turns(Map.get(resolved, :transcript))

        {:ok,
         %{
           conversation: resolved,
           turns: turns,
           title: Map.get(resolved, :title),
           masked?: masked?(Map.get(resolved, :transcript))
         }}

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def get_conversation(_mount, _org_id, _conv_id), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp actor_of(mount, org_id) do
    case Mount.scope(mount, org_id) do
      %Samen.Scope{actor: actor} -> actor
      other -> other
    end
  end

  defp masked?(%Samen.Masked{}), do: true
  defp masked?(_), do: false

  # The transcript JSON is inside the vault envelope. On a clear plane we get a
  # binary and decode it; on a masked plane we get `%Samen.Masked{}` and must
  # not try to Jason.decode it — return a single masked turn so the template
  # renders `••••` with no `vt_*` in the DOM.
  defp decode_turns(%Samen.Masked{} = masked), do: [%{"role" => "assistant", "content" => masked}]

  defp decode_turns(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"turns" => turns}} when is_list(turns) ->
        turns
        |> Enum.filter(&is_map/1)
        |> Enum.filter(fn t -> is_binary(Map.get(t, "role")) and not is_nil(Map.get(t, "content")) end)

      {:ok, _other} ->
        []

      _ ->
        []
    end
  end

  defp decode_turns(_other), do: []
end
