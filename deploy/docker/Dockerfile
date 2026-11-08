# The published image: ghcr.io/molik-labs/zmrig
#
#   docker build -f deploy/docker/Dockerfile -t zmrig:dev .
#   docker run --rm zmrig:dev version
#   docker run --rm -e WALLET=4... -e POOL=host:port zmrig:dev
#   docker run --rm zmrig:dev pool
#
# One image, two jobs. The miner is the default because it is what almost every
# container is for; `pool` runs the Ocean Pool from the same bytes, so a rig and
# the pool it mines to are never built from different commits.
#
# Unlike deploy/Dockerfile (the Render/Fly pool service, deliberately minimal and
# single-purpose) this one is the thing a person pulls, so it carries the shim
# that turns environment variables into miner flags (deploy/docker/entry.js) and
# the registry checker that answers "is a newer release published?"
# (deploy/docker/update.js).
#
# It is published by .github/workflows/image.yml with per-release labels, so
# `docker inspect` on a running container says which commit it is. An image
# without that is an image nobody can audit.

# ---------------------------------------------------------------- build ----
# node:22 rather than a bare build image: the Zig miner needs python3-free zig
# (downloaded below) and a C++ toolchain, and nothing else. The build and the
# runtime share a distro so a glibc bump cannot surprise the second stage.
FROM node:22-bookworm AS zmrig

ARG ZIG_VERSION=0.13.0
# portable = baseline x86-64, so the image runs on any host that can run Docker.
# The RandomX JIT retargets itself at runtime; what this leaves on the table is
# the instruction set of the statically compiled helpers (BLAKE2b, dataset
# init), which is why the appliance images - built for one known machine - stay
# the tuned path.
ARG ZMRIG_PORTABLE=--portable
ARG ZMRIG_JOBS=2

# build-essential, not g++: on Debian `g++` *recommends* libc6-dev rather than
# depending on it, so a compiler without C library headers builds nothing and
# reports whichever translation unit finished last. This is what broke the
# Render deploy once.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential binutils make ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Prove the toolchain before spending minutes on the engine: a missing header or
# crt object fails here, in one line, instead of 200 compiles later.
RUN printf '#include <string.h>\n#include <cstdio>\nint main(void){ std::printf("%%zu\\n", strlen("ok")); return 0; }\n' > /tmp/probe.cpp \
 && c++ -O2 /tmp/probe.cpp -o /tmp/probe \
 && /tmp/probe \
 && rm -f /tmp/probe /tmp/probe.cpp

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && ln -s /opt/zig/zig /usr/local/bin/zig \
 && zig version

WORKDIR /src

COPY src ./src
COPY zmrig ./zmrig

RUN ZIG=/usr/local/bin/zig ./zmrig/build.sh --jobs "${ZMRIG_JOBS}" ${ZMRIG_PORTABLE} --output /out \
 && /out/zmrig --version

# -------------------------------------------------------------- runtime ----
FROM node:22-bookworm-slim AS runtime

# The release this image is. Baked in by the workflow from zmrig/src/main.zig, so
# the checker inside the image can compare itself with the registry without a
# Docker socket and without guessing.
ARG ZMRIG_VERSION=0.0.0-dev
ARG ZMRIG_REVISION=unknown
ARG ZMRIG_TAG=latest
ARG ZMRIG_IMAGE=ghcr.io/molik-labs/zmrig

LABEL org.opencontainers.image.title="zmrig" \
      org.opencontainers.image.description="RandomX miner (Zig) and the Ocean Pool, from one build" \
      org.opencontainers.image.version="${ZMRIG_VERSION}" \
      org.opencontainers.image.revision="${ZMRIG_REVISION}" \
      org.opencontainers.image.source="https://github.com/MoLik-Labs/ZMRIG" \
      org.opencontainers.image.url="https://molik-labs.github.io/ZMRIG/" \
      org.opencontainers.image.documentation="https://molik-labs.github.io/ZMRIG/docs/install/docker" \
      org.opencontainers.image.licenses="GPL-3.0" \
      org.opencontainers.image.authors="@nggkhaiz" \
      org.opencontainers.image.vendor="MoLik Labs"

# libstdc++6 for the miner (the engine is C++), tini because PID 1 must reap
# zombies and forward signals: a miner that never sees SIGTERM is a miner that
# loses its last shares to a SIGKILL ten seconds later.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=zmrig /out/zmrig /usr/local/bin/zmrig

WORKDIR /app

# `pool/src/address.js` re-exports `lib/address.js`, the one decoder the miner,
# the fleet, the bot and the pool all use. It used to be required lazily - only
# when a miner logged in - so an image without `lib/` built, started and answered
# /api/config, and the first rig to connect crashed it.
COPY lib ./lib
COPY pool ./pool
COPY deploy/docker/entry.js ./deploy/docker/entry.js
COPY deploy/docker/update.js ./deploy/docker/update.js

RUN ln -s /app/deploy/docker/entry.js /usr/local/bin/zmrig-docker \
 && chmod +x /app/deploy/docker/entry.js /app/deploy/docker/update.js \
 && chmod 0755 /usr/local/bin/zmrig \
 && mkdir -p /app/pool/data

# The pool job writes here. Created as root, then handed to the user the process
# runs as, so a bind-mounted volume is not read-only behind its back.
RUN chown -R node:node /app/pool/data

ENV ZMRIG_VERSION="${ZMRIG_VERSION}" \
    ZMRIG_REVISION="${ZMRIG_REVISION}" \
    ZMRIG_TAG="${ZMRIG_TAG}" \
    ZMRIG_IMAGE="${ZMRIG_IMAGE}" \
    NODE_ENV=production

# The pool job's defaults: the same ones deploy/Dockerfile sets, so `pool` behaves
# identically whether it came from this image or from the Render build.
ENV PORT=3333 \
    HTTP_PORT=8080 \
    BIND=0.0.0.0 \
    STATE_FILE=/app/pool/data/state.json \
    AUDIT_FILE=/app/pool/data/audit.jsonl \
    VERIFIER_BINARY=/usr/local/bin/zmrig

USER node

EXPOSE 3333 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/zmrig-docker"]
CMD ["mine"]
