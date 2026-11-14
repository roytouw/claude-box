# claude-box base image: Claude Code + gh + git + uv, as a non-root user, with helpers that open
# links in the host browser and copy to the host clipboard. Contains no credentials.
FROM ghcr.io/astral-sh/uv:0.8.0 AS uv

FROM node:22-bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/roytouw/claude-box" \
      org.opencontainers.image.description="Claude Code in a container, separated from your host setup" \
      org.opencontainers.image.licenses="MIT"

ARG CLAUDE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq less openssh-client procps ripgrep \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" && npm cache clean --force

RUN userdel -r node \
    && useradd --create-home --uid 1000 --shell /bin/bash agent \
    && mkdir -p /workspace && chown agent:agent /workspace

COPY --chown=agent:agent seed-CLAUDE.md /home/agent/.claude/CLAUDE.md

# Open links in the host browser and copy to the host clipboard (see bin/claude-box).
COPY box-open box-clip /usr/local/bin/
RUN chmod 0755 /usr/local/bin/box-open /usr/local/bin/box-clip \
    && ln -s box-open /usr/local/bin/xdg-open \
    && ln -s box-clip /usr/local/bin/xclip \
    && ln -s box-clip /usr/local/bin/xsel

ENV BROWSER=/usr/local/bin/box-open \
    DISABLE_AUTOUPDATER=1 \
    ENABLE_CLAUDEAI_MCP_SERVERS=false

USER agent
WORKDIR /workspace
CMD ["claude"]
