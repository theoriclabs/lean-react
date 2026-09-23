# Build from the allowlisted context produced by scripts/package-cafe.mjs.
FROM node:24-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl zstd git build-essential libssl-dev libgmp-dev libcurl4-openssl-dev
WORKDIR /opt
RUN curl -fL --retry 3 https://github.com/leanprover/lean4/releases/download/v4.33.0/lean-4.33.0-linux.tar.zst -o lean.tar.zst \
    && echo '4b3fb03c29a1e0a253fb1d11f9bae3725f19a0dc6fc09b3ea16d2c9df3349e2c  lean.tar.zst' | sha256sum -c - \
    && tar --zstd -xf lean.tar.zst
ENV PATH="/opt/lean-4.33.0-linux/bin:${PATH}"
COPY leandb /src/leandb
COPY leanhttp /src/leanhttp
COPY leanws /src/leanws
COPY leansqlite /src/leansqlite
COPY leanreact /src/leanreact
WORKDIR /src/leanreact
RUN npm ci && npm run build:cafe
WORKDIR /src/leanreact/adapters/native
# The snapshot ships every dependency's source; the overrides keep Lake off the network.
RUN lake -Kleandb=/src/leandb -Kleanhttp=/src/leanhttp -Kleanws=/src/leanws -Kleansqlite=/src/leansqlite -Kopenssl=/usr update \
    && lake -Kleandb=/src/leandb -Kleanhttp=/src/leanhttp -Kleanws=/src/leanws -Kleansqlite=/src/leansqlite -Kopenssl=/usr build leanapp_cafe leanapp_crypto_checks \
    && .lake/build/bin/leanapp_crypto_checks

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3 libgmp10 libcurl4 ca-certificates tini
WORKDIR /app
COPY --from=build /src/leanreact/LICENSE /app/LICENSE
COPY --from=build /src/leandb/LICENSE /app/licenses/LeanDb-LICENSE
COPY --from=build /src/leanhttp/LICENSE /app/licenses/LeanHttp-LICENSE
COPY --from=build /src/leanws/LICENSE /app/licenses/LeanWs-LICENSE
COPY --from=build /src/leansqlite/LICENSE /app/licenses/SQLite-LICENSE
COPY --from=build /src/leanreact/adapters/native/.lake/build/bin/leanapp_cafe /app/bin/leanapp_cafe
COPY --from=build /src/leanreact/examples/dist-cafe /app/examples/dist-cafe
COPY --from=build /src/leanreact/scripts/serve-cafe.mjs /app/scripts/serve-cafe.mjs
COPY --from=build /src/leanreact/engine/gateway /app/engine/gateway
COPY SOURCE-MANIFEST.json /app/SOURCE-MANIFEST.json
ENV NODE_ENV=production PORT=8080 LEANAPP_CAFE_BINARY=/app/bin/leanapp_cafe LEANAPP_BACKEND_PORT=4181
# Start as root only to hand the database directory (often a root-owned volume) to `node`,
# then drop privileges; the gateway and the Lean backend never run as root.
RUN printf '%s\n' '#!/bin/sh' \
      'if [ "$(id -u)" = 0 ]; then' \
      '  dir="${RAILWAY_VOLUME_MOUNT_PATH:-$(dirname "${LEANAPP_DB_PATH:-/data/db}")}"' \
      '  if [ -d "$dir" ] && ! chown -R node:node "$dir"; then' \
      '    echo "entrypoint: cannot chown $dir; staying root" >&2; exec "$@"' \
      '  fi' \
      '  exec setpriv --reuid=node --regid=node --init-groups "$@"' \
      'fi' \
      'exec "$@"' > /usr/local/bin/leanapp-entrypoint && chmod 755 /usr/local/bin/leanapp-entrypoint
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/leanapp-entrypoint"]
CMD ["node", "/app/scripts/serve-cafe.mjs"]
