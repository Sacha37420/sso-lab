# lab-mcp — serveur MCP du lab (contrat multi-dev, I5).
#
# L'image porte, en plus du serveur Python, TOUT ce dont les commandes
# d'exploitation de scripts/ ont besoin (I4) : bash, git, jq, curl, openssl,
# flock, ss/ip, python3, et le client Docker avec compose + buildx. Ces
# commandes sont exécutées depuis ce conteneur, contre le démon de l'hôte
# (docker.sock monté) et contre le dépôt monté AU MÊME CHEMIN que sur l'hôte.
#
# Volontairement absent : `gh`. Le serveur n'utilise jamais d'identifiants
# GitHub autres que ceux de l'appelant (I5).
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git jq curl openssl openssh-client ca-certificates iproute2 procps util-linux iptables \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# Le serveur tourne sous l'UID du propriétaire du dépôt sur l'hôte : les
# fichiers que les scripts créent dans $ROOT (dossier d'app, .ports, .owners,
# .git…) doivent lui appartenir, et git refuse un dépôt dont le propriétaire
# diffère. Un vrai compte (pas seulement `user:` numérique) : new-app.sh
# appelle `id -un`. Le groupe supplémentaire porte le GID du groupe `docker`
# de l'hôte, pour le socket.
ARG LAB_UID=1000
ARG LAB_GID=1000
ARG DOCKER_GID=989
RUN groupadd -g "${LAB_GID}" lab \
 && (getent group "${DOCKER_GID}" > /dev/null || groupadd -g "${DOCKER_GID}" dockerhost) \
 && useradd -u "${LAB_UID}" -g "${LAB_GID}" -G "${DOCKER_GID}" -m -s /bin/bash lab

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY labmcp ./labmcp
# Pare-feu des ponts d'espace (I3 v7). Le moteur ne l'exécute jamais dans son propre conteneur
# (il n'a ni le réseau de l'hôte ni NET_ADMIN) : il lance un conteneur jetable de CETTE image.
COPY --chmod=0755 firewall/lab-ws-firewall.sh /usr/local/bin/lab-ws-firewall

USER lab
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/app
EXPOSE 8000
CMD ["python", "-m", "labmcp"]
