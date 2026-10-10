#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# lab-ws-firewall — ferme l'hôte et les autres ponts aux espaces de travail.
# Contrat multi-dev, I3 (v7).
#
#   lab-ws-firewall apply  <préfixe>     pose les règles (idempotent)
#   lab-ws-firewall remove <préfixe>     les retire
#   lab-ws-firewall show                 liste complète des règles (iptables-save, table filter)
#
# <préfixe> : préfixe d'INTERFACE des ponts d'espace — « lws » en service,
# « lwt… » pour les essais. Forme imposée : ^lw[a-z]{1,5}$.
#
# OÙ IL TOURNE : dans un conteneur JETABLE lancé par le moteur, en réseau hôte,
# avec la seule capacité NET_ADMIN (le moteur n'a ni l'un ni l'autre). Il ne
# fait rien d'autre que ce fichier.
#
# CE QU'IL TOUCHE — et rien d'autre : la table filter d'IPv4, chaînes INPUT et
# DOCKER-USER, par des règles qui portent TOUTES « -i <préfixe>+ » et le
# commentaire « lab-ws:<préfixe> ». Une règle sans cette interface ne peut pas
# sortir d'ici : `rule` l'ajoute elle-même. Ni nat, ni mangle, ni les chaînes de
# Docker, ni edge-net, ni un `ports:`.
#
# POURQUOI DEUX CHAÎNES — où passe chaque flux d'un espace :
#   • vers un service NATIF de l'hôte (sshd :22, sur l'IP de la passerelle du
#     pont ou l'IP LAN de l'hôte)                          → INPUT ;
#   • vers un port PUBLIÉ par Docker (Keycloak :8080, LDAP :389, pgAdmin :5050,
#     ports d'apps) : Docker le réécrit (DNAT) vers le conteneur AVANT le
#     filtrage, le paquet est alors transmis vers un autre pont → DOCKER-USER ;
#   • vers le réseau local (192.168.x) ou un autre pont   → DOCKER-USER ;
#   • vers Internet                                        → DOCKER-USER, laissé passer.
#
# RÈGLES (dans cet ordre, en tête de chaîne) :
#   INPUT        80/443 → ACCEPT ; tout le reste → REJECT
#   DOCKER-USER  même pont → RETURN (sans effet tant que br_netfilter est absent) ;
#                connexion réécrite dont le port d'ORIGINE est 80/443 (l'URL
#                publique du lab, publiée par edge-router) → RETURN ;
#                destination privée (10/8, 172.16/12, 192.168/16, 169.254/16,
#                100.64/10) → REJECT ; le reste (Internet) n'est pas touché.
#   RETURN et non ACCEPT : ce qui est laissé passer reste soumis aux règles de
#   Docker (isolement entre ponts compris).
# ─────────────────────────────────────────────────────────────────────────────
set -eu

CMD="${1:-}"; PFX="${2:-}"

# Le dorsal que Docker utilise réellement : celui où DOCKER-USER existe.
IPT=""
for bin in iptables-nft iptables-legacy iptables; do
  if command -v "$bin" > /dev/null 2>&1 && "$bin" -w 5 -t filter -S DOCKER-USER > /dev/null 2>&1; then
    IPT="$bin"; break
  fi
done
[ -n "$IPT" ] || { echo "lab-ws-firewall : chaîne DOCKER-USER introuvable (Docker n'utilise pas iptables ?) — rien n'a été fait" >&2; exit 3; }

if [ "$CMD" = "show" ]; then
  echo "# dorsal : $IPT ($($IPT -V))"
  "${IPT}-save" -t filter
  exit 0
fi

echo "$PFX" | grep -Eq '^lw[a-z]{1,5}$' || { echo "lab-ws-firewall : préfixe refusé : '$PFX' (attendu ^lw[a-z]{1,5}\$)" >&2; exit 2; }
IF="${PFX}+"
TAG="lab-ws:${PFX}"

# Toute règle passe par ici : interface et commentaire sont ajoutés ICI, pas par l'appelant.
rule() { chain="$1"; shift; printf '%s\n' "-A $chain -i $IF $* -m comment --comment $TAG"; }

wanted() {
  rule INPUT       -p tcp -m multiport --dports 80,443 -j ACCEPT
  rule INPUT       -j REJECT --reject-with icmp-port-unreachable
  rule DOCKER-USER -o "$IF" -j RETURN
  rule DOCKER-USER -p tcp -m conntrack --ctstate DNAT --ctorigdstport 443 -j RETURN
  rule DOCKER-USER -p tcp -m conntrack --ctstate DNAT --ctorigdstport 80 -j RETURN
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
    rule DOCKER-USER -d "$net" -j REJECT --reject-with icmp-port-unreachable
  done
}

# Nos règles actuellement en place (reconnues à leur commentaire), telles que le noyau les rend.
# (le noyau rend le commentaire entre guillemets : --comment "lab-ws:lws")
MINE="--comment \"\{0,1\}${TAG}\"\{0,1\}\( \|\$\)"
current() { for c in INPUT DOCKER-USER; do "$IPT" -w 5 -t filter -S "$c" | grep -- "$MINE" || true; done; }

remove_all() {
  current | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # « -A CHAÎNE … » → « -D CHAÎNE … » ; la règle est rejouée mot pour mot.
    # shellcheck disable=SC2086
    eval "set -- $line"; shift; chain="$1"; shift
    "$IPT" -w 5 -t filter -D "$chain" "$@"
  done
}

case "$CMD" in
  remove)
    remove_all
    echo "lab-ws-firewall : règles « $TAG » retirées ($IPT)"
    ;;
  apply)
    n_wanted="$(wanted | wc -l)"
    # Déjà en place, complètes et en tête des deux chaînes ? Alors rien à faire.
    ok=1
    [ "$(current | wc -l)" = "$n_wanted" ] || ok=0
    for c in INPUT DOCKER-USER; do
      k="$(wanted | grep -c -- "^-A $c ")"
      "$IPT" -w 5 -t filter -S "$c" | grep '^-A ' | head -n "$k" | grep -c -- "$MINE" | grep -qx "$k" || ok=0
    done
    if [ "$ok" = 1 ]; then echo "lab-ws-firewall : règles « $TAG » déjà en place ($IPT)"; exit 0; fi
    remove_all
    # Insérées en tête, dans l'ordre voulu : la dernière voulue d'abord.
    wanted | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' | while IFS= read -r line; do
      # shellcheck disable=SC2086
      eval "set -- $line"; shift; chain="$1"; shift
      "$IPT" -w 5 -t filter -I "$chain" 1 "$@"
    done
    [ "$(current | wc -l)" = "$n_wanted" ] || { echo "lab-ws-firewall : pose incomplète — règles retirées" >&2; remove_all; exit 4; }
    echo "lab-ws-firewall : $n_wanted règles « $TAG » posées ($IPT)"
    ;;
  *)
    echo "usage : lab-ws-firewall apply|remove <préfixe> | show" >&2; exit 2 ;;
esac
