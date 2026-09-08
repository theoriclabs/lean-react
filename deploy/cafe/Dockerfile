# Build from the allowlisted context produced by scripts/package-cafe.mjs.
FROM node:24-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl zstd git build-essential libssl-dev libgmp-dev libcurl4-openssl-dev
WORKDIR /opt
RUN curl -fL --retry 3 https://github.com/leanprover/lean4/releases/download/v4.33.0/lean-4.33.0-linux.tar.zst -o lean.tar.zst \
    && echo '4b3fb03c29a1e0a253fb1d11f9bae3725f19a0dc6fc09b3ea16d2c9df3349e2c  lean.tar.zst' | sha256sum -c - \
    && tar --zstd -xf lean.tar.zst
ENV PATH="/opt/lean-4.33.0-linux/bin:${PATH}"
COPY leandb_v2 /src/leandb_v2
COPY leanhttp /src/leanhttp
COPY leansqlite /src/leansqlite
COPY leanreact /src/leanreact
WORKDIR /src/leanreact
RUN npm ci && npm run build:cafe
WORKDIR /src/leanreact/adapters/native
RUN lake -Kleansqlite=/src/leansqlite -Kopenssl=/usr build leanapp_cafe leanapp_crypto_checks \
    && .lake/build/bin/leanapp_crypto_checks

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3 libgmp10 libcurl4 ca-certificates tini
WORKDIR /app
COPY --from=build /src/leanreact/LICENSE /app/LICENSE
COPY --from=build /src/leandb_v2/LICENSE /app/licenses/LeanDb-LICENSE
COPY --from=build /src/leanhttp/LICENSE /app/licenses/LeanHttp-LICENSE
COPY --from=build /src/leansqlite/LICENSE /app/licenses/SQLite-LICENSE
COPY --from=build /src/leanreact/adapters/native/.lake/build/bin/leanapp_cafe /app/bin/leanapp_cafe
COPY --from=build /src/leanreact/examples/dist-cafe /app/examples/dist-cafe
COPY --from=build /src/leanreact/scripts/serve-cafe.mjs /app/scripts/serve-cafe.mjs
COPY SOURCE-MANIFEST.json /app/SOURCE-MANIFEST.json
ENV NODE_ENV=production PORT=8080 LEANAPP_CAFE_BINARY=/app/bin/leanapp_cafe LEANAPP_BACKEND_PORT=4181
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "/app/scripts/serve-cafe.mjs"]
