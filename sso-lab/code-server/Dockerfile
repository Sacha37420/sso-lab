FROM ghcr.io/coder/code-server:latest
USER root

# Aligner l'UID/GID de l'utilisateur "coder" sur celui de l'hôte (sacha = 1000)
RUN usermod -u 1000 coder && groupmod -g 1000 coder

# Installer Node.js 20 LTS (npm n'est pas dans le PATH de l'image de base)
# puis Claude Code CLI + outils de développement
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends curl ca-certificates git gh && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g @anthropic-ai/claude-code && \
    rm -rf /var/lib/apt/lists/*

# Installer les extensions VS Code utiles
USER coder
RUN code-server --install-extension ms-python.python 2>/dev/null || true && \
    code-server --install-extension eamodio.gitlens 2>/dev/null || true && \
    code-server --install-extension mhutchie.git-graph 2>/dev/null || true && \
    code-server --install-extension esbenp.prettier-vscode 2>/dev/null || true && \
    code-server --install-extension angular.ng-template 2>/dev/null || true

WORKDIR /home/coder/dev
