ARG BASE_IMAGE
ARG UV_VERSION

# Stage 1: Python + uv toolchain
FROM python:3.12-slim AS python-toolchain
ARG UV_VERSION
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /usr/local/bin/uv
# 将 Python 安装复制到独立前缀，避免覆盖 npm base 的 /usr/local/（含 Node.js）
RUN mkdir -p /opt/python3.12 && \
    cp -a /usr/local/lib/python3.12      /opt/python3.12/lib && \
    cp -a /usr/local/include/python3.12  /opt/python3.12/include && \
    mkdir -p /opt/python3.12/bin && \
    cp /usr/local/bin/python3.12     /opt/python3.12/bin/ && \
    cp /usr/local/bin/pip3.12        /opt/python3.12/bin/ && \
    cp /usr/local/bin/uv             /opt/python3.12/bin/ && \
    ln -sf python3.12 /opt/python3.12/bin/python3 && \
    ln -sf python3.12 /opt/python3.12/bin/python && \
    ln -sf pip3.12    /opt/python3.12/bin/pip3 && \
    ln -sf pip3.12    /opt/python3.12/bin/pip && \
    ln -sf uv         /opt/python3.12/bin/uv

# Stage 2: uv offline cache — pre-download common Python development packages
FROM python:3.12-slim AS pip-cache
ARG UV_VERSION
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /usr/local/bin/uv
RUN uv venv /tmp/cache-venv && \
    uv pip install --python /tmp/cache-venv/bin/python \
        fastapi \
        uvicorn \
        sqlalchemy \
        psycopg2-binary \
        redis \
        pydantic \
        pytest \
        pytest-asyncio \
        httpx \
        aiohttp

# Stage 3: final image — layered on top of the npm base image
FROM ${BASE_IMAGE}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make jq postgresql-client redis-tools vim-tiny && \
    rm -rf /var/lib/apt/lists/*

# Python toolchain（安装到 /opt/python3.12，不与 Node.js 冲突）
COPY --from=python-toolchain /opt/python3.12/ /opt/python3.12/

# Pre-cached Python packages（构建时下载，运行时 UV_OFFLINE=1 禁止网络访问）
COPY --from=pip-cache /root/.cache/uv/ /home/agent/.cache/uv/
COPY --from=pip-cache /tmp/cache-venv/lib/python3.12/site-packages/ /opt/python3.12/lib/site-packages/

ENV PATH="/opt/python3.12/bin:${PATH}"
ENV PYTHONPATH="/opt/python3.12/lib/site-packages"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
# 运行时禁止 uv 网络访问 —— 只用预缓存的包
# 如果需要新增依赖，在有网机器上重新构建镜像
ENV UV_OFFLINE=1
RUN chown -R agent:agent /home/agent/.cache/uv /opt/python3.12