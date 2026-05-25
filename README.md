# SSO Lab — Plateforme d'authentification SSO

Lab d'apprentissage SSO/LDAP autour de **Keycloak**, **OpenLDAP**, **PostgreSQL** et **pgAdmin**, avec deux applications clientes (Spring Boot + Angular) authentifiées via OIDC.

---

## Architecture

```
dev/
├── sso-lab/            ← Keycloak 22 + OpenLDAP + phpLDAPadmin
├── infra/              ← PostgreSQL 16 + pgAdmin 8 (OAuth2 Keycloak)
├── front-cadriciel/    ← Angular 17 SPA  [submodule git]
├── spring-app/         ← Spring Boot 3   [submodule git]
├── bbox.env            ← source de vérité réseau (LAN/WAN, Bbox)
├── setup.sh            ← initialisation complète depuis zéro
├── clean.sh            ← remise à zéro (volumes compris)
├── reset_url.sh        ← propage les IPs vers tous les .env
├── init-secrets.sh     ← génère des mots de passe forts
├── recompose_docker.sh ← gère le cycle de vie des stacks Docker
├── create-app-client.sh← crée/met à jour les clients Keycloak
├── new-app.sh          ← scaffolde une nouvelle application
├── get-ports-list.sh   ← génère ports.env depuis tous les .env
└── open-bbox-ports.sh  ← ouvre les ports NAT sur la Bbox Bouygues
```

---

## Services et ports

| Service        | Stack      | Port | Accès                              |
|----------------|------------|------|------------------------------------|
| Keycloak       | sso-lab    | 8080 | `http://LAN_IP:8080`               |
| phpLDAPadmin   | sso-lab    | 8081 | `http://LAN_IP:8081`               |
| pgAdmin        | infra      | 5050 | `http://LAN_IP:5050`               |
| PostgreSQL     | infra      | —    | interne uniquement (`dev-net`)     |
| Spring Boot    | spring-app | 8082 | `http://LAN_IP:8082`               |
| Angular        | front-cadriciel | 4200 | `http://LAN_IP:4200`          |

---

## Réseaux Docker

| Réseau            | Utilisé par                                      |
|-------------------|--------------------------------------------------|
| `sso-lab_sso-net` | Keycloak, OpenLDAP, phpLDAPadmin, infra, apps    |
| `dev-net`         | PostgreSQL, pgAdmin, Spring Boot, Angular        |

---

## Utilisateurs LDAP

| Utilisateur | Groupes                          | Accès pgAdmin |
|-------------|----------------------------------|---------------|
| sacha       | developers, admins, famille, amis | ✓            |
| hassan      | developers, amis                 | ✓             |
| lea         | famille, amis                    | ✗             |
| elodie      | famille                          | ✗             |

> pgAdmin est restreint au groupe **developers** via `OAUTH2_ADDITIONAL_CLAIMS`.

---

## Premier démarrage

### Prérequis

- Docker + Docker Compose
- `curl`, `jq`
- Cloner avec les submodules :

```bash
git clone --recurse-submodules https://github.com/Sacha37420/sso-lab.git dev
cd dev
```

### Configuration initiale

Éditer **`bbox.env`** (source de vérité pour toutes les IPs) :

```env
SERVER_URL_LAN=http://192.168.1.X   # IP LAN de la machine hôte
SERVER_URL_WAN=http://X.X.X.X       # IP publique WAN
BBOX_ADMIN_PASSWORD=...             # mot de passe admin de la Bbox (si Bbox Bouygues)
```

### Lancement

```bash
bash setup.sh        # interactif (demande confirmation)
bash setup.sh --yes  # silencieux (CI)
```

Ce script enchaîne 9 étapes :

