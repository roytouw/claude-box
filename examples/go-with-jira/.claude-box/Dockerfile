# Project image: the claude-box base plus the tools this project needs.
FROM ghcr.io/roytouw/claude-box:base

ARG GO_VERSION=1.26.2

USER root
RUN apt-get update && apt-get install -y --no-install-recommends make postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
       | tar -C /usr/local -xz

# Jira/Confluence MCP server, preinstalled outside the home volume so it starts instantly.
RUN UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    uv tool install mcp-atlassian && chmod -R a+rX /opt/uv
USER agent

ENV PATH="/usr/local/go/bin:/home/agent/go/bin:${PATH}"
