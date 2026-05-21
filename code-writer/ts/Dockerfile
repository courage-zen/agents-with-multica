ARG BASE_IMAGE

# Stage 1: npm offline cache — pre-download common TS development dependencies
FROM node:22-bookworm-slim AS npm-cache
WORKDIR /tmp/cache
RUN printf '{"name":"modcache","private":true,"dependencies":{"tsx":"^4.19.0","typescript":"^5.8.0","@types/node":"^22.0.0","commander":"^14.0.0","inquirer":"^12.0.0","ora":"^8.0.0","chalk":"^5.0.0","cli-table3":"^0.6.0","pg":"^8.16.0","drizzle-orm":"^0.44.0","ioredis":"^5.6.0","zod":"^3.24.0","yaml":"^2.7.0","vitest":"^3.2.0"}}\n' > package.json && npm install --prefer-offline

# Stage 2: final image — layered on top of the npm base image
FROM ${BASE_IMAGE}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make jq postgresql-client redis-tools vim-tiny && \
    rm -rf /var/lib/apt/lists/*
COPY --from=npm-cache /tmp/cache/node_modules/ /opt/npm-precache/node_modules/
COPY --from=npm-cache /root/.npm/_cacache/     /home/agent/.npm/_cacache/
RUN npm install -g tsx typescript && \
    chown -R agent:agent /home/agent/.npm /opt/npm-precache