FROM ghcr.io/coder/code-server:latest
USER root

# Aligner l'UID/GID de l'utilisateur "coder" sur celui de l'hôte (sacha = 1000)
# afin que les fichiers créés dans le volume aient les bons droits côté hôte.
RUN usermod -u 1000 coder && groupmod -g 1000 coder

# Installer Claude Code + git + outils de développement
RUN npm install -g @anthropic-ai/claude-code && \
    apt-get update -q && \
    apt-get install -y --no-install-recommends git curl gh && \
    rm -rf /var/lib/apt/lists/*

# Installer les extensions VS Code utiles au démarrage du container
# (Python, GitLens, GitGraph, Prettier — silencieux si déjà installées)
USER coder
RUN code-server --install-extension ms-python.python 2>/dev/null || true && \
    code-server --install-extension eamodio.gitlens 2>/dev/null || true && \
    code-server --install-extension mhutchie.git-graph 2>/dev/null || true && \
    code-server --install-extension esbenp.prettier-vscode 2>/dev/null || true

WORKDIR /home/coder/dev
