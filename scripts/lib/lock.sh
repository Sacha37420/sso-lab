# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/lock.sh — verrou de déploiement du lab (à SOURCER, après
# registry.sh). Contrat « multi-dev » v2, I4 :
#
#   « Un seul déploiement ou une seule création à la fois sur l'hôte : flock
#     sur <LAB_STATE_DIR>/deploy.lock (attente bornée, puis échec explicite). »
#
# POURQUOI UN VERROU : 2 vCPU / 16 Go — deux builds concurrents se ralentissent
# au point de sembler bloqués ; et deux créations simultanées ne doivent pas
# pouvoir obtenir le même nom ni le même port (le contrôle du nom et l'écriture
# de .ports/.owners se font sous ce verrou, I1).
#
# RÉ-ENTRANCE — le point qui piège : flock est attaché à une « description de
# fichier ouverte ». Un script qui tient le verrou et appelle un autre script
# qui le reprend par un NOUVEL open() se bloquerait lui-même jusqu'à
# l'expiration du délai. Or les commandes s'emboîtent (setup2.sh est appelé
# pendant un déploiement qui a déjà fait app-sync.sh ; le MCP enchaîne
# check-app-name → new-app → app-register « sous le verrou »).
# Convention retenue :
#   • celui qui prend le verrou exporte LAB_LOCK_HELD=<chemin du verrou> ;
#   • un script qui trouve cette variable NE la croit PAS sur parole : il tente
#     un flock non bloquant. S'il l'obtient, c'est que personne ne tenait le
#     verrou (variable héritée d'un environnement périmé) — il le garde, et
#     tout est en ordre. S'il ne l'obtient pas, le verrou est bien tenu, par un
#     ancêtre : il continue sans le reprendre.
#   Une variable d'environnement mensongère ne peut donc JAMAIS faire tourner
#   une commande sans qu'un verrou soit réellement tenu par quelqu'un.
#
# Pour enchaîner plusieurs commandes sous UN verrou (cas du MCP) :
#   bash scripts/lab-lock.sh <commande> [args…]
#
# Réglage : LAB_LOCK_TIMEOUT (secondes d'attente, défaut 900).
# Code de sortie en cas d'attente dépassée : 75 (EX_TEMPFAIL).
# ─────────────────────────────────────────────────────────────────────────────

lab_lock_path() { printf '%s/deploy.lock\n' "$(registry_state_dir)"; }

# Prend le verrou (ou constate qu'un ancêtre le tient). À appeler une fois, tôt.
# Le verrou est relâché automatiquement à la fin du processus (fermeture du fd).
lab_lock_acquire() {
  local what="${1:-opération}" path timeout="${LAB_LOCK_TIMEOUT:-900}"
  path="$(lab_lock_path)"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=900

  mkdir -p "$(dirname "$path")" || {
    echo "✗ Verrou de déploiement : impossible de créer $(dirname "$path")" >&2; return 1; }
  # fd ouvert en ajout : n'écrase jamais le contenu (le fichier sert de témoin).
  exec {_LAB_LOCK_FD}>>"$path" || {
    echo "✗ Verrou de déploiement : impossible d'ouvrir $path" >&2; return 1; }

  if flock -n "$_LAB_LOCK_FD"; then
    :
  elif [[ "${LAB_LOCK_HELD:-}" == "$path" ]]; then
    # Tenu par un ancêtre (voir en-tête) : on ne le reprend pas.
    exec {_LAB_LOCK_FD}>&-
    return 0
  else
    echo "… Verrou de déploiement occupé (dernier détenteur enregistré : $(cat "$path.holder" 2>/dev/null || echo inconnu)) — attente jusqu'à ${timeout}s pour : $what" >&2
    if ! flock -w "$timeout" "$_LAB_LOCK_FD"; then
      echo "✗ Verrou de déploiement toujours occupé après ${timeout}s — abandon de : $what" >&2
      echo "  Dernier détenteur enregistré : $(cat "$path.holder" 2>/dev/null || echo inconnu)" >&2
      exec {_LAB_LOCK_FD}>&-
      return 75
    fi
  fi

  export LAB_LOCK_HELD="$path"
  # Témoin purement informatif (qui tient le verrou, depuis quand) : jamais lu
  # pour décider quoi que ce soit.
  printf '%s pid=%s depuis %s\n' "$what" "$$" "$(date '+%F %T')" > "$path.holder" 2>/dev/null || true
  return 0
}
