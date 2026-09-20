# Multi-stage Dockerfile for Samenerp
# Monorepo build: samen_core → samen_web → samenerp
# Build context is the REPO ROOT (docker compose sets context: ..)

# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM hexpm/elixir:1.20.2-erlang-27.2.4-alpine-3.24.1 AS build

RUN apk add --no-cache build-base git

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy all three packages
COPY samen_core/ ./samen_core/
COPY samen_web/ ./samen_web/
COPY samenerp/ ./samenerp/

# Fetch + compile in dependency order
#   samen_core has no local deps — compile it first
#   samen_web depends on samen_core (path dep)
#   samenerp depends on both (path deps)
RUN cd samen_core && mix deps.get --only prod && mix compile
RUN cd samen_web && mix deps.get --only prod && mix compile
RUN cd samenerp && mix deps.get --only prod && mix compile

# Build the OTP release for samenerp
RUN cd samenerp && mix release samenerp

# ─── Stage 2: Runtime ───────────────────────────────────────────────────────
FROM alpine:3.24.1 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses curl

RUN addgroup --system -g 1000 app && \
    adduser --system -g app --uid 1000 --shell /bin/sh app

WORKDIR /app

# Copy release
COPY --from=build --chown=app:app /app/samenerp/_build/prod/rel/samenerp ./samenerp

# Copy priv dirs (migrations, static assets)
COPY --from=build --chown=app:app /app/samen_core/priv ./samen_core/priv
COPY --from=build --chown=app:app /app/samen_web/priv ./samen_web/priv
COPY --from=build --chown=app:app /app/samenerp/priv ./samenerp/priv

USER app

EXPOSE 4050

ENV PORT=4050
ENV PHX_SERVER=true

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:4050/healthz || exit 1

ENTRYPOINT ["/app/samenerp/bin/samenerp"]
CMD ["start"]
