defmodule Samenerp.Support do
  @moduledoc """
  Customer Support module for ticketing and help desk.

  Provides a simple ticketing system for customer support.

  ## Features

  - Ticket creation and management
  - Priority levels (low, medium, high, urgent)
  - Status tracking (open, in_progress, resolved, closed)
  - Assignment to support agents
  - Internal notes
  - Customer satisfaction ratings

  ## Configuration

      config :samenerp, Samenerp.Support,
        enabled: true,
        default_priority: :medium,
        auto_assign: true

  ## Ticket Lifecycle

  1. **Created** — Customer submits a ticket
  2. **Open** — Ticket is ready for assignment
  3. **In Progress** — Agent is working on the ticket
  4. **Resolved** — Issue is fixed
  5. **Closed** — Ticket is archived

  ## Priority Levels

  - `:low` — Non-urgent, can wait
  - `:medium` — Normal priority (default)
  - `:high` — Needs attention soon
  - `:urgent` — Critical issue, immediate attention
  """

  require Logger

  @type ticket_status :: :open | :in_progress | :resolved | :closed
  @type ticket_priority :: :low | :medium | :high | :urgent

  @type ticket :: %{
          id: String.t(),
          subject: String.t(),
          description: String.t(),
          status: ticket_status(),
          priority: ticket_priority(),
          customer_id: String.t(),
          assignee_id: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Create a new support ticket.
  """
  @spec create_ticket(map()) :: {:ok, ticket()} | {:error, term()}
  def create_ticket(attrs) do
    Logger.info("[Support] Creating ticket: #{attrs.subject}")

    ticket = %{
      id: generate_id(),
      subject: attrs.subject,
      description: attrs.description,
      status: :open,
      priority: Map.get(attrs, :priority, :medium),
      customer_id: attrs.customer_id,
      assignee_id: nil,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Auto-assign if enabled
    ticket =
      if auto_assign?() do
        assign_ticket(ticket, find_available_agent())
      else
        ticket
      end

    {:ok, ticket}
  end

  @doc """
  Update a ticket's status.
  """
  @spec update_status(String.t(), ticket_status()) :: {:ok, ticket()} | {:error, term()}
  def update_status(ticket_id, new_status) do
    Logger.info("[Support] Updating ticket #{ticket_id} to #{new_status}")

    # In production, this would update the database
    # For now, return a mock ticket
    {:ok,
     %{
       id: ticket_id,
       status: new_status,
       updated_at: DateTime.utc_now()
     }}
  end

  @doc """
  Assign a ticket to an agent.
  """
  @spec assign_ticket(ticket(), String.t()) :: ticket()
  def assign_ticket(ticket, agent_id) do
    Logger.info("[Support] Assigning ticket #{ticket.id} to agent #{agent_id}")

    %{ticket | assignee_id: agent_id, updated_at: DateTime.utc_now()}
  end

  @doc """
  Add an internal note to a ticket.
  """
  @spec add_note(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_note(ticket_id, agent_id, note) do
    Logger.info("[Support] Adding note to ticket #{ticket_id}")

    # In production, this would save the note
    :ok
  end

  @doc """
  Get ticket by ID.
  """
  @spec get_ticket(String.t()) :: {:ok, ticket()} | {:error, :not_found}
  def get_ticket(ticket_id) do
    # In production, this would query the database
    # For now, return a mock ticket
    {:ok,
     %{
       id: ticket_id,
       subject: "Sample Ticket",
       description: "This is a sample ticket",
       status: :open,
       priority: :medium,
       customer_id: "customer_123",
       assignee_id: nil,
       created_at: DateTime.utc_now(),
       updated_at: DateTime.utc_now()
     }}
  end

  @doc """
  List tickets with optional filters.
  """
  @spec list_tickets(keyword()) :: [ticket()]
  def list_tickets(opts \\ []) do
    Logger.info("[Support] Listing tickets with filters: #{inspect(opts)}")

    # In production, this would query the database
    # For now, return an empty list
    []
  end

  @doc """
  Get support statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      total_tickets: 0,
      open_tickets: 0,
      in_progress_tickets: 0,
      resolved_tickets: 0,
      average_resolution_time_hours: 0,
      customer_satisfaction_score: 0
    }
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
    |> binary_part(0, 22)
  end

  defp auto_assign? do
    Application.get_env(:samenerp, __MODULE__, [])
    |> Keyword.get(:auto_assign, true)
  end

  defp find_available_agent do
    # In production, this would find an available support agent
    # For now, return a mock agent ID
    "agent_001"
  end
end
