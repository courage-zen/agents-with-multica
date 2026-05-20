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

# Stage 3: download claude-code native binary
FROM alpine:3.20 AS claude-downloader
ARG CLAUDE_CODE_VERSION="2.1.145"
ARG TARGETARCH
RUN mkdir -p /out && \
    apk add --no-cache curl && \
    case "${TARGETARCH}" in \
    amd64) PLATFORM="linux-x64" ;; \
    arm64) PLATFORM="linux-arm64" ;; \
    *)     PLATFORM="linux-x64" ;; \
    esac && \
    curl -fsSL -o /out/claude "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}/${PLATFORM}/claude" && \
    chmod +x /out/claude

# Stage 4: final image
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates curl sudo && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD: /usr/local/bin/cc-proxy start -c /home/agent/.cc-proxy" >> /etc/sudoers.d/agent && \
    chmod 0440 /etc/sudoers.d/agent
COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=claude-downloader /out/claude /usr/local/bin/claude
RUN /usr/local/bin/claude install --prefix /usr/local
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    chown -R agent:agent /home/agent
ENTRYPOINT ["/entrypoint.sh"]