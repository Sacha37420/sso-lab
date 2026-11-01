# Keycloak du lab — image « optimisée » (chantier failles, F11).
# Les options de construction (base, santé) sont figées ici : au démarrage,
# `start --optimized` saute la phase de reconstruction (≈ 1 à 5 min sur
# l'hôte à 2 vCPU) et le moindre écart d'option de construction est une
# erreur visible plutôt qu'une reconstruction silencieuse.
FROM quay.io/keycloak/keycloak:26.8.1 AS builder
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.8.1
COPY --from=builder /opt/keycloak/ /opt/keycloak/
