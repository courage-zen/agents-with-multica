# Stage 1: download cc-proxy
FROM alpine:3.20 AS cc-proxy-downloader
ARG CC_PROXY_VERSION
ARG TARGETARCH
RUN mkdir -p /out && \
    apk add --no-cache curl && \
    curl -fsSL -o /out/cc-proxy "https://github.com/courage-zen/cc-proxy/releases/download/v${CC_PROXY_VERSION}/cc-proxy-${TARGETARCH}" && \
    chmod +x /out/cc-proxy

# Stage 2: download multica
FROM alpine:3.20 AS multica-downloader
ARG MULTICA_VERSION
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

# Stage 3: Install Claude Code via npm
FROM node:22-bookworm-slim AS claude-install
ARG CLAUDE_CODE_VERSION
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# Stage 4: final image
FROM node:22-bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates curl sudo openssh-client && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD: /usr/local/bin/cc-proxy start -c /home/agent/.cc-proxy" >> /etc/sudoers.d/agent && \
    chmod 0440 /etc/sudoers.d/agent
COPY --from=cc-proxy-downloader /out/cc-proxy /usr/local/bin/cc-proxy
COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=claude-install /usr/local/lib/node_modules/@anthropic-ai/claude-code \
                          /usr/local/lib/node_modules/@anthropic-ai/claude-code
RUN ln -sf /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js /usr/local/bin/claude && \
    ln -sf /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js /usr/local/bin/claude-code
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    mkdir -p /home/agent/wiki /home/agent/.claude/skills && \
    git config --system credential.helper store && \
    git config --system user.name agent && \
    git config --system user.email agent@container && \
    chown -R agent:agent /home/agent
WORKDIR /home/agent
ENTRYPOINT ["/entrypoint.sh"]
