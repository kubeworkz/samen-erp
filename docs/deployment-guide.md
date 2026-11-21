# Samenerp Deployment Guide

This guide covers deploying Samenerp as an enterprise SaaS service.

> **What ships.** Deployment files, the served `/api/openapi.json`, the health
> probes and the Support-scope mount are real. Monitoring, plan-based rate
> limiting, SSO/SAML, customer audit-log export, data residency, white-label
> branding and security-header middleware are unwired host shells, and
> `/metrics` is egress-off by default. Steps that depend on them are called out
> below.

## Prerequisites

- Docker and Docker Compose installed
- A domain name (for production)
- A Stripe account **only if** you wire live billing (optional — the host boots
  fail-honest with billing unconfigured)
- No HuggingFace account is needed server-side: AI keys are tenant-supplied
  (BYOK) and the core runs keyless

## Quick Start (Local Development)

### 1. Clone and Setup

```bash
git clone https://github.com/kubeworkz/samen-erp.git
cd samen-erp/samenerp
```

### 2. Create Environment File

No `.env.example` is checked in. Create `.env` with at least a secret key base;
Compose defaults the rest for local development:

```bash
printf 'SECRET_KEY_BASE=%s\n' "$(mix phx.gen.secret)" > .env
```

### 3. Start Services

```bash
docker-compose up -d
```

### 4. Run Migrations

```bash
docker-compose exec app /app/samenerp/bin/samenerp eval "Samenerp.Release.migrate()"
```

### 5. Seed Database

The container entrypoint already runs `Samenerp.Seeds.seed!/0` before the app
starts. There is no `priv/repo/seeds.exs`, so `Samenerp.Release.seed()` only
prints "No seed file found" — it is not the seed step.

### 6. Access the Application

- **Web UI:** http://localhost:4050
- **Health Check:** http://localhost:4050/healthz
- **Readiness Check:** http://localhost:4050/readyz
- **API:** http://localhost:4050/api/v1

## Production Deployment

### Option 1: Fly.io (Recommended)

Fly.io is the recommended platform for deploying Elixir/Phoenix applications.

#### 1. Install Fly CLI

```bash
curl -L https://fly.io/install.sh | sh
fly auth login
```

#### 2. Launch the App

```bash
cd samenerp
fly launch --no-deploy
```

`--no-deploy` stops `fly launch` from starting a Machine before the volume and
mount exist; the first deploy is step 7.

#### 3. Create the KMS Volume

The file-backed keystore needs a Fly volume; without one, every deploy that
replaces the machine mints a new master key and invalidates every stored blind
index, so all logins break. A volume is per-machine, so create one per machine
(`--count N`), in the app's primary region (`primary_region` in `fly.toml`;
`ord` below). `--size` is in GB and defaults to 1; `--yes` skips the
confirmation prompt. The `initial_size` in step 4 makes `fly deploy` create any
extra volumes a multi-machine app needs, so one is enough here:

```bash
fly volumes create samenerp_kms --region ord --size 1 --yes
```

#### 4. Mount It in `fly.toml`

`fly launch` generated `fly.toml`; add (or extend) its `[mounts]` block so the
keystore path is the volume rather than the container filesystem:

```toml
[mounts]
  source = "samenerp_kms"
  destination = "/app/data/kms_keys"
  initial_size = "1gb"
```

`initial_size` is used only when `fly deploy` has to create a missing volume
(it ignores the flag when one already exists, and `fly volumes create` ignores
it entirely).

This must match `SAMEN_KMS_KEY_DIR` in the next step. If you already mount a
volume at `/app/data` for other durable data, mount that one instead, chown
`/app/data` (not its `kms_keys` child) in step 5, and leave
`SAMEN_KMS_KEY_DIR` pointing at the child.

#### 5. Set the Mount's Owner Before the First Deploy

The image runs as the non-root `app` user (uid 1000), so the keystore directory
must be writable by that uid — a fresh Fly volume is not guaranteed to be. Do it
from a throwaway Machine with the volume mounted: `fly ssh console` only reaches
a *running* app Machine, so it cannot be relied on after a deploy whose first
boot failed.

```bash
fly machine run --app samenerp --region ord --rm \
  --volume samenerp_kms:/app/data/kms_keys \
  alpine:3 chown 1000:1000 /app/data/kms_keys
```

`--rm` destroys the throwaway Machine on exit and releases the volume, and
`fly deploy` ignores Machines it did not create.

#### 6. Set Secrets

```bash
fly secrets set \
  DATABASE_URL="ecto://postgres:PASSWORD@HOST/samenerp" \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  PHX_HOST="your-domain.com" \
  SAMEN_KMS_ADAPTER="file_backed" \
  SAMEN_KMS_KEY_DIR="/app/data/kms_keys"
```

