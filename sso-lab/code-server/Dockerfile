FROM ghcr.io/coder/code-server:latest
USER root
# Installer Claude Code CLI + outils utiles
RUN npm install -g @anthropic-ai/claude-code && \
    apt-get update -q && \
    apt-get install -y --no-install-recommends git curl && \
    rm -rf /var/lib/apt/lists/*
USER coder
WORKDIR /home/coder/dev
