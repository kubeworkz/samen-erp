defmodule Samenerp.AuditLog do
  @moduledoc """
  Customer-facing Audit Log for compliance and transparency.

  Provides an audit trail of all user actions within a tenant.

  ## Features

  - Immutable append-only log
  - User action tracking
  - Resource changes
  - IP address logging
  - Export capabilities (CSV, JSON)
  - Retention policy

  ## Configuration

      config :samenerp, Samenerp.AuditLog,
        enabled: true,
        retention_days: 365,
        export_enabled: true

  ## Audit Events

  | Event | Description |
  |---|---|
  | `user.login` | User logged in |
  | `user.logout` | User logged out |
  | `user.create` | User created |
  | `user.update` | User updated |
  | `user.delete` | User deleted |
  | `resource.create` | Resource created |
  | `resource.update` | Resource updated |
  | `resource.delete` | Resource deleted |
  | `settings.update` | Settings changed |
  | `api_key.create` | API key created |
  | `api_key.revoke` | API key revoked |

  ## Export Format

  ### CSV
  ```csv
  timestamp,event,user_id,resource_type,resource_id,ip_address,details
  2026-01-15T10:30:00Z,user.login,user_123,,,192.168.1.1,"{""browser"":""Chrome""}"
  ```

  ### JSON
  ```json
  {
    "timestamp": "2026-01-15T10:30:00Z",
    "event": "user.login",
    "user_id": "user_123",
    "ip_address": "192.168.1.1"
  }
  ```
  """

  require Logger

  @type audit_entry :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          event: String.t(),
          user_id: String.t() | nil,
          resource_type: String.t() | nil,
          resource_id: String.t() | nil,
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          details: map()
        }

  @doc """
  Log an audit event.
  """
  @spec log(map()) :: {:ok, String.t()} | {:error, term()}
  def log(attrs) do
    entry = %{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      event: attrs.event,
      user_id: attrs[:user_id],
      resource_type: attrs[:resource_type],
      resource_id: attrs[:resource_id],
      ip_address: attrs[:ip_address],
      user_agent: attrs[:user_agent],
      details: attrs[:details] || %{}
    }

    Logger.info("[AuditLog] #{entry.event} by #{entry.user_id || "system"}")

    # In production, this would append to database
    # For now, just log
    {:ok, entry.id}
  end

  @doc """
  Log user login.
  """
  @spec log_login(String.t(), String.t(), map()) :: {:ok, String.t()}
  def log_login(user_id, ip_address, details \\ %{}) do
    log(%{
      event: "user.login",
      user_id: user_id,
      ip_address: ip_address,
      details: details
    })
  end

  @doc """
  Log user logout.
  """
  @spec log_logout(String.t(), String.t()) :: {:ok, String.t()}
  def log_logout(user_id, ip_address) do
    log(%{
      event: "user.logout",
      user_id: user_id,
      ip_address: ip_address
    })
  end

  @doc """
  Log resource creation.
  """
  @spec log_create(String.t(), String.t(), String.t(), map()) :: {:ok, String.t()}
  def log_create(user_id, resource_type, resource_id, details \\ %{}) do
    log(%{
      event: "resource.create",
      user_id: user_id,
      resource_type: resource_type,
      resource_id: resource_id,
      details: details
    })
  end

  @doc """
  Log resource update.
  """
  @spec log_update(String.t(), String.t(), String.t(), map()) :: {:ok, String.t()}
  def log_update(user_id, resource_type, resource_id, details \\ %{}) do
    log(%{
      event: "resource.update",
      user_id: user_id,
      resource_type: resource_type,
      resource_id: resource_id,
      details: details
    })
  end

  @doc """
  Log resource deletion.
  """
  @spec log_delete(String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def log_delete(user_id, resource_type, resource_id) do
    log(%{
      event: "resource.delete",
      user_id: user_id,
      resource_type: resource_type,
      resource_id: resource_id
    })
  end

  @doc """
  Query audit log entries.
  """
  @spec query(map()) :: [audit_entry()]
  def query(filters \\ %{}) do
    Logger.info("[AuditLog] Querying with filters: #{inspect(filters)}")

    # In production, this would query the database
    # For now, return empty list
    []
  end

  @doc """
  Export audit log to CSV.
  """
  @spec export_csv(map()) :: {:ok, String.t()} | {:error, term()}
  def export_csv(filters \\ %{}) do
    Logger.info("[AuditLog] Exporting to CSV")

    entries = query(filters)

    header = "timestamp,event,user_id,resource_type,resource_id,ip_address,details\n"

    rows =
      Enum.map(entries, fn entry ->
        "#{entry.timestamp},#{entry.event},#{entry.user_id || ""},#{entry.resource_type || ""},#{entry.resource_id || ""},#{entry.ip_address || ""},#{Jason.encode!(entry.details)}"
      end)
      |> Enum.join("\n")

    {:ok, header <> rows}
  end

  @doc """
  Export audit log to JSON.
  """
  @spec export_json(map()) :: {:ok, String.t()} | {:error, term()}
  def export_json(filters \\ %{}) do
    Logger.info("[AuditLog] Exporting to JSON")

    entries = query(filters)

    {:ok, Jason.encode!(entries, pretty: true)}
  end

  @doc """
  Get audit log statistics.
  """
  @spec stats(map()) :: map()
  def stats(filters \\ %{}) do
    Logger.info("[AuditLog] Calculating stats")

    # In production, this would aggregate from database
    # For now, return mock stats
    %{
      total_entries: 0,
      events_by_type: %{},
      active_users: 0,
      date_range: %{
        from: nil,
        to: nil
      }
    }
  end

  @doc """
  Purge old audit log entries based on retention policy.
  """
  @spec purge_old_entries() :: {:ok, integer()} | {:error, term()}
  def purge_old_entries do
    Logger.info("[AuditLog] Purging old entries")

    retention_days = retention_days()
    cutoff_date = DateTime.utc_now() |> DateTime.add(-retention_days, :day)

    # In production, this would delete old entries
    # For now, return 0
    {:ok, 0}
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  defp retention_days do
    Application.get_env(:samenerp, __MODULE__, [])
    |> Keyword.get(:retention_days, 365)
  end
end