| # | Étape                  | Script                   |
|---|------------------------|--------------------------|
| 1 | Nettoyage complet      | `clean.sh`               |
| 2 | Propagation des IPs    | `reset_url.sh`           |
| 3 | Génération des secrets | `init-secrets.sh`        |
| 4 | Démarrage sso-lab      | `recompose_docker.sh`    |
| 5 | Attente Keycloak       | *(sonde + sleep 20s)*    |
| 6 | Config Keycloak        | `create-app-client.sh`   |
| 7 | Démarrage de tout      | `recompose_docker.sh`    |
| 8 | Génération ports.env   | `get-ports-list.sh`      |
| 9 | Ouverture ports Bbox   | `open-bbox-ports.sh`     |

---

## Opérations courantes

### Redémarrer une stack

```bash
bash recompose_docker.sh --app sso-lab --force
bash recompose_docker.sh --app infra --force
bash recompose_docker.sh --force          # toutes les stacks
```

### Regénérer les clients Keycloak

```bash
bash create-app-client.sh                 # toutes les apps
bash create-app-client.sh spring-app      # une seule app
bash create-app-client.sh infra --client-id pgadmin --port 5050
bash create-app-client.sh front-cadriciel --public --port 4200
```

Options disponibles : `--client-id`, `--public`, `--port`, `--redirect-path`, `--no-rotate`, `--no-wan`

### Changer l'IP du serveur

```bash
# 1. Éditer bbox.env → SERVER_URL_LAN / SERVER_URL_WAN
vim bbox.env
# 2. Propager vers tous les .env
bash reset_url.sh
# 3. Redémarrer les stacks
bash recompose_docker.sh --force
```

### Ajouter une nouvelle application

```bash
bash new-app.sh
# → assistant interactif : Spring Boot / Django / Angular (seul ou combiné)
# → crée le dossier, docker-compose.yml, .env.example, .keycloak-client-opts
```

### Remettre à zéro

```bash
bash clean.sh    # arrête tout, supprime volumes + images locales + caches
```

---

## Secrets et fichiers `.env`

Tous les `.env` sont ignorés par git. Chaque dossier contient un `.env.example` à copier :

```bash
cp sso-lab/.env.example    sso-lab/.env
cp infra/.env.example      infra/.env
cp front-cadriciel/.env.example front-cadriciel/.env
cp spring-app/.env.example spring-app/.env
cp bbox.env.example        bbox.env
```

Les mots de passe (`CHANGE_ME`) sont ensuite générés automatiquement par `init-secrets.sh`.

---

## Dépôts Git

