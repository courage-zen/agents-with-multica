# Stage 1: Download multica
FROM alpine:3.20 AS multica-downloader

ARG MULTICA_VERSION=0.3.2
ARG TARGETARCH

RUN apk add --no-cache curl tar

RUN mkdir -p /out

ARG ARCH=${TARGETARCH}
RUN case "${ARCH}" in \
      amd64) ARCH_MAPPED="amd64" ;; \
      arm64) ARCH_MAPPED="arm64" ;; \
      *)     ARCH_MAPPED="amd64" ;; \
    esac \
    && curl -fsSL "https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}/multica-cli-${MULTICA_VERSION}-linux-${ARCH_MAPPED}.tar.gz" \
       -o /tmp/multica.tar.gz \
    && tar -xzf /tmp/multica.tar.gz -C /out multica \
    && chmod +x /out/multica \
    && rm /tmp/multica.tar.gz

# Stage 2: Download opencode
FROM alpine:3.20 AS opencode-downloader

ARG OPENCODE_VERSION=v0.0.55
ARG TARGETARCH

RUN apk add --no-cache curl tar

RUN mkdir -p /out

ARG ARCH=${TARGETARCH}
RUN case "${ARCH}" in \
      amd64) ARCH_MAPPED="x86_64" ;; \
      arm64) ARCH_MAPPED="arm64" ;; \
      *)     ARCH_MAPPED="x86_64" ;; \
    esac \
    && curl -fsSL "https://github.com/opencode-ai/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${ARCH_MAPPED}.tar.gz" \
       -o /tmp/opencode.tar.gz \
    && tar -xzf /tmp/opencode.tar.gz -C /out opencode \
    && chmod +x /out/opencode \
    && rm /tmp/opencode.tar.gz

# Stage 3: Final image
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-yaml git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=multica-downloader /out/multica /usr/local/bin/multica
COPY --from=opencode-downloader /out/opencode /usr/local/bin/opencode

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]