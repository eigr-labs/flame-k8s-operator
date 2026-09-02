FROM elixir:1.18-otp-27 AS builder

ENV MIX_ENV=prod

WORKDIR /app/examples/flame_example

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      git \
      build-essential \
      ca-certificates \
      zstd \
      pkg-config \
      libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY examples/flame_example/mix.exs examples/flame_example/mix.lock ./
COPY examples/flame_example/config ./config
COPY examples/flame_example/lib ./lib
COPY flame_k8s /app/flame_k8s

RUN mix local.rebar --force \
    && mix local.hex --force \
    && mix deps.get \
    && mix deps.compile

ENV RELEASE_DISTRIBUTION="name"

# Overriden at runtime
ENV POD_IP="127.0.0.1"

# This will be the basename of node
ENV RELEASE_NAME="flame_example"

# This will be the full nodename
ENV RELEASE_NODE="${RELEASE_NAME}@${POD_IP}"

RUN test -d rel || mix release.init

RUN mix release flame_example

# ---- Application Stage ----
FROM debian:bookworm-slim

RUN apt-get update \
        && apt-get install -y --no-install-recommends \
            ca-certificates \
            zstd \
            libstdc++6 \
            openssl \
            libncurses6 \
            libtinfo6 \
        && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV=prod
ENV HOME=/app

COPY --from=builder --chown=nobody:root /app/examples/flame_example/_build/${MIX_ENV}/rel/bakeware/ ./

RUN mkdir -p /app/.cache/bakeware/ && chmod 777 /app/.cache/bakeware/

USER nobody

ENTRYPOINT [ "./flame_example", "start" ] 