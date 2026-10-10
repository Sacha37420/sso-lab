#!/bin/sh
# scripts/lib/git-askpass.sh — fournit à git le jeton du développeur.
#
# Contrat multi-dev I4 : « Le jeton GitHub arrive par la variable
# d'environnement LAB_GIT_TOKEN, consommé via GIT_ASKPASS. Jamais écrit dans
# .git/config, une URL de remote, un journal ou .owners. »
#
# git appelle ce programme avec la question en argument (« Username for
# 'https://github.com': », « Password for 'https://x@github.com': ») et lit la
# réponse sur stdout. Rien n'est jamais écrit ailleurs.
case "$1" in
  Username*) printf '%s\n' "${LAB_GIT_USERNAME:-x-access-token}" ;;
  Password*) printf '%s\n' "${LAB_GIT_TOKEN:-}" ;;
  *)         printf '\n' ;;
esac
