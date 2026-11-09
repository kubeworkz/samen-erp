defmodule Samen.Web.Erp.OcrQuota.PubSub do
  @moduledoc """
  The realtime transport for the ERP hosted-OCR budget.

  The budget is durable and shared across nodes, but a page that read it once
  goes stale the moment another session spends a document. A successful charge
  publishes an id-only `{:ocr_quota_changed, org_id}` on this org topic; the ERP
  dashboard subscribes and re-reads the budget through its own mount, so
  exhaustion (or any other spend) shows up without a reload.

  Only the bounded org id rides the message — no document, count, vendor or
  operator identity. The subscriber never trusts a pushed budget; it re-reads
  with `Samen.Web.Erp.OcrQuota.budget/2`.

  The pubsub server is a HOST fact, read from the mount's `:pubsub` label
  (default `Driftwood.PubSub`), exactly like chat, notes and notifications. A
  host without a running server still renders every page: `subscribe/2` and
  `broadcast/2` return `{:error, _}` instead of crashing, and the page simply
  refreshes on its next navigation.
  """

  alias Samen.Web.Mount

  @doc "The per-org topic. The org id is a bounded internal identifier."
  @spec topic(String.t()) :: String.t()
  def topic(org_id) when is_binary(org_id), do: "samen:erp:ocr_quota:#{org_id}"

  @doc "The pubsub server name for a mount (`:pubsub` label; default `Driftwood.PubSub`)."
  @spec server(Mount.t()) :: atom()
  def server(%Mount{} = mount), do: Mount.label(mount, :pubsub, Driftwood.PubSub)

  @doc """
  Subscribe the calling process to one org's budget changes. Called only on a
  connected mount. Never raises: a host without a running PubSub keeps working.
  """
  @spec subscribe(Mount.t(), String.t() | nil) :: :ok | {:error, term()}
  def subscribe(%Mount{} = mount, org_id) when is_binary(org_id) do
    Phoenix.PubSub.subscribe(server(mount), topic(org_id))
  rescue
    e -> {:error, e}
  end

  def subscribe(_mount, _org_id), do: {:error, :no_org}

  @doc """
  Unsubscribe the calling process from one org's budget changes — used when the
  page's current org changes. Never raises.
  """
  @spec unsubscribe(Mount.t(), String.t() | nil) :: :ok | {:error, term()}
  def unsubscribe(%Mount{} = mount, org_id) when is_binary(org_id) do
    Phoenix.PubSub.unsubscribe(server(mount), topic(org_id))
  rescue
    e -> {:error, e}
  end

  def unsubscribe(_mount, _org_id), do: {:error, :no_org}

  @doc """
  Publish "this org's budget changed" on its topic.

  The envelope is `{:ocr_quota_changed, org_id}` — the org id only. Publishing
  is best-effort: a host without a running server returns `{:error, _}` and the
  caller still completes the charge.
  """
  @spec broadcast(atom(), String.t()) :: :ok | {:error, term()}
  def broadcast(server, org_id) when is_atom(server) and is_binary(org_id) do
    Phoenix.PubSub.broadcast(server, topic(org_id), {:ocr_quota_changed, org_id})
  rescue
    e -> {:error, e}
  end
end
