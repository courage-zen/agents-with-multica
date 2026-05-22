ARG BASE_IMAGE

# Stage 1: Go dev tools — sqlc, golangci-lint, goose
FROM golang:1.26-bookworm AS go-tools
ARG SQLC_VERSION
ARG GOLANGCI_LINT_VERSION
ARG GOOSE_VERSION
RUN go install github.com/sqlc-dev/sqlc/cmd/sqlc@v${SQLC_VERSION} && \
    go install github.com/golangci/golangci-lint/cmd/golangci-lint@v${GOLANGCI_LINT_VERSION} && \
    go install github.com/pressly/goose/v3/cmd/goose@v${GOOSE_VERSION}

# Stage 2: Pre-cache Go modules (CLI + DB + Redis 常用依赖)
# 在有网环境构建时把常用包下载到 module cache，运行时 GOPROXY=off 禁止网络访问，
# 所有依赖只能从这个预缓存的 cache 中获取。
FROM golang:1.26-bookworm AS go-module-cache

ENV GOPATH=/gocache
ENV GOPROXY=https://goproxy.cn,direct

WORKDIR /tmp/modcache
RUN go mod init modcache && \
    # --- CLI 框架 ---
    go get github.com/spf13/cobra@latest && \
    go get github.com/spf13/pflag@latest && \
    # --- PostgreSQL ---
    go get github.com/jackc/pgx/v5@latest && \
    go get github.com/jackc/pgx/v5/pgtype@latest && \
    go get github.com/jackc/pgx/v5/stdlib@latest && \
    # --- Redis (集群模式) ---
    go get github.com/redis/go-redis/v9@latest && \
    # --- 配置 ---
    go get github.com/spf13/viper@latest && \
    # --- 日志 ---
    go get go.uber.org/zap@latest && \
    # --- 输出格式化 ---
    go get github.com/charmbracelet/lipgloss@latest && \
    # --- 测试 ---
    go get github.com/stretchr/testify@latest && \
    # --- 加密 / UUID ---
    go get github.com/google/uuid@latest && \
    go get golang.org/x/crypto@latest && \
    # --- YAML / JSON ---
    go get gopkg.in/yaml.v3@latest && \
    # --- Context / 并发 ---
    go get golang.org/x/sync@latest && \
    # --- HTTP client (CLI 调 API 时可能需要) ---
    go get golang.org/x/net@latest && \
    # --- 让 go mod tidy 实际下载所有依赖 ---
    go mod tidy

# Stage 3: final image — layered on top of the npm base image
FROM ${BASE_IMAGE}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make jq postgresql-client redis-tools vim-tiny gcc && \
    rm -rf /var/lib/apt/lists/*

# Go toolchain
COPY --from=go-tools /usr/local/go/ /usr/local/go/
COPY --from=go-tools /go/bin/sqlc          /usr/local/bin/sqlc
COPY --from=go-tools /go/bin/golangci-lint /usr/local/bin/golangci-lint
COPY --from=go-tools /go/bin/goose         /usr/local/bin/goose

# 预缓存的 Go module cache（构建时下载，运行时只读此缓存）
COPY --from=go-module-cache /gocache/pkg/mod/cache/ /home/agent/go/pkg/mod/cache/
COPY --from=go-module-cache /gocache/pkg/mod/sumdb/  /home/agent/go/pkg/mod/sumdb/

ENV GOPATH=/home/agent/go
ENV GOROOT=/usr/local/go
ENV PATH="${GOROOT}/bin:${GOPATH}/bin:${PATH}"
# 运行时禁止网络访问 Go proxy —— 只用预缓存的模块
# 如果需要新增依赖，在有网机器上重新构建镜像
ENV GOPROXY=off
ENV GONOSUMCHECK=*
ENV GONOSUMDB=*
ENV GOFLAGS=-mod=mod
RUN chown -R agent:agent /home/agent/go