`SAMEN_KMS_KEY_DIR` MUST be on a persistent volume. The file-backed adapter
mints a master key on first keystore use; a fresh container with an ephemeral
dir mints a new one and silently invalidates every stored blind index, so every
login fails while the gates still pass. `aws_kms_dynamo` is a boot-refusing
skeleton today (`Samen.Kms.assert_prod_adapter_ready!/0` refuses it), and no
code reads `SAMEN_KMS_AWS_ACCESS_KEY_ID` / `SAMEN_KMS_AWS_SECRET_ACCESS_KEY`.

Billing is optional: the host boots fail-honest with the provider unconfigured,
and nothing wires a live Stripe provider by default. Only if you have wired a
live billing adapter, add:

```bash
fly secrets set \
  STRIPE_SECRET_KEY="sk_live_..." \
  STRIPE_WEBHOOK_SECRET="whsec_..."
```

#### 7. Deploy

```bash
fly deploy
```

### Option 2: AWS ECS/Fargate

#### 1. Build and Push Docker Image

```bash
# Build
docker build -t samenerp .

# Tag for ECR
docker tag samenerp:latest ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/samenerp:latest

# Push
docker push ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/samenerp:latest
```

#### 2. Create ECS Task Definition

```json
{
  "family": "samenerp",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "containerDefinitions": [
    {
      "name": "samenerp",
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/samenerp:latest",
      "portMappings": [
        {
          "containerPort": 4050,
          "hostPort": 4050
        }
      ],
      "environment": [
        {"name": "PORT", "value": "4050"},
        {"name": "PHX_SERVER", "value": "true"},
        {"name": "PHX_HOST", "value": "your-domain.com"}
      ],
      "secrets": [
        {"name": "DATABASE_URL", "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT:secret:samenerp/database-url"},
        {"name": "SECRET_KEY_BASE", "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT:secret:samenerp/secret-key-base"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/samenerp",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

### Option 3: Kubernetes

#### 1. Create Namespace

```bash
kubectl create namespace samenerp
```

#### 2. Create Secrets

```bash
kubectl create secret generic samenerp-secrets \
  --namespace=samenerp \
  --from-literal=DATABASE_URL="ecto://postgres:PASSWORD@HOST/samenerp" \
  --from-literal=SECRET_KEY_BASE="$(mix phx.gen.secret)"
```

#### 3. Deploy

No Kubernetes manifests are checked in, so there is no `k8s/` directory to
apply. Write a Deployment/Service/Ingress for the `samenerp` image, using the
environment and secret shape from the Fly.io and ECS sections above.

## Environment Variables Reference

### Required

| Variable | Description | Example |
|---|---|---|
| `DATABASE_URL` | PostgreSQL connection URL | `ecto://postgres:pass@host/db` |
| `SECRET_KEY_BASE` | Phoenix secret key base | `mix phx.gen.secret` |
| `PHX_HOST` | Production domain | `app.yourdomain.com` |

### Optional - KMS

| Variable | Description | Default |
|---|---|---|
| `SAMEN_KMS_ADAPTER` | KMS adapter; `file_backed` is the only production-usable one today (`aws_kms_dynamo` refuses prod boot) | `file_backed` |
| `SAMEN_KMS_KEY_DIR` | Per-subject DEK + master key directory; must be a persistent volume or all logins break | `/app/data/kms_keys` |
| `SAMEN_KMS_FILE_PATH` | Vestigial; the file-backed adapter ignores it | `/app/data/kms_store.json` |
| `SAMEN_KMS_AWS_REGION` | Region for the `aws_kms_dynamo` skeleton | `us-east-1` |
| `SAMEN_KMS_DYNAMO_TABLE` | DynamoDB table for the `aws_kms_dynamo` skeleton | `samenerp-kms-keys` |

### Optional - Billing

| Variable | Description |
|---|---|
| `STRIPE_SECRET_KEY` | Stripe secret API key |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret |

Only needed if you have wired a live billing adapter; the host boots
fail-honest with the provider unconfigured.

### Optional - Email

| Variable | Description |
|---|---|
| `SAMEN_ESP_PROVIDER` | Email provider (postmark/ses/resend) |
| `SAMEN_POSTMARK_API_KEY` | Postmark API key |
| `SAMEN_SES_REGION` | AWS SES region |
| `SAMEN_RESEND_API_KEY` | Resend API key |

### Optional - Observability

| Variable | Description |
|---|---|
| `SENTRY_DSN` | Sentry error tracking DSN (config only — not wired) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OpenTelemetry collector endpoint (config only — not wired) |

