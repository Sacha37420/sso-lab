# ─────────────────────────────────────────────────────────────────────────────
# lab-workspace — image d'espace de travail par projet (contrat multi-dev, I7).
#
# Un conteneur `ws-<uid>` par dev, ouvert sur UN projet, lancé par le moteur
# (lab-mcp) avec les options d'enfermement d'I3. Voir README.md.
#
# Contexte de build = ce dossier seul : l'image ne lit rien du dépôt, ne
# contient aucun secret du lab ni aucun identifiant.
#
# TOUT ce qui doit survivre vit HORS de /home/coder : la maison du dev est
# montée par-dessus à l'exécution et masque ce que l'image y aurait posé.
#
# Versions : toutes épinglées ici, nulle part ailleurs. Pour monter une
# version, changer l'ARG (et son sha256 quand il y en a un), reconstruire,
# puis rejouer `bash workspace/verify.sh`.
# ─────────────────────────────────────────────────────────────────────────────

ARG PYTHON_IMAGE=python:3.12.15-slim-bookworm
ARG NODE_IMAGE=node:20.20.2-bookworm-slim
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.13.0

FROM ${NODE_IMAGE} AS node
FROM ${UV_IMAGE} AS uv

FROM ${PYTHON_IMAGE}

ARG CODE_SERVER_VERSION=4.141.0
ARG CODE_SERVER_SHA256=f384beb4f3ba207e0bca27d0dbd36dd825d5aa909d78c6d4baa8703eaf6b77ba
ARG GH_VERSION=2.102.0
ARG GH_SHA256=7e54a307f90afdc59796c325ec0c49fb09e6c18537727207a8ac7513584ea5b0
ARG CLAUDE_CODE_VERSION=2.1.296
ARG MISTRAL_VIBE_VERSION=2.26.1
ARG EXT_PYTHON_VERSION=2026.4.0

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Outils de base. Ni sudo, ni docker, ni compilateur : un besoin ponctuel de
# paquet système est un besoin d'image, pas quelque chose que le dev installe.
RUN apt-get update -q \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client tini \
      less nano procps jq unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Node 20 (+ npm) : copié depuis l'image officielle, pas de `curl | bash`.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && node --version && npm --version

# uv : binaire officiel, sert à installer Vibe et reste disponible au dev.
COPY --from=uv /uv /uvx /usr/local/bin/

# code-server et gh : paquets .deb des publications GitHub, somme vérifiée.
RUN set -eu; cd /tmp; \
    curl -fsSL -o cs.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_amd64.deb"; \
    curl -fsSL -o gh.deb "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.deb"; \
    printf '%s  cs.deb\n%s  gh.deb\n' "$CODE_SERVER_SHA256" "$GH_SHA256" | sha256sum -c -; \
    dpkg -i cs.deb gh.deb; \
    rm -f cs.deb gh.deb; \
    code-server --version; gh --version

# Claude Code : paquet npm global épinglé. La mise à jour automatique est
# coupée (ENV plus bas) — elle échouerait de toute façon, `coder` ne pouvant
# pas écrire dans /usr/local, et l'image doit rester celle qui a été vérifiée.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

# Mistral Vibe : `uv tool`, environnement isolé sous /opt, commande dans le PATH.
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin UV_NO_CACHE=1 \
      uv tool install --python /usr/local/bin/python3.12 "mistral-vibe==${MISTRAL_VIBE_VERSION}" \
 && vibe --version

# Utilisateur non-root, uid/gid 1000. Aucun groupe supplémentaire.
RUN groupadd -g 1000 coder \
 && useradd -u 1000 -g 1000 -M -d /home/coder -s /bin/bash coder \
 && mkdir -p /home/coder /work /opt/lab/extensions \
 && chown coder:coder /home/coder /work /opt/lab/extensions

# Extension Python : installée hors de la maison (elle serait masquée par le
# montage), recopiée dans la maison au premier démarrage par l'entrée.
USER coder
RUN code-server --extensions-dir /opt/lab/extensions \
      --install-extension "ms-python.python@${EXT_PYTHON_VERSION}" \
 && test -d /opt/lab/extensions/ms-python.python-*
USER root
# La maison de l'image reste VIDE : tout ce qui s'y trouverait serait masqué
# par le montage, donc trompeur.
RUN find /home/coder -mindepth 1 -delete && test -z "$(ls -A /home/coder)"

# Configuration posée par l'image (jamais dans la maison) :
#   /etc/gitconfig        assistant d'identifiants lisant GH_TOKEN dans l'environnement
#   /opt/lab/code-server.yaml  écoute et options de l'éditeur
#   /opt/lab/regles-lab.md     règles d'I8, posées dans la maison par l'entrée
COPY config/gitconfig /etc/gitconfig
COPY config/code-server.yaml /opt/lab/code-server.yaml
COPY regles-lab.md /opt/lab/regles-lab.md
COPY entrypoint.sh /usr/local/bin/lab-entrypoint
COPY lib/ /opt/lab/lib/
RUN chmod 0755 /usr/local/bin/lab-entrypoint \
 && chmod -R a+rX,go-w /opt/lab/lib /opt/lab/regles-lab.md /opt/lab/code-server.yaml /etc/gitconfig

# Garde-fous de build : ce que l'image ne doit PAS contenir.
RUN ! command -v sudo && ! command -v docker && ! getent group docker \
 && test "$(id -u coder)" = 1000 && test "$(id -Gn coder)" = coder

ENV HOME=/home/coder \
    SHELL=/bin/bash \
    DISABLE_AUTOUPDATER=1 \
    LAB_WORKSPACE_VERSIONS="code-server=${CODE_SERVER_VERSION} gh=${GH_VERSION} claude-code=${CLAUDE_CODE_VERSION} mistral-vibe=${MISTRAL_VIBE_VERSION} ms-python.python=${EXT_PYTHON_VERSION}"

USER coder
WORKDIR /work
EXPOSE 8080
ENTRYPOINT ["tini", "--", "/usr/local/bin/lab-entrypoint"]
