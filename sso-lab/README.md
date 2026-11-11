# SSO Lab — OpenLDAP + Keycloak + Spring Boot

Lab d'apprentissage SSO/LDAP pour préparer un poste Développeur Intégrateur.

## Stack
| Service | Image | Port |
|---|---|---|
| OpenLDAP | osixia/openldap:1.5.0 | 389 |
| phpLDAPadmin | osixia/phpldapadmin:0.9.0 | 8081 |
| Keycloak | sso-lab-keycloak:26.8.1 (base `keycloak` de `dev-postgres`) | 8080 (127.0.0.1) |
| Spring App | (étape 3) | 8082 |

## Lancement
```bash
cd sso-lab
docker compose up -d
```

## Étapes
- [x] Étape 1 — docker-compose.yml + init.ldif
- [ ] Étape 2 — User Federation Keycloak → LDAP
- [ ] Étape 3 — Spring Boot OIDC
- [ ] Étape 4 — Flux complet & JWT
- [ ] Étape 5 — SSO multi-apps
