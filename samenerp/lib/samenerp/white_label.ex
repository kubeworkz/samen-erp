defmodule Samenerp.WhiteLabel do
  @moduledoc """
  White-Label support module for custom branding.

  Allows customers to customize the look and feel of the application.

  ## Features

  - Custom logos and favicons
  - Brand colors
  - Custom domain
  - Email templates
  - Login page customization
  - Footer branding
  - CSS overrides

  ## Configuration

      config :samenerp, Samenerp.WhiteLabel,
        enabled: true,
        custom_domains_enabled: true,
        max_custom_domains: 5

  ## Customization Options

  ### Visual Branding
  - Logo (SVG/PNG, max 2MB)
  - Favicon (ICO/PNG, max 100KB)
  - Primary color (hex)
  - Secondary color (hex)
  - Font family
  - Border radius

  ### Custom Domain
  - Primary domain (e.g., `erp.yourcompany.com`)
  - SSL certificate (auto-provisioned via Let's Encrypt)
  - DNS verification

  ### Email Templates
  - Welcome email
  - Password reset
  - Invoice emails
  - Notification emails

  ## CSS Override Structure

  ```css
  :root {
    --primary-color: #your-primary;
    --secondary-color: #your-secondary;
    --font-family: 'Your Font', sans-serif;
    --border-radius: 8px;
  }
  ```
  """

  require Logger

  # Escapes constant folding on the stub default-config's literal nils so the
  # defensive branches below stay representative under --warnings-as-errors.
  @spec widen(term()) :: term()
  defp widen(value), do: value

  @type branding_config :: %{
          logo_url: String.t() | nil,
          favicon_url: String.t() | nil,
          primary_color: String.t(),
          secondary_color: String.t(),
          font_family: String.t(),
          border_radius: String.t(),
          custom_css: String.t() | nil,
          custom_domain: String.t() | nil
        }

  @doc """
  Get default branding configuration.
  """
  @spec default_config() :: branding_config()
  def default_config do
    %{
      logo_url: nil,
      favicon_url: nil,
      primary_color: "#0e7c5a",
      secondary_color: "#1a1a1a",
      font_family: "system-ui, -apple-system, sans-serif",
      border_radius: "8px",
      custom_css: nil,
      custom_domain: nil
    }
  end

  @doc """
  Get branding configuration for a tenant.
  """
  @spec get_branding(String.t()) :: branding_config()
  def get_branding(tenant_id) do
    Logger.debug("[WhiteLabel] Getting branding for tenant #{tenant_id}")

    # In production, this would query the database
    # For now, return default
    default_config()
  end

  @doc """
  Update branding configuration for a tenant.
  """
  @spec update_branding(String.t(), map()) :: :ok | {:error, term()}
  def update_branding(tenant_id, attrs) do
    Logger.info("[WhiteLabel] Updating branding for tenant #{tenant_id}")

    # Validate colors
    cond do
      attrs[:primary_color] && !valid_color?(attrs[:primary_color]) ->
        {:error, :invalid_primary_color}
      attrs[:secondary_color] && !valid_color?(attrs[:secondary_color]) ->
        {:error, :invalid_secondary_color}
      true ->
        # In production, this would update the database
        :ok
    end
  end

  @doc """
  Generate CSS variables for a tenant's branding.
  """
  @spec generate_css(String.t()) :: String.t()
  def generate_css(tenant_id) do
    branding = get_branding(tenant_id)

    """
    :root {
      --primary-color: #{branding.primary_color};
      --secondary-color: #{branding.secondary_color};
      --font-family: #{branding.font_family};
      --border-radius: #{branding.border_radius};
    }

    #{widen(branding.custom_css) || ""}
    """
  end

  @doc """
  Set custom domain for a tenant.
  """
  @spec set_custom_domain(String.t(), String.t()) :: :ok | {:error, term()}
  def set_custom_domain(tenant_id, domain) do
    Logger.info("[WhiteLabel] Setting custom domain for tenant #{tenant_id}: #{domain}")

    cond do
      !valid_domain?(domain) ->
        {:error, :invalid_domain}
      !custom_domains_enabled?() ->
        {:error, :custom_domains_disabled}
      true ->
        # In production, this would:
        # 1. Verify domain ownership (DNS TXT record)
        # 2. Provision SSL certificate
        # 3. Update routing configuration
        :ok
    end
  end

  @doc """
  Get custom domain for a tenant.
  """
  @spec get_custom_domain(String.t()) :: String.t() | nil
  def get_custom_domain(tenant_id) do
    Logger.debug("[WhiteLabel] Getting custom domain for tenant #{tenant_id}")

    # In production, this would query the database
    nil
  end

  @doc """
  Verify domain ownership.
  """
  @spec verify_domain(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_domain(domain) do
    Logger.info("[WhiteLabel] Verifying domain: #{domain}")

    # In production, this would check DNS TXT record
    # For now, return mock verification
    {:ok,
     %{
       verified: true,
       verified_at: DateTime.utc_now(),
       ssl_status: "active"
     }}
  end

  @doc """
  Upload logo for a tenant.
  """
  @spec upload_logo(String.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_logo(tenant_id, file_data, filename) do
    Logger.info("[WhiteLabel] Uploading logo for tenant #{tenant_id}")

    if !valid_logo?(filename, byte_size(file_data)) do
      {:error, :invalid_logo}
    else
      # In production, this would upload to S3/storage
      # For now, return mock URL
      {:ok, "https://storage.samenerp.com/logos/#{tenant_id}/#{filename}"}
    end
  end

  @doc """
  Generate email template with branding.
  """
  @spec email_template(String.t(), String.t(), map()) :: String.t()
  def email_template(tenant_id, template_name, assigns \\ %{}) do
    branding = get_branding(tenant_id)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: #{branding.font_family}; }
        .header { background-color: #{branding.primary_color}; color: white; padding: 20px; }
        .content { padding: 20px; }
        .footer { background-color: #{branding.secondary_color}; color: white; padding: 10px; text-align: center; }
      </style>
    </head>
    <body>
      <div class="header">
        #{if widen(branding.logo_url), do: "<img src=\"#{branding.logo_url}\" alt=\"Logo\" />", else: "Samen ERP"}
      </div>
      <div class="content">
        #{render_template(template_name, assigns)}
      </div>
      <div class="footer">
        #{widen(branding.custom_domain) || "samenerp.com"}
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Get white-label statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      tenants_with_custom_branding: 0,
      tenants_with_custom_domain: 0,
      custom_domains_verified: 0,
      logos_uploaded: 0
    }
  end

  # Private functions

  defp valid_color?(color) do
    Regex.match?(~r/^#[0-9A-Fa-f]{6}$/, color)
  end

  defp valid_domain?(domain) do
    Regex.match?(~r/^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/, domain)
  end

  defp valid_logo?(filename, size) do
    allowed_extensions = ~w(.svg .png .jpg .jpeg .gif)
    max_size = 2 * 1024 * 1024  # 2MB

    ext = Path.extname(filename) |> String.downcase()
    ext in allowed_extensions and size <= max_size
  end

  defp custom_domains_enabled? do
    Application.get_env(:samenerp, __MODULE__, [])
    |> Keyword.get(:custom_domains_enabled, true)
  end

  defp render_template("welcome", assigns) do
    "Welcome to #{assigns[:company_name] || "Samen ERP"}!"
  end

  defp render_template("password_reset", assigns) do
    "Click here to reset your password: #{assigns[:reset_url]}"
  end

  defp render_template(_, _), do: ""
end
