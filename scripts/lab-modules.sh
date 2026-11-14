#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lab-modules.sh — catalogue des modules du lab, état, plan d'installation.
# Chantier « modules », contrat v1, I2 (chantiers/modules/CONTRAT.md).
#
# Usage :
#   bash scripts/lab-modules.sh list [--json]
#   bash scripts/lab-modules.sh show <nom> [--json] [--check]
#   bash scripts/lab-modules.sh plan [--json] [--reinstall] [--with-deps] [--for-engine] <nom>[,<nom>…]
#   bash scripts/lab-modules.sh selection [--json]
#   bash scripts/lab-modules.sh selection add <nom>[,…] [--by <uid>]
#   bash scripts/lab-modules.sh settings <nom>     stdin : lignes CLÉ=valeur
#   bash scripts/lab-modules.sh prepare <nom>
#
# list / show / plan / selection : LECTURE SEULE, sans verrou. Avec --json :
# une ligne JSON sur stdout (formes : contrat I2) ; sans : un tableau lisible.
# Un module = une unité du lab (dossier avec docker-compose.yml, sous-module
# déclaré, ou entrée du catalogue modules/). Sa description : <dossier>/lab-module.json,
# sinon modules/<nom>.json, sinon déduite (modules/README.md).
#
# show --check : vérifie prérequis système, domaine, réglages, dépendances,
#   groupes (Keycloak, adresse interne — jamais créés) et joue `install.sh --check`
#   du module s'il en déclare un (module-hook.sh).
#
# settings <nom> : pour chaque ligne CLÉ=valeur lue sur stdin, écrit la clé dans
#   le .env du module (app-env.sh set, donc sous le verrou de déploiement et
#   jamais une clé gérée) SEULEMENT si elle est déclarée par la description et
#   pas encore réglée. Un réglage déjà posé n'est jamais réécrit. Une ligne par
#   clé sur stdout, sans valeur : « CLÉ: écrit | déjà réglé | non déclaré | refusé ».
#
# prepare <nom> : rend un module déployable sans rien démarrer — extrait son
#   sous-module s'il est vide (app du superutilisateur seulement : un projet de
#   développeur se récupère par app-sync.sh, avec sa clé de déploiement), crée
#   son .env depuis .env.example s'il n'en a pas (lib/fresh-env.sh, mêmes
#   ajustements qu'install.sh). Ne touche jamais à un .env existant.
#
# Codes : 0 succès · 1 refus ou échec (JSON rendu quand même avec --json) · 2 usage.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"
PY=(python3 -B "$SCRIPT_DIR/lib/modules.py" "$ROOT")