Neither is wired: `Samenerp.Monitoring` is never started and the release ships
no `:sentry` or OpenTelemetry exporter dependency, so these variables only set
unused config. Treat observability as operator-supplied.

## Health Checks

### Liveness Probe

```bash
curl http://localhost:4050/healthz
# Returns: "ok"
```

### Readiness Probe

```bash
curl http://localhost:4050/readyz
# Returns: "ready" or "not ready" with component status
```

## Database Migrations

### Run Migrations

```bash
docker-compose exec app /app/samenerp/bin/samenerp eval "Samenerp.Release.migrate()"
```

### Rollback

```bash
docker-compose exec app /app/samenerp/bin/samenerp eval "Samenerp.Release.rollback()"
```

## Monitoring

### Logs

```bash
# Docker Compose
docker-compose logs -f app

# Fly.io
fly logs

# Kubernetes
kubectl logs -f deployment/samenerp -n samenerp
```

### Metrics

`GET /metrics` is mounted by `samen_metrics_route/1`, but it self-gates to 404
until the host enables the Prometheus reporter (`metrics_egress?: true` plus a
`telemetry_metrics_prometheus` dependency). Samenerp does not set that flag and
ships no exporter, so the endpoint is **not live**; `OTEL_EXPORTER_OTLP_ENDPOINT`
does not change that.

## Troubleshooting

### Application Won't Start

1. Check database connectivity:
   ```bash
   docker-compose exec db psql -U postgres -d samenerp -c "SELECT 1"
   ```

2. Check environment variables:
   ```bash
   docker-compose exec app env | grep -E "(DATABASE_URL|SECRET_KEY_BASE|PHX_HOST)"
   ```

3. Check logs:
   ```bash
   docker-compose logs app | tail -50
   ```

### Database Connection Issues

1. Ensure PostgreSQL is running:
   ```bash
   docker-compose ps db
   ```

2. Check database URL format:
   ```
   ecto://USERNAME:PASSWORD@HOST/DATABASE
   ```

### Migration Failures

1. Check migration status:
   ```bash
   docker-compose exec app /app/samenerp/bin/samenerp eval "Ecto.Migrator.with_repo(Samenerp.Repo, fn repo -> Enum.each(Ecto.Migrator.migrations(repo), &IO.inspect/1) end)"
   ```

2. Run pending migrations:
   ```bash
   docker-compose exec app /app/samenerp/bin/samenerp eval "Samenerp.Release.migrate()"
   ```

## Security Considerations

### Production Checklist

These are operator obligations, not shipped features. Audit-on-write is live in
the kernel, but customer audit-log export, CSP/security-header middleware and
plan-based rate limiting are unwired shells today (see the README's claim set).

- [ ] Use strong, unique passwords for all services
- [ ] Enable SSL/TLS for all connections
- [ ] Configure proper firewall rules
- [ ] Set up monitoring and alerting
- [ ] Enable audit logging
- [ ] Configure backup strategy
- [ ] Review and restrict CORS settings
- [ ] Enable CSP headers
- [ ] Set up rate limiting
- [ ] Configure session timeouts

### Secrets Management

- **Never commit secrets to version control**
- Use environment variables or secrets management
- Rotate secrets regularly
- Use different secrets for development/staging/production

## Backup and Recovery

`Samenerp.Backup` is manual helpers only — no scheduler, WAL archiving or
point-in-time recovery is wired. The commands below are the operator's own
procedure; run them on a schedule and store the dumps off the database host.

### Database Backup

```bash
# Docker Compose
docker-compose exec db pg_dump -U postgres samenerp > backup.sql

# Fly.io
fly postgres connect -a samenerp-db
pg_dump -U postgres samenerp > backup.sql
```

### Database Restore

```bash
# Docker Compose
cat backup.sql | docker-compose exec -T db psql -U postgres samenerp

# Fly.io
fly postgres connect -a samenerp-db
psql -U postgres samenerp < backup.sql
```

## Scaling

### Horizontal Scaling

The shipped release is single-node. There is no `libcluster`/`dns_cluster`
dependency or discovery strategy, even though `RELEASE_NODE` is set, so adding a
second BEAM node will not form a cluster or fan PubSub out across nodes. What you
can scale today:

1. **Database connection pooling** - Configure `POOL_SIZE` (default 10) in
   `runtime.exs`
2. **Oban workers** - Scale background job processing against the shared
   Postgres-backed queue

### Vertical Scaling

- Increase CPU/memory allocation
- Tune connection pool size
- Optimize Oban queue limits

## Support

For deployment issues, check:

1. The repository README and its claim set (what is live vs. a shell)
2. GitHub Issues: https://github.com/kubeworkz/samen-erp/issues
