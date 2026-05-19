# Stage 1: Download cc-proxy
FROM alpine:3.20 AS cc-proxy-downloader

ARG CC_PROXY_VERSION="0.1.0"
ARG TARGETARCH

RUN mkdir -p /out \
    && apk add --no-cache curl \
    && curl -fsSL \
      "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" \
      -o /out/cc-proxy \
    && chmod +x /out/cc-proxy

# Stage 2: Download multica
FROM alpine:3.20 AS multica-downloader

ARG MULTICA_VERSION="0.3.2"
ARG TARGETARCH

RUN mkdir -p /out \
    && apk add --no-cache curl tar \
    && case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        arm64) ARCH="arm64" ;; \
        *) ARCH="amd64" ;; \
    esac \
    && curl -fsSL \
      "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/multica.tar.gz \
    && tar -xzf /tmp/multica.tar.gz -C /out multica \
    && chmod +x /out/multica \
    && rm -f /tmp/multica.tar.gz

# Stage 3: Final image
FROM node:24-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-yaml git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION="2.1.100"

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader   /out/multica  /usr/local/bin/multica

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy

ENTRYPOINT ["/entrypoint.sh"]
