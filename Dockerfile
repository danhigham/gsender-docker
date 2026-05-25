# syntax=docker/dockerfile:1

# =============================================================================
# Build stage
# -----------------------------------------------------------------------------
# gSender's headless server is plain Node (no Electron / no X needed). We build
# it from upstream source. Native modules (serialport, usb) need a C/C++
# toolchain + libudev headers to compile against this Node version.
# =============================================================================
FROM node:24-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git python3 build-essential libudev-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Which gSender version to build. CI overrides this with the upstream release
# tag (e.g. --build-arg GSENDER_REF=v1.6.1).
ARG GSENDER_REF=v1.6.1

# The web (vite) build is memory hungry.
ENV NODE_OPTIONS=--max-old-space-size=8192

WORKDIR /app
RUN git clone --depth 1 --branch "${GSENDER_REF}" \
        https://github.com/Sienci-Labs/gsender.git . \
    && rm -rf .git

# Mirrors upstream's own production build sequence, minus the Electron/.deb
# packaging:
#   1. root build tooling     2. sync version metadata into src/
#   3. server runtime deps (compiles native modules against Node — note we do
#      NOT pass --ignore-scripts, unlike the Electron build, because we run on
#      Node and need the bindings built for Node's ABI, not Electron's)
#   4. prebuild   5. build server + web UI  ->  dist/gsender/
RUN yarn install
RUN npm run package-sync
RUN yarn --cwd src install --production --non-interactive
RUN npm run prebuild-prod
RUN npm run build-prod

# The runtime only needs the compiled server (dist/gsender), the launcher
# (bin/) and the *server's* production dependencies — which were installed into
# src/node_modules. The bundled server resolves its externals from the nearest
# ancestor node_modules, so we ship src/node_modules as /app/node_modules and
# leave behind the ~1GB of build/frontend tooling in the root node_modules.
#
# The server statically imports `electron` (for an optional userData path) but
# guards every actual use behind a runtime check, and we never launch Electron.
# electron is a build-only dep so it isn't in src/node_modules; drop in an empty
# stub so `require('electron')` resolves to {} instead of throwing.
RUN mkdir -p src/node_modules/electron \
    && echo 'module.exports = {};' > src/node_modules/electron/index.js \
    && printf '{"name":"electron","version":"0.0.0-stub","main":"index.js"}\n' \
         > src/node_modules/electron/package.json

# =============================================================================
# Runtime stage
# =============================================================================
FROM node:24-bookworm-slim AS runtime

# libudev1 is required at runtime by the serialport / usb native modules.
# tini gives us proper PID 1 signal handling (clean Ctrl-C / docker stop).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libudev1 ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/dist             ./dist
COPY --from=builder /app/bin              ./bin
COPY --from=builder /app/package.json     ./package.json
COPY --from=builder /app/src/node_modules ./node_modules
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production

# gSender keeps its config in ~/.cncrc. We relocate it onto /data so settings,
# macros and uploaded G-code survive container restarts and image upgrades.
VOLUME ["/data"]
EXPOSE 8080

# tini = clean PID 1 signal handling; entrypoint pre-creates /data dirs.
# Headless server, reachable on the LAN. Override CMD in compose to tweak flags
# (e.g. add `--controller grblHal`). The CNC serial device is mapped into the
# container at run time via `--device`.
ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "bin/gsender", "-H", "0.0.0.0", "-p", "8080", "--remote", \
     "-c", "/data/.cncrc", "-w", "/data/gcode"]
