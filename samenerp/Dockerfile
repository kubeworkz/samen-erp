# Multi-stage Dockerfile for Samenerp
# Stage 1: Build
FROM hexpm/elixir:1.20.2-erlang-27.2.4-alpine-3.24.1 AS build

# Install build dependencies
RUN apk add --no-cache build-base git

# Set build ENV
ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set workdir
WORKDIR /app

# Install mix dependencies
COPY mix.exs mix.lock ./
COPY samen_core/mix.exs samen_core/mix.lock ./samen_core/
COPY samen_web/mix.exs samen_web/mix.lock ./samen_web/
COPY samenerp/mix.exs samenerp/mix.lock ./samenerp/

# Fetch dependencies
RUN cd samen_core && mix deps.get --only prod
RUN cd samen_web && mix deps.get --only prod
RUN cd samenerp && mix deps.get --only prod

# Copy umbrella structure
COPY samen_core ./samen_core
COPY samen_web ./samen_web
COPY samenerp ./samenerp

# Compile dependencies
RUN cd samen_core && MIX_ENV=prod mix compile
RUN cd samen_web && MIX_ENV=prod mix compile
RUN cd samenerp && MIX_ENV=prod mix compile

# Build the release
RUN cd samenerp && MIX_ENV=prod mix release samenerp

# Stage 2: Runtime
FROM alpine:3.24.1 AS runtime

# Install runtime dependencies
RUN apk add --no-cache libstdc++ openssl libncurses5 curl

# Set workdir
WORKDIR /app

# Run as non-root user
RUN addgroup --system -g 1000 app && \
    adduser --system -g app --uid 1000 --shell /bin/sh app && \
    mkdir -p /app && chown app:app /app

# Copy the release from the build stage
COPY --from=build --chown=app:app /app/samenerp/_build/prod/rel/samenerp ./samenerp

# Copy the priv directory for migrations
COPY --from=build --chown=app:app /app/samenerp/priv ./samenerp/priv
COPY --from=build --chown=app:app /app/samen_core/priv ./samen_core/priv
COPY --from=build --chown=app:app /app/samen_web/priv ./samen_web/priv

# Create a script to run migrations and start the app
RUN chown -R app:app /app

USER app

# Expose the port
EXPOSE 4050

# Set environment variables
ENV PORT=4050
ENV PHX_SERVER=true

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:4050/healthz || exit 1

# Run the release
ENTRYPOINT ["/app/samenerp/bin/samenerp"]
CMD ["start"]
