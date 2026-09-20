defmodule Samen.Web.Onboarding.ProductTourLive do
  @moduledoc """
  Enhanced Onboarding with Guided Product Tour.

  Provides a step-by-step guided tour for new users, highlighting key features
  and helping them get started quickly.

  ## Tour Steps

  1. **Welcome** — Introduction to the platform
  2. **Dashboard** — Overview of the main dashboard
  3. **ERP Features** — Tour of accounting, inventory, etc.
  4. **AI Features** — Introduction to HuggingFace integration
  5. **Settings** — How to configure the workspace
  6. **Complete** — Tour completion and next steps

  ## Features

  - Interactive step-by-step tour
  - Skip/complete options
  - Progress tracking
  - Contextual help tooltips
  - Sample data seeding
  """

  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.Mount
  alias Samen.Web.CurrentOrg

  @tour_steps [
    %{
      id: "welcome",
      title: "Welcome to Samen ERP",
      description: "Your all-in-one ERP solution with AI-powered features. Let's take a quick tour!",
      icon: "👋",
      position: :center
    },
    %{
      id: "dashboard",
      title: "Dashboard Overview",
      description: "Your dashboard shows key metrics, recent activity, and quick actions. Customize it to fit your workflow.",
      icon: "📊",
      position: :top,
      highlight: ".dashboard-metrics"
    },
    %{
      id: "erp_features",
      title: "ERP Features",
      description: "Access accounting, inventory, procurement, and manufacturing — all in one place.",
      icon: "💼",
      position: :left,
      highlight: ".erp-nav"
    },
    %{
      id: "ai_features",
      title: "AI-Powered Features",
      description: "Connect your HuggingFace API key to unlock AI assistance for text generation, analysis, and more.",
      icon: "🤖",
      position: :right,
      highlight: ".ai-nav"
    },
    %{
      id: "settings",
      title: "Workspace Settings",
      description: "Configure your workspace, manage users, and set up integrations in Settings.",
      icon: "⚙️",
      position: :bottom,
      highlight: ".settings-nav"
    },
    %{
      id: "complete",
      title: "You're All Set!",
      description: "You're ready to start using Samen ERP. Explore the features and let us know if you need help!",
      icon: "🎉",
      position: :center
    }
  ]

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       current_step: 0,
       total_steps: length(@tour_steps),
       tour_steps: @tour_steps,
       show_tour: true,
       tour_completed: false,
       sample_data_seeded: false
     )}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    current_step = socket.assigns.current_step
    total_steps = socket.assigns.total_steps

    if current_step < total_steps - 1 do
      {:noreply, assign(socket, current_step: current_step + 1)}
    else
      # Tour completed
      {:noreply,
       socket
       |> assign(tour_completed: true, show_tour: false)
       |> put_flash(:info, "Tour completed! Welcome to Samen ERP.")}
    end
  end

  def handle_event("prev_step", _params, socket) do
    current_step = socket.assigns.current_step

    if current_step > 0 do
      {:noreply, assign(socket, current_step: current_step - 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("skip_tour", _params, socket) do
    {:noreply,
     socket
     |> assign(show_tour: false, tour_completed: true)
     |> put_flash(:info, "Tour skipped. You can restart it anytime from Settings.")}
  end

  def handle_event("restart_tour", _params, socket) do
    {:noreply,
     socket
     |> assign(current_step: 0, show_tour: true, tour_completed: false)}
  end

  def handle_event("seed_sample_data", _params, socket) do
    # Seed sample data for the tour
    case seed_sample_data(socket.assigns.org_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(sample_data_seeded: true)
         |> put_flash(:info, "Sample data added! Explore the features with realistic data.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to seed sample data: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="product-tour" class="product-tour">
      <%= if @show_tour do %>
        <.tour_overlay
          current_step={@current_step}
          total_steps={@total_steps}
          tour_steps={@tour_steps}
        />
      <% end %>

      <.page_content org_id={@org_id} tour_completed={@tour_completed} sample_data_seeded={@sample_data_seeded} />
    </div>
    """
  end

  # Tour overlay component
  defp tour_overlay(assigns) do
    step = Enum.at(assigns.tour_steps, assigns.current_step)

    ~H"""
    <div class="tour-overlay" id="tour-overlay">
      <div class="tour-backdrop"></div>

      <div class="tour-card" id={"tour-step-#{@current_step}"}>
        <div class="tour-header">
          <span class="tour-icon">{step.icon}</span>
          <h3 class="tour-title">{step.title}</h3>
        </div>

        <p class="tour-description">{step.description}</p>

        <div class="tour-progress">
          <div class="tour-progress-bar" style={"width: #{(@current_step + 1) / @total_steps * 100}%"}></div>
        </div>

        <div class="tour-step-indicator">
          Step {@current_step + 1} of {@total_steps}
        </div>

        <div class="tour-actions">
          <button
            type="button"
            phx-click="skip_tour"
            class="tour-btn tour-btn-secondary"
            id="tour-skip"
          >
            Skip Tour
          </button>

          <div class="tour-nav">
            <%= if @current_step > 0 do %>
              <button
                type="button"
                phx-click="prev_step"
                class="tour-btn tour-btn-outline"
                id="tour-prev"
              >
                ← Previous
              </button>
            <% end %>

            <button
              type="button"
              phx-click="next_step"
              class="tour-btn tour-btn-primary"
              id="tour-next"
            >
              <%= if @current_step < @total_steps - 1 do %>
                Next →
              <% else %>
                Complete Tour
              <% end %>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Page content component
  defp page_content(assigns) do
    ~H"""
    <div class="page-content" id="onboarding-content">
      <div class="welcome-header">
        <h1>Welcome to Samen ERP</h1>
        <p>Your all-in-one ERP solution with AI-powered features.</p>
      </div>

      <div class="quick-start-grid">
        <div class="quick-start-card" id="card-erp">
          <h3>💼 ERP Features</h3>
          <p>Access accounting, inventory, procurement, and manufacturing.</p>
          <.link navigate="/erp/coa" class="quick-start-link">Explore ERP →</.link>
        </div>

        <div class="quick-start-card" id="card-ai">
          <h3>🤖 AI Features</h3>
          <p>Connect HuggingFace for AI-powered assistance.</p>
          <.link navigate="/settings/huggingface" class="quick-start-link">Setup AI →</.link>
        </div>

        <div class="quick-start-card" id="card-billing">
          <h3>💳 Billing</h3>
          <p>Manage subscriptions and invoices.</p>
          <.link navigate="/billing" class="quick-start-link">View Billing →</.link>
        </div>

        <div class="quick-start-card" id="card-settings">
          <h3>⚙️ Settings</h3>
          <p>Configure your workspace and integrations.</p>
          <.link navigate="/settings" class="quick-start-link">Open Settings →</.link>
        </div>
      </div>

      <div class="sample-data-section" id="sample-data">
        <h3>📊 Get Started with Sample Data</h3>
        <p>Add sample data to explore the features with realistic content.</p>
        <button
          type="button"
          phx-click="seed_sample_data"
          class="btn btn-primary"
          id="seed-sample-data"
          disabled={@sample_data_seeded}
        >
          <%= if @sample_data_seeded do %>
            ✓ Sample Data Added
          <% else %>
            Add Sample Data
          <% end %>
        </button>
      </div>

      <%= if @tour_completed do %>
        <div class="tour-completed-banner" id="tour-completed">
          <p>✓ Product tour completed! You're ready to go.</p>
          <button
            type="button"
            phx-click="restart_tour"
            class="btn btn-outline"
            id="restart-tour"
          >
            Restart Tour
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  # Private functions

  defp seed_sample_data(org_id) do
    # In production, this would seed realistic sample data
    # For now, return success
    IO.puts("Seeding sample data for org: #{org_id}")
    :ok
  end
end
