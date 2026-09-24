import Config

# =============================================================================
# Runtime Configuration (ADR-024 — the --deploy layer)
# =============================================================================
# This file is evaluated at RUNTIME (not compile time) in production.
# It reads environment variables and configures the application accordingly.
# =============================================================================

if config_env() == :prod do
  # ---------------------------------------------------------------------------
  # Database
  # ---------------------------------------------------------------------------
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :samenerp, Samenerp.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # ---------------------------------------------------------------------------
  # Audit Event App Role
  # ---------------------------------------------------------------------------
  if aud_role = System.get_env("SAMEN_AUD_EVENT_APP_ROLE") do
    config :samenerp, :aud_event_app_role, aud_role
  end

  # ---------------------------------------------------------------------------
  # Phoenix Endpoint
  # ---------------------------------------------------------------------------
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4050")

  config :samenerp, SamenerpWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true,
    # Allow WebSocket connections from production domains
    check_origin: ["//#{host}", "//65.109.232.89"]

  # ---------------------------------------------------------------------------
  # KMS Configuration
  # ---------------------------------------------------------------------------
  # ADR-045 §4.2 — the KMS adapter is selected at RUNTIME.
  # In production, use AWS KMS + DynamoDB for durable key storage.
  kms_adapter = System.get_env("SAMEN_KMS_ADAPTER") || "file_backed"

  case kms_adapter do
    "aws_kms_dynamo" ->
      config :samen_core, Samen.Kms,
        adapter: Samen.Kms.AwsKmsDynamo

      config :samen_core, Samen.Kms.AwsKmsDynamo,
        enabled: true,
        region: System.get_env("SAMEN_KMS_AWS_REGION") || "us-east-1",
        table_name: System.get_env("SAMEN_KMS_DYNAMO_TABLE") || "samenerp-kms-keys"

    "file_backed" ->
      # WARNING: only durable if the key DIR below is on a persistent volume.
      config :samen_core, Samen.Kms,
        adapter: Samen.Kms.FileBacked

      # `Samen.Kms.FileBacked` reads `:kms_key_dir` (it stores one
      # `<subject>.dek` + `master.key` per subject); the `file_path` key set
      # below is vestigial and must not be relied on.
      #
      # This MUST point at the mounted volume: the adapter's default is
      # `System.tmp_dir!()/samen_core_keystore`, which is EPHEMERAL per
      # container. A rotating keystore mints a new master (and therefore a new
      # `sys:bidx` blind-index key) on every container recreate, silently
      # invalidating every stored `email_bidx` — i.e. ALL logins break, while
      # every gate still passes. (Hit in prod 2026-09-24: 20 credentials, none
      # resolvable, because the dir was /tmp inside the container.)
      config :samen_core,
        kms_key_dir: System.get_env("SAMEN_KMS_KEY_DIR") || "/app/data/kms_keys"

      config :samen_core, Samen.Kms.FileBacked,
        file_path: System.get_env("SAMEN_KMS_FILE_PATH") || "/app/data/kms_store.json"

    _ ->
      raise "Unknown KMS adapter: #{kms_adapter}. Use 'aws_kms_dynamo' or 'file_backed'."
  end

  # ---------------------------------------------------------------------------
  # Oban (Background Jobs)
  # ---------------------------------------------------------------------------
  # The canonical queue taxonomy is installed at boot via Samen.Jobs.install_defaults/1
  # No additional configuration needed here unless you want to override limits.

  # ---------------------------------------------------------------------------
  # HuggingFace AI Integration
  # ---------------------------------------------------------------------------
  # BYOK architecture — users bring their own API keys.
  # No server-side HuggingFace configuration needed.

  # ---------------------------------------------------------------------------
  # Stripe Billing (Optional)
  # ---------------------------------------------------------------------------
  if stripe_key = System.get_env("STRIPE_SECRET_KEY") do
    config :samen_stripe, :secret_key, stripe_key
  end

  if webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET") do
    config :samen_stripe, :webhook_secret, webhook_secret
  end

  # ---------------------------------------------------------------------------
  # Email Service Provider (Optional)
  # ---------------------------------------------------------------------------
  esp_provider = System.get_env("SAMEN_ESP_PROVIDER")

  case esp_provider do
    "postmark" ->
      config :samen_postmark, :api_key, System.get_env("SAMEN_POSTMARK_API_KEY")

    "ses" ->
      config :samen_ses,
        region: System.get_env("SAMEN_SES_REGION"),
        access_key: System.get_env("SAMEN_SES_ACCESS_KEY"),
        secret_key: System.get_env("SAMEN_SES_SECRET_KEY")

    "resend" ->
      resend_api_key = System.get_env("SAMEN_RESEND_API_KEY")
      resend_from = System.get_env("SAMEN_EMAIL_FROM") || "noreply@samenerp.kubeworkz.io"

      config :samen_resend, api_key: resend_api_key, from: resend_from

      # Wire the ESP adapter for auth + lifecycle emails
      config :samen_core, Samen.Delivery.Lifecycle.EmailWorker,
        adapter: SamenResend.Provider,
        adapter_config: %{
          api_key: resend_api_key,
          from: resend_from,
          resolve_recipient:
            Samen.Delivery.AuthRecipient.resolver(
              credential_mod: Samenerp.Identity.Credential,
              user_mod: Samenerp.Identity.User
            )
        }

    provider when provider in [nil, "", " "] ->
      # No ESP configured — fail-honest (returns {:error, :not_configured})
      :ok

    other ->
      raise "Unknown ESP provider: #{other}. Use 'postmark', 'ses', or 'resend'."
  end

  # ---------------------------------------------------------------------------
  # Observability (Optional)
  # ---------------------------------------------------------------------------
  if sentry_dsn = System.get_env("SENTRY_DSN") do
    config :sentry, dsn: sentry_dsn
  end

  # OpenTelemetry
  if otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
    config :opentelemetry,
      resource: [service: "samenerp"],
      exporters: [
        otlp: [
          endpoint: otel_endpoint,
          protocol: :http_protobuf
        ]
      ]
  end

  # ---------------------------------------------------------------------------
  # Operator Authority (prod)
  # ---------------------------------------------------------------------------
  # Replace the dev-only bypass with a real resolver that checks operator membership.
  config :samenerp, :operator_authority,
    {Samenerp.OperatorAuthz, :resolve_role, [:samenerp]}

  # ---------------------------------------------------------------------------
  # Logger
  # ---------------------------------------------------------------------------
  config :logger, level: :info
end
