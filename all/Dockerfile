# Stage 1: download cc-proxy
FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION="0.1.0"
ARG TARGETARCH
RUN mkdir -p /out && \
    apk add --no-cache curl && \
    curl -fsSL -o /out/cc-proxy "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" && \
    chmod +x /out/cc-proxy

# Stage 2: download multica
FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION="0.3.2"
ARG TARGETARCH
ARG ARCH=${TARGETARCH}
RUN mkdir -p /out && \
    apk add --no-cache curl tar && \
    case "${ARCH}" in \
    amd64) ARCH="amd64" ;; \
    arm64) ARCH="arm64" ;; \
    *)     ARCH="amd64" ;; \
    esac && \
    curl -L -o /out/multica.tar.gz "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH}.tar.gz" && \
    tar -xzf /out/multica.tar.gz -C /out && \
    chmod +x /out/multica && \
    rm /out/multica.tar.gz

# Stage 4: final image
FROM node:24-bookworm-slim
ARG CLAUDE_CODE_VERSION="2.1.100"
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates curl sudo && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD: /usr/local/bin/cc-proxy start -c /home/agent/.cc-proxy" >> /etc/sudoers.d/agent && \
    chmod 0440 /etc/sudoers.d/agent && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    chown -R agent:agent /home/agent
ENV CC_SWITCH_CONFIG_DIR=/etc/cc-proxy
ENTRYPOINT ["/entrypoint.sh"]