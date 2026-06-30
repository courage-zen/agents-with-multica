ARG BASE_IMAGE
ARG UV_VERSION

# Stage 1: Python + uv toolchain
FROM python:3.12-slim AS python-toolchain
ARG UV_VERSION
RUN pip install --no-cache-dir uv==${UV_VERSION}
# 将 Python 安装复制到独立前缀，避免覆盖 npm base 的 /usr/local/（含 Node.js）
RUN mkdir -p /opt/python3.12 && \
    cp -a /usr/local/lib/python3.12      /opt/python3.12/lib && \
    cp -a /usr/local/include/python3.12  /opt/python3.12/include && \
    mkdir -p /opt/python3.12/bin && \
    cp /usr/local/bin/python3.12         /opt/python3.12/bin/ && \
    cp /usr/local/bin/pip3               /opt/python3.12/bin/  || true && \
    cp /usr/local/bin/pip                /opt/python3.12/bin/  || true && \
    cp /usr/local/bin/uv                 /opt/python3.12/bin/ && \
    cp /usr/local/bin/uvx                /opt/python3.12/bin/ || true && \
    cp -a /usr/local/lib/libpython3.12*  /opt/python3.12/lib/  || true && \
    ln -sf python3.12 /opt/python3.12/bin/python3 && \
    ln -sf python3.12 /opt/python3.12/bin/python && \
    ln -sf pip3       /opt/python3.12/bin/pip3 && \
    ln -sf pip3       /opt/python3.12/bin/pip && \
    ln -sf uv         /opt/python3.12/bin/uv && \
    # 修复所有脚本的 shebang，使其指向新路径
    find /opt/python3.12/bin -type f -exec sed -i 's|#!/usr/local/bin/python3|#!/opt/python3.12/bin/python3|g' {} \;

# Stage 2: pre-install common Python development packages
FROM python:3.12-slim AS pip-cache
ARG UV_VERSION
RUN pip install --no-cache-dir uv==${UV_VERSION}
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
        aiohttp \
        'mcp[cli]' \
        sqlglot \
        pymysql \
        python-dotenv

# Stage 3: final image — layered on top of the npm base image
FROM ${BASE_IMAGE}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make jq postgresql-client redis-tools vim-tiny && \
    rm -rf /var/lib/apt/lists/*

# Python toolchain（安装到 /opt/python3.12，不与 Node.js 冲突）
COPY --from=python-toolchain /opt/python3.12/ /opt/python3.12/

# Pre-installed Python packages（直接安装到 site-packages，无需 uv cache）
COPY --from=pip-cache /tmp/cache-venv/lib/python3.12/site-packages/ /opt/python3.12/lib/site-packages/

ENV PATH="/opt/python3.12/bin:${PATH}"
ENV PYTHONPATH="/opt/python3.12/lib/site-packages"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
# 注册 Python 库路径到系统链接器，避免 LD_LIBRARY_PATH 全局污染影响 Node.js 进程
RUN echo "/opt/python3.12/lib" > /etc/ld.so.conf.d/python3.12.conf && ldconfig
RUN chown -R agent:agent /opt/python3.12/lib/site-packages