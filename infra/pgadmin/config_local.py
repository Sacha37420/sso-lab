# ─────────────────────────────────────────────────────────────────
# config_local.py — Configuration pgAdmin (SSO via Keycloak)
# ─────────────────────────────────────────────────────────────────
import os

# SSO Keycloak uniquement
AUTHENTICATION_SOURCES = ['oauth2']

MASTER_PASSWORD_REQUIRED = False
ALLOW_SPECIAL_EMAIL_DOMAINS = ['local']

OAUTH2_CONFIG = [
    {
        'OAUTH2_NAME'            : 'keycloak',
        'OAUTH2_DISPLAY_NAME'    : 'SSO Lab (Keycloak)',
        'OAUTH2_CLIENT_ID'       : os.environ['KEYCLOAK_CLIENT_ID'],
        'OAUTH2_CLIENT_SECRET'   : os.environ['KEYCLOAK_CLIENT_SECRET'],

        # URL appelée par le NAVIGATEUR
        'OAUTH2_AUTHORIZATION_URL'  : os.environ.get('KEYCLOAK_PUBLIC_URL', 'http://localhost:8080') + '/realms/ssolab/protocol/openid-connect/auth',

        # URLs appelées par le SERVEUR pgAdmin (résolution Docker interne)
        'OAUTH2_TOKEN_URL'          : 'http://keycloak:8080/realms/ssolab/protocol/openid-connect/token',
        'OAUTH2_API_BASE_URL'       : 'http://keycloak:8080/realms/ssolab/protocol/openid-connect/',
        'OAUTH2_USERINFO_ENDPOINT'  : 'http://keycloak:8080/realms/ssolab/protocol/openid-connect/userinfo',
        'OAUTH2_SERVER_METADATA_URL': 'http://keycloak:8080/realms/ssolab/.well-known/openid-configuration',

        'OAUTH2_USERNAME_CLAIM'  : 'preferred_username',
        'OAUTH2_EMAIL_CLAIM'     : 'email',
        'OAUTH2_SCOPE'           : 'openid email profile',

        # Restreint l'accès aux membres du groupe LDAP 'developers'.
        # pgAdmin vérifie que 'developers' est présent dans le claim 'groups'
        # (le mapper Keycloak injecte les groupes sans slash : ["developers", …])
        'OAUTH2_ADDITIONAL_CLAIMS': {'groups': 'developers'},

        'OAUTH2_ICON'            : 'fa-lock',
        'OAUTH2_BUTTON_COLOR'    : '#2db1ff',
    }
]


