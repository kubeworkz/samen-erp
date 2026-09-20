# Multi-stage Dockerfile for Samenerp
# Stage 1: Build
FROM hexpm/elixir:1.20.2-erlang-27.2-ubuntu-noble-20240617 AS build

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

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
FROM ubuntu:noble-20240617 AS runtime

# Install runtime dependencies
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app

# Run as non-root user
RUN groupadd --system -g 1000 app && \
    useradd --system -g app --uid 1000 --shell /bin/sh app && \
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
