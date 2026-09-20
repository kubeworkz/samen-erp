defmodule Samenerp.Security do
  @moduledoc """
  Security Hardening module for production deployment.

  Provides security headers, CSP configuration, and security middleware.

  ## Features

  - Content Security Policy (CSP) headers
  - HTTP Strict Transport Security (HSTS)
  - X-Content-Type-Options
  - X-Frame-Options
  - X-XSS-Protection
  - Referrer-Policy
  - Permissions-Policy

  ## Configuration

      config :samenerp, Samenerp.Security,
        csp_policy: "default-src 'self'",
        hsts_max_age: 31536000,
        enforce_https: true

  ## Security Headers

  All responses include these security headers:

  - `Content-Security-Policy` — Controls resource loading
  - `Strict-Transport-Security` — Enforce HTTPS
  - `X-Content-Type-Options` — Prevent MIME sniffing
  - `X-Frame-Options` — Prevent clickjacking
  - `X-XSS-Protection` — Enable XSS filter
  - `Referrer-Policy` — Control referrer information
  - `Permissions-Policy` — Control browser features
  """

  @doc """
  Get the default CSP policy.
  """
  @spec csp_policy() :: String.t()
  def csp_policy do
    Application.get_env(:samenerp, __MODULE__, [])
    |> Keyword.get(:csp_policy, default_csp_policy())
  end

  @doc """
  Get HSTS max age in seconds.
  """
  @spec hsts_max_age() :: integer()
  def hsts_max_age do
    Application.get_env(:samenerp, __MODULE__, [])
    |> Keyword.get(:hsts_max_age, 31_536_000)
  end

  @doc """
  Check if HTTPS should be enforced.
  """
  @spec enforce_https?() :: boolean()
  def enforce_https? do
    Application.get_env(:samenerp, __MODULE__, [])
    |> Keyword.get(:enforce_https, true)
  end

  @doc """
  Get all security headers as a list of tuples.
  """
  @spec security_headers() :: [{String.t(), String.t()}]
  def security_headers do
    [
      {"content-security-policy", csp_policy()},
      {"strict-transport-security", "max-age=#{hsts_max_age()}"},
      {"x-content-type-options", "nosniff"},
      {"x-frame-options", "DENY"},
      {"x-xss-protection", "1; mode=block"},
      {"referrer-policy", "strict-origin-when-cross-origin"},
      {"permissions-policy", "camera=(), microphone=(), geolocation=()"}
    ]
  end

  @doc """
  Apply security headers to a Plug.Conn.
  """
  @spec apply_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def apply_headers(conn) do
    Enum.reduce(security_headers(), conn, fn {header, value}, conn ->
      Plug.Conn.put_resp_header(conn, header, value)
    end)
  end

  @doc """
  Check if a request is secure (HTTPS).
  """
  @spec secure_request?(Plug.Conn.t()) :: boolean()
  def secure_request?(conn) do
    conn.scheme == :https or
      conn.req_headers["x-forwarded-proto"] == "https"
  end

  @doc """
  Redirect to HTTPS if not secure.
  """
  @spec enforce_https(Plug.Conn.t()) :: Plug.Conn.t() | :ok
  def enforce_https(conn) do
    if enforce_https?() and not secure_request?(conn) do
      https_url = "https://#{conn.host}#{conn.request_path}"
      Plug.Conn.redirect(conn, to: https_url)
    else
      conn
    end
  end

  @doc """
  Generate a nonce for CSP.
  """
  @spec generate_nonce() :: String.t()
  def generate_nonce do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
  end

  @doc """
  Check if a path is safe for redirection (open redirect prevention).
  """
  @spec safe_redirect?(String.t()) :: boolean()
  def safe_redirect?(path) do
    # Only allow relative paths
    not String.starts_with?(path, "http://") and
      not String.starts_with?(path, "https://") and
      not String.contains?(path, "..")
  end

  defp default_csp_policy do
    "default-src 'self'; " <>
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data: https:; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self' https://huggingface.co; " <>
      "frame-ancestors 'none'"
  end
end