| Repo                                                      | Contenu                  |
|-----------------------------------------------------------|--------------------------|
| [sso-lab](https://github.com/Sacha37420/sso-lab)         | Infra + scripts (ce repo)|
| [front-cadriciel](https://github.com/Sacha37420/front-cadriciel) | Angular SPA       |
| [spring-app](https://github.com/Sacha37420/spring-app)   | Spring Boot app          |

`front-cadriciel` et `spring-app` sont des **git submodules** du repo principal.

Mettre à jour les submodules :

```bash
git submodule update --remote --merge
```


---

## Structure du dossier

```
dev/
├── README.md
├── .gitignore              ← ignore tous les .env (secrets)
├── infra/                  ← PostgreSQL + pgAdmin  [restart: always]
│   ├── docker-compose.yml
│   ├── .env                ← credentials postgres + pgAdmin (non commité)
│   ├── init/
│   │   ├── 00_schemas.sql      ← CREATE SCHEMA par app  ← MODIFIER ICI
│   │   └── 01_pg_hba_trust.sh  ← trust auth pour dev (pas de mot de passe DB)
│   └── pgadmin/
│       ├── config_local.py     ← config pgAdmin (OAuth2 Keycloak)
│       └── docker-entrypoint.sh
├── sso-lab/                ← Keycloak + OpenLDAP   [restart: always]
│   ├── docker-compose.yml
│   ├── .env                ← credentials LDAP + Keycloak (non commité)
│   └── ldap/
│       └── init.ldif           ← utilisateurs et groupes LDAP
├── spring-app/             ← exemple d'app connectée aux deux infras
└── mon-app/                ← nouvelle app (même modèle)
    ├── .env                ← secrets réels       (non commité)
    ├── .env.example        ← template            (commité)
    └── docker-compose.yml
```

---

## Démarrage des infrastructures

`infra/` et `sso-lab/` utilisent `restart: always` : une fois démarrés, ils redémarrent automatiquement avec Docker. Il suffit de les lancer **une seule fois**.

```bash
cd ~/dev/sso-lab && docker compose up -d   # Keycloak + OpenLDAP
cd ~/dev/infra   && docker compose up -d   # PostgreSQL + pgAdmin
```

Ensuite, on ne manipule plus que les applications :

```bash
cd ~/dev/mon-app && docker compose up -d    # démarrer
cd ~/dev/mon-app && docker compose down     # arrêter
```

> Pour stopper l'infrastructure sans perdre les données :
> ```bash
> docker compose -f ~/dev/infra/docker-compose.yml stop
> docker compose -f ~/dev/sso-lab/docker-compose.yml stop
> ```
> `stop` suspend les containers. `down` les supprime (les volumes persistent). `down --volumes` supprime aussi les données.

---

## Référence rapide

### URLs

| Service | Navigateur | Depuis un container |
|---|---|---|
| Keycloak admin | `http://192.168.1.50:8080` | `http://keycloak:8080` sur `sso-lab_sso-net` |
| phpLDAPadmin | `http://192.168.1.50:8081` | — |
| pgAdmin | `http://192.168.1.50:5050` | — |
| PostgreSQL | non exposé | `postgres:5432` sur `dev-net` |

### Credentials

| Service | Identifiant | Mot de passe |
|---|---|---|
| Keycloak admin | `admin` | `adminpassword` |
| phpLDAPadmin | `cn=admin,dc=ssolab,dc=local` | `adminpassword` |
| pgAdmin (SSO) | compte LDAP (ex. `sacha`) | mot de passe LDAP |
| PostgreSQL | `devuser` | `devpassword` |

### Paramètres Keycloak

| Paramètre | Valeur |
|---|---|
| Realm | `ssolab` |
| Issuer URI (depuis un container) | `http://keycloak:8080/realms/ssolab` |
| Issuer URI (depuis l'hôte) | `http://192.168.1.50:8080/realms/ssolab` |

---

## Créer une nouvelle application

### Étape 1 — Déclarer le schéma PostgreSQL

La base `devdb` est partagée. Chaque app a son propre schéma pour éviter les collisions de noms de tables.

Ajouter une ligne dans [`infra/init/00_schemas.sql`](infra/init/00_schemas.sql) :

```sql
CREATE SCHEMA IF NOT EXISTS mon_app;
```

> Ce fichier s'exécute uniquement au **premier démarrage** du container postgres (volume vide).  
> Si postgres tourne déjà, créer le schéma directement :
> ```bash
> docker exec dev-postgres psql -U devuser -d devdb -c "CREATE SCHEMA IF NOT EXISTS mon_app;"
> ```

---

### Étape 2 — Créer le client Keycloak

1. Aller sur `http://192.168.1.50:8080` → `admin / adminpassword`
2. Sélectionner le realm **ssolab**
3. **Clients → Create client**
   - Client type : `OpenID Connect`
   - Client ID : `mon-app`
   - Client authentication : **ON** (mode confidentiel → génère un secret)
4. **Settings** → Valid redirect URIs : `http://192.168.1.50:8083/*`
5. **Credentials** → copier le `Client secret`

---

### Étape 3 — Créer le fichier `.env`

```bash
cp ~/dev/spring-app/.env.example ~/dev/mon-app/.env
```

Remplir `mon-app/.env` :

```dotenv
# ── Base de données ──────────────────────────────────────────────
DB_HOST=postgres
DB_PORT=5432
DB_NAME=devdb
DB_SCHEMA=mon_app          # ← nom du schéma créé à l'étape 1
DB_USER=devuser
DB_PASSWORD=devpassword

# ── SSO Keycloak ─────────────────────────────────────────────────
KEYCLOAK_CLIENT_ID=mon-app
KEYCLOAK_CLIENT_SECRET=<secret copié depuis Keycloak>
KEYCLOAK_ISSUER_URI=http://keycloak:8080/realms/ssolab
```

> Le `.env` ne doit jamais être commité. Commiter uniquement `.env.example` avec des valeurs vides.

---

### Étape 4 — `docker-compose.yml`

Déclarer les deux réseaux infra comme **externes** et y rattacher le service :

```yaml
# mon-app/docker-compose.yml

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net   # ← réseau créé par sso-lab/docker-compose.yml
  dev-net:
    external: true
    name: dev-net            # ← réseau créé par infra/docker-compose.yml

services:
  mon-app:
    build: .
    container_name: mon-app
    restart: unless-stopped
    env_file: .env
    ports:
      - "8083:8083"
    networks:
      - sso-net   # ← pour joindre keycloak:8080
      - dev-net   # ← pour joindre postgres:5432
```

> Retirer `sso-net` si l'app n'a pas de SSO, `dev-net` si elle n'a pas de base de données.

---

### Étape 5 — `application.yml` (Spring Boot)

```yaml
server:
  port: 8083

spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST:postgres}:${DB_PORT:5432}/${DB_NAME:devdb}?currentSchema=${DB_SCHEMA:mon_app}
    username: ${DB_USER:devuser}
    password: ${DB_PASSWORD:devpassword}
    driver-class-name: org.postgresql.Driver

  jpa:
    hibernate:
      ddl-auto: update
    properties:
      hibernate:
        default_schema: ${DB_SCHEMA:mon_app}

  security:
    oauth2:
      client:
        registration:
          keycloak:
            client-id: ${KEYCLOAK_CLIENT_ID:mon-app}
            client-secret: ${KEYCLOAK_CLIENT_SECRET}
            scope: openid, profile, email
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/{registrationId}"
        provider:
          keycloak:
            issuer-uri: ${KEYCLOAK_ISSUER_URI:http://keycloak:8080/realms/ssolab}
            user-name-attribute: preferred_username
```

> La syntaxe `${VAR:valeur_par_défaut}` permet de lancer l'app hors Docker (en local) sans définir les variables d'environnement.

---

### Étape 6 — `pom.xml`

```xml
<!-- Base de données -->
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
    <scope>runtime</scope>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
</dependency>

<!-- SSO -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-client</artifactId>
</dependency>
```

---

### Étape 7 — SecurityConfig (Spring Boot)

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    private final ClientRegistrationRepository clientRegistrationRepository;

    public SecurityConfig(ClientRegistrationRepository clientRegistrationRepository) {
        this.clientRegistrationRepository = clientRegistrationRepository;
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/", "/error").permitAll()
                .anyRequest().authenticated()
            )
            .oauth2Login(Customizer.withDefaults())
            .logout(logout -> logout
                .logoutSuccessHandler(oidcLogoutHandler())
            );
        return http.build();
    }

    private LogoutSuccessHandler oidcLogoutHandler() {
        OidcClientInitiatedLogoutSuccessHandler handler =
            new OidcClientInitiatedLogoutSuccessHandler(clientRegistrationRepository);
        handler.setPostLogoutRedirectUri("{baseUrl}");
        return handler;
    }
}
```

Le login SSO est déclenché en redirigeant l'utilisateur vers :

```
GET /oauth2/authorization/keycloak
```

---

## Isolation réseau — récapitulatif

```
  ┌─────────────── sso-lab_sso-net ──────────────────┐
  │  openldap:389   phpldapadmin   keycloak:8080      │
  │                                     ▲             │
  └─────────────────────────────────────┼─────────────┘
                                        │ OAuth2/OIDC
                                    mon-app
                                        │ JDBC
  ┌───────────────── dev-net ───────────┼─────────────┐
  │  postgres:5432  (port non exposé)   ▼             │
  └────────────────────────────────────────────────────┘
```

