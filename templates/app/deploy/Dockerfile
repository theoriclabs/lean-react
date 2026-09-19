# Build from the snapshot produced by `npm run package`: the application plus every pinned
# dependency's source, so the container never reaches the network for Lean packages.
FROM node:24-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl zstd git build-essential libssl-dev libgmp-dev libcurl4-openssl-dev
WORKDIR /opt
RUN curl -fL --retry 3 https://github.com/leanprover/lean4/releases/download/v4.33.0/lean-4.33.0-linux.tar.zst -o lean.tar.zst \
    && echo '4b3fb03c29a1e0a253fb1d11f9bae3725f19a0dc6fc09b3ea16d2c9df3349e2c  lean.tar.zst' | sha256sum -c - \
    && tar --zstd -xf lean.tar.zst
ENV PATH="/opt/lean-4.33.0-linux/bin:${PATH}"
COPY leanreact /src/leanreact
COPY leandb /src/leandb
COPY leanhttp /src/leanhttp
COPY leanws /src/leanws
COPY leansqlite /src/leansqlite
COPY app /src/app
ENV LEANAPP_LEANREACT_SOURCE=/src/leanreact LEANAPP_LEANDB_SOURCE=/src/leandb LEANAPP_LEANHTTP_SOURCE=/src/leanhttp \
    LEANAPP_LEANWS_SOURCE=/src/leanws LEANAPP_LEANSQLITE_SOURCE=/src/leansqlite LEANAPP_OPENSSL_PREFIX=/usr
WORKDIR /src/app
RUN npm install --no-audit --no-fund && npm run build
WORKDIR /src/app/native
RUN lake -Kleanreact=/src/leanreact -Kleanapp_native=/src/leanreact/adapters/native -Kleandb=/src/leandb -Kleanhttp=/src/leanhttp \
      -Kleanws=/src/leanws -Kleansqlite=/src/leansqlite -Kopenssl=/usr build {{name}}_server {{name}}_checks \
    && .lake/build/bin/{{name}}_checks

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3 libgmp10 libcurl4 ca-certificates tini
WORKDIR /app
COPY --from=build /src/leanreact/LICENSE /app/licenses/LeanReact-LICENSE
COPY --from=build /src/leandb/LICENSE /app/licenses/LeanDb-LICENSE
COPY --from=build /src/leanhttp/LICENSE /app/licenses/LeanHttp-LICENSE
COPY --from=build /src/leanws/LICENSE /app/licenses/LeanWs-LICENSE
COPY --from=build /src/leansqlite/LICENSE /app/licenses/SQLite-LICENSE
COPY --from=build /src/leanreact/engine /app/leanreact/engine
COPY --from=build /src/app/native/.lake/build/bin/{{name}}_server /app/bin/{{name}}_server
COPY --from=build /src/app/dist /app/dist
COPY --from=build /src/app/gateway /app/gateway
COPY SOURCE-MANIFEST.json /app/SOURCE-MANIFEST.json
ENV NODE_ENV=production PORT=8080 LEANAPP_BINARY=/app/bin/{{name}}_server LEANAPP_BACKEND_PORT=4271 LEANAPP_LEANREACT_SOURCE=/app/leanreact
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "/app/gateway/serve.mjs"]
