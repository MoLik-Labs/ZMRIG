# Ocean Pool image: the pool plus the zmrig verifier it needs to check shares.
#
#   docker build -f deploy/Dockerfile -t ocean-pool .
#   docker run --rm -p 3333:3333 -p 8080:8080 \
#     -e DAEMON=http://node.example:18081 \
#     -v pool-data:/app/pool/data ocean-pool
#
# Stage 1 builds zmrig from the sources in this repository, so the verifier and
# the miner are always the same code. Stage 2 has no compiler in it.

FROM node:20-bookworm AS zmrig

ARG ZIG_VERSION=0.13.0

# build-essential, not g++: on Debian, `g++` *recommends* libc6-dev rather than
# depending on it, so `--no-install-recommends g++` gives you a compiler with no
# C library headers. Every translation unit then dies on `#include <string.h>`,
# the build reports one of them (whichever finished last), and the message names
# a source file that is perfectly fine. This is what broke the Render deploy.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential binutils make ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Prove the toolchain before spending two minutes on the engine: a missing
# header or crt object fails here, in one line, instead of 200 compiles later.
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

# build.sh compiles the C++ RandomX engine from src/ and links it with the Zig
# miner from zmrig/. `--portable` keeps the binary runnable on any x86-64 host,
# not just the machine that built the image.
COPY src ./src
COPY zmrig ./zmrig

RUN ZIG=/usr/local/bin/zig ./zmrig/build.sh --jobs 2 --portable --output /out \
 && /out/zmrig --version


FROM node:20-bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=zmrig /out/zmrig /usr/local/bin/zmrig

WORKDIR /app

# `pool/src/address.js` is a two-line re-export of `lib/address.js`, the one
# decoder the miner, the fleet, the bot and the pool all use. It used to be
# required lazily - only when a miner logged in - so an image without `lib/`
# built, started, and answered /api/config perfectly; the first rig to connect
# was what crashed it. The pool's config check now decodes its own fee address
# at startup, which is how this was found. Copy the shared library.
COPY lib ./lib

COPY pool ./pool

RUN mkdir -p /app/pool/data \
 && chown -R node:node /app/pool/data \
 && chmod 0755 /usr/local/bin/zmrig

USER node

ENV NODE_ENV=production \
    PORT=3333 \
    HTTP_PORT=8080 \
    BIND=0.0.0.0 \
    STATE_FILE=/app/pool/data/state.json \
    AUDIT_FILE=/app/pool/data/audit.jsonl \
    VERIFIER_BINARY=/usr/local/bin/zmrig

EXPOSE 3333 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.HTTP_PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "node", "pool/src/index.js", "--config", "pool/config.json"]