usage() { sed -n '/^# Usage :/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die()   { echo "✗ lab-modules : $*" >&2; exit 1; }

CMD="${1:-}"; [[ -n "$CMD" ]] || usage; shift

# Tableau lisible d'un `list --json` (pour un humain sur l'hôte).
human_list() {
  jq -r '
    def st: {"installed":"installé","stopped":"arrêté","not_installed":"non installé","inaccessible":"inaccessible",
             "absent":"absent","invalid":"description invalide"}[.] // .;
    "Sélection mémorisée : " + (if .selection.memorized then ((.selection.modules | join(", ")) + "  (" + (.selection.updated_at // "?") + ")") else "aucune" end),
    "",
    (.modules[] | [ .name, .category, (.state | st), (if .required then "obligatoire" elif .selected then "choisi" else "" end),
                    ((.requires.modules | map(.name) | join(",")) | if . == "" then "—" else . end), .source ] | @tsv)' \
  | awk -F'\t' 'NR <= 2 { print; next } { printf "  %-32s %-12s %-22s %-12s %-26s %s\n", $1, $2, $3, $4, $5, $6 }'
}

case "$CMD" in
  list)
    json=false; for a in "$@"; do case "$a" in --json) json=true ;; *) usage ;; esac; done
    _o="$("${PY[@]}" list)" || exit $?
    if $json; then printf '%s\n' "$_o"; else printf '%s\n' "$_o" | human_list; fi
    ;;

  show)
    name=""; json=false; check=false
    for a in "$@"; do case "$a" in --json) json=true ;; --check) check=true ;; -*) usage ;; *) [[ -z "$name" ]] && name="$a" || usage ;; esac; done
    registry_valid_app "$name" || usage
    args=(show "$name")
    tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
    if $check; then
      args+=(--check)
      # Groupes du realm : par l'API d'administration, adresse INTERNE (kcadmin.sh).
      # shellcheck source=lib/kcadmin.sh
      source "$SCRIPT_DIR/lib/kcadmin.sh"
      if kc_admin_login 2> /dev/null && kc_admin_get "/groups?briefRepresentation=true&max=1000" 2> /dev/null \
           | jq -r '.. | objects | select(has("name") and has("path")) | .name' > "$tmpd/groups" 2> /dev/null; then
        args+=(--groups-file "$tmpd/groups")
      fi
      LAB_HOOK_RESULT_FILE="$tmpd/hook" bash "$SCRIPT_DIR/module-hook.sh" "$name" --check > /dev/null 2>&1 || true
      [[ -s "$tmpd/hook" ]] && args+=(--hook-file "$tmpd/hook")
    fi
    _o="$("${PY[@]}" "${args[@]}")"; rc=$?
    if $json || [[ $rc -eq 2 ]]; then printf '%s\n' "$_o"; exit $rc; fi
    printf '%s\n' "$_o" | jq -r '
      if .error then "✗ " + .detail else
      "\(.label)  (\(.name))  — \(.category)\(if .required then ", obligatoire" else "" end)",
      "  état : \(.state)   description : \(.source)\(if .valid then "" else " — INVALIDE" end)",
      (.errors[]? | "  ✘ " + .),
      "  dépend de : " + ((.requires.modules | map(.name + (if .interface then " (interface " + .interface + ")" else "" end)) | join(", ")) | if . == "" then "—" else . end),
      (if (.requires.system | length) > 0 then "  système : " + (.requires.system | map(.command + (if .min_version then " ≥ " + .min_version else "" end)) | join(", ")) else empty end),
      (if (.settings | length) > 0 then "  réglages : " + (.settings | map(.key + (if .set then " ✔" else (if .required then " (requis, à régler)" else " (facultatif, non réglé)" end) end)) | join(", ")) else empty end),
      "  groupes : " + ((.groups | join(", ")) | if . == "" then "—" else . end),
      "  script d'\''installation : " + (if .install then "install.sh (" + (.install.timeout_s|tostring) + " s)" else "aucun" end),
      (.checks[]? | "  " + (if .ok == true then "✔" elif .ok == false then "✘" else "·" end) + " " + .what + " — " + .detail),
      (if has("ok") then (if .ok then "  → rien ne manque" else "  → quelque chose manque" end) else empty end)
      end'
    exit $rc
    ;;

  plan)
    json=false; flags=(); names=""
    for a in "$@"; do
      case "$a" in
        --json) json=true ;;
        --reinstall|--with-deps|--for-engine) flags+=("$a") ;;
        -*) usage ;;
        *) [[ -z "$names" ]] && names="$a" || usage ;;
      esac
    done
    [[ -n "$names" ]] || usage
    _o="$("${PY[@]}" plan "${flags[@]}" "$names")"; rc=$?
    if $json || [[ $rc -eq 2 ]]; then printf '%s\n' "$_o"; exit $rc; fi
    printf '%s\n' "$_o" | jq -r '
      def act: {"install":"installer","reinstall":"réinstaller","keep":"déjà en service, inchangé"}[.] // .;
      "Plan pour : " + (.requested | join(", ")),
      (if (.steps | length) > 0 then "Dans cet ordre :" else empty end),
      (.steps | to_entries[] | "  \(.key + 1). \(.value.module) — \(.value.action | act)\(if .value.reason != "demandé" then " (" + .value.reason + ")" else "" end)\(if .value.hook then " · script d’installation" else "" end)"),
      (if (.blocked | length) > 0 then "Ne pourront pas être installés :" else empty end),
      (.blocked[] | "  ✘ \(.module) — \(.reason)"),
      (if (.settings_missing | length) > 0 then "Réglages à fournir :" else empty end),
      (.settings_missing[] | "  · \(.module) : \(.key)\(if .required then " (requis)" else "" end) — \(.question)"),
      (.warnings[] | "  ⚠ " + .),
      (if .ok then "→ plan réalisable" else "→ plan NON réalisable" end)'
    exit $rc
    ;;

  selection)
    sub="${1:-}"
    case "$sub" in
      ""|--json) _o="$("${PY[@]}" selection)" || exit $?
                 if [[ "$sub" == "--json" ]]; then printf '%s\n' "$_o"
                 else printf '%s\n' "$_o" | jq -r 'if .memorized then "Sélection : " + (.modules | join(", ")) + " — " + (.updated_at // "?") + " par " + (.by // "?") else "Aucune sélection mémorisée." end'; fi ;;
      add) shift; names="${1:-}"; shift || true
           by="$(registry_superuser)"
           if [[ "${1:-}" == "--by" ]]; then by="${2:-}"; fi
           registry_valid_uid "$by" || die "--by : uid du lab attendu"
           "${PY[@]}" selection-add "$names" --by "$by" ;;
      *) usage ;;
    esac
    ;;

  settings)
    name="${1:-}"; [[ $# -eq 1 ]] && registry_valid_app "$name" || usage
    declared=" $("${PY[@]}" declared-settings "$name" | tr '\n' ' ') "
    dir="$(registry_app_dir "$name")"
    [[ -f "$dir/.env" ]] || die "$name n'a pas de .env (bash scripts/lab-modules.sh prepare $name)"
    refused=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      key="${line%%=*}"; val="${line#*=}"
      if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]{0,63}$ || "$line" != *=* ]]; then echo "?: ligne ignorée (CLÉ=valeur attendu)"; refused=1; continue; fi
      if [[ "$declared" != *" $key "* ]]; then echo "$key: non déclaré"; refused=1; continue; fi
      cur="$(grep -E "^${key}=" "$dir/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e "s/^['\"]//" -e "s/['\"]\$//")"
      if [[ -n "$cur" && "$cur" != *CHANGE_ME* ]]; then echo "$key: déjà réglé"; continue; fi
      if printf '%s' "$val" | bash "$SCRIPT_DIR/app-env.sh" set "$name" "$key" > /dev/null 2>&1; then echo "$key: écrit"
      else echo "$key: refusé"; refused=1; fi
    done
    val=""; cur=""
    exit $refused
    ;;

  prepare)
    name="${1:-}"; [[ $# -eq 1 ]] && registry_valid_app "$name" || usage
    dir="$(registry_app_dir "$name")"
    rel="$(registry_app_relpath "$name")"
    # 1. Sous-module vide : extraction (app du superutilisateur seulement).
    if [[ -d "$dir" && -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
      registry_is_superuser "$(registry_app_owner "$name")" \
        || die "$name : dossier vide et propriétaire ≠ superutilisateur — un projet de développeur se récupère par son déploiement (app-sync.sh)"
      section="$(git -C "$ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
                 | awk -v p="$rel" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1; exit }')"
      [[ -n "$section" ]] || die "$rel est vide et n'est pas un sous-module déclaré"
      echo "  → extraction du sous-module $rel"
      git -C "$ROOT" -c "submodule.${section}.update=checkout" submodule update --init -- "$rel" 2>&1 | sed 's/^/    /' >&2
      [[ -n "$(ls -A "$dir" 2>/dev/null)" ]] || die "sous-module $rel inaccessible (dépôt privé ?)"
    fi
    [[ -f "$dir/docker-compose.yml" ]] || die "$name n'a pas de docker-compose.yml : rien à installer"
    # 2. .env depuis le gabarit, s'il manque.
    if [[ -f "$dir/.env" ]]; then
      echo "  ✔ $rel/.env présent (jamais réécrit)"
    elif [[ -f "$dir/.env.example" ]]; then
      # shellcheck source=lib/fresh-env.sh
      source "$SCRIPT_DIR/lib/fresh-env.sh"
      lab_fresh_env "$dir" || die "création de $rel/.env impossible"
      echo "  ✔ $rel/.env créé depuis son gabarit (base, secrets et identités ajustés)"
    else
      die "$rel n'a ni .env ni .env.example"
    fi
    ;;

  *) usage ;;
esac
