# Workspace image: the claude-box base (Node, gh, glab, git) plus what the repos need.
FROM ghcr.io/roytouw/claude-box:base

ARG GO_VERSION=1.26.2

USER root
RUN apt-get update && apt-get install -y --no-install-recommends make \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
       | tar -C /usr/local -xz
USER agent

ENV PATH="/usr/local/go/bin:/home/agent/go/bin:${PATH}"
