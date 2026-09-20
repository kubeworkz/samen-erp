# Samenerp Deployment Guide

This guide covers deploying Samenerp as an enterprise SaaS service.

## Prerequisites

- Docker and Docker Compose installed
- A domain name (for production)
- Stripe account (for billing)
- HuggingFace account (for AI features)

## Quick Start (Local Development)

### 1. Clone and Setup

```bash
git clone https://github.com/kubeworkz/samen-erp.git
cd samen-erp/samenerp
```

### 2. Create Environment File

```bash
cp .env.example .env
# Edit .env with your settings
```

### 3. Start Services

```bash
docker-compose up -d
```

### 4. Run Migrations

```bash
docker-compose exec app bin/samenerp eval "Samenerp.Release.migrate()"
```

### 5. Seed Database

```bash
docker-compose exec app bin/samenerp eval "Samenerp.Release.seed()"
```

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
fly launch
```

#### 3. Set Secrets

```bash
fly secrets set \
  DATABASE_URL="ecto://postgres:PASSWORD@HOST/samenerp" \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  PHX_HOST="your-domain.com" \
  STRIPE_SECRET_KEY="sk_live_..." \
  STRIPE_WEBHOOK_SECRET="whsec_..." \
  SAMEN_KMS_ADAPTER="aws_kms_dynamo" \
  SAMEN_KMS_AWS_REGION="us-east-1" \
  SAMEN_KMS_AWS_ACCESS_KEY_ID="..." \
  SAMEN_KMS_AWS_SECRET_ACCESS_KEY="..."
```

#### 4. Deploy

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

```bash
kubectl apply -f k8s/
```

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
| `SAMEN_KMS_ADAPTER` | KMS adapter | `file_backed` |
| `SAMEN_KMS_FILE_PATH` | File path for file-backed KMS | `/app/data/kms_store.json` |
| `SAMEN_KMS_AWS_REGION` | AWS region for KMS | `us-east-1` |
| `SAMEN_KMS_AWS_ACCESS_KEY_ID` | AWS access key ID | - |
| `SAMEN_KMS_AWS_SECRET_ACCESS_KEY` | AWS secret access key | - |

### Optional - Billing

| Variable | Description |
|---|---|
| `STRIPE_SECRET_KEY` | Stripe secret API key |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret |

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
| `SENTRY_DSN` | Sentry error tracking DSN |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OpenTelemetry collector endpoint |

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
docker-compose exec app bin/samenerp eval "Samenerp.Release.migrate()"
```

### Rollback

```bash
docker-compose exec app bin/samenerp eval "Samenerp.Release.rollback()"
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

If you've configured OpenTelemetry:

```bash
# Prometheus scrape endpoint
curl http://localhost:4050/metrics
```

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
   docker-compose exec app bin/samenerp eval "Ecto.Migrator.with_repo(Samenerp.Repo, &Ecto.Migrator.migrations_status/1)"
   ```

2. Run pending migrations:
   ```bash
   docker-compose exec app bin/samenerp eval "Samenerp.Release.migrate()"
   ```

## Security Considerations

### Production Checklist

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

Samenerp supports horizontal scaling through:

1. **Multiple Elixir nodes** - Use libcluster for node discovery
2. **Database connection pooling** - Configure pool size in runtime.exs
3. **Oban workers** - Scale background job processing

### Vertical Scaling

- Increase CPU/memory allocation
- Tune connection pool size
- Optimize Oban queue limits

## Support

For deployment issues, check:

1. [Deployment Guide](docs/deployment-guide.md)
2. [Troubleshooting Guide](docs/troubleshooting.md)
3. GitHub Issues: https://github.com/kubeworkz/samen-erp/issues
