"""
Settings pour __APP_TITLE__.
Les variables sensibles sont lues depuis le fichier .env via python-decouple.
"""
from decouple import config

# ── Sécurité ──────────────────────────────────────────────────────────────────
SECRET_KEY = config('SECRET_KEY', default='django-insecure-__APP_SLUG__-change-in-production')
DEBUG = config('DEBUG', default=False, cast=bool)
ALLOWED_HOSTS = config('ALLOWED_HOSTS', default='*').split(',')

# ── Applications ──────────────────────────────────────────────────────────────
INSTALLED_APPS = [
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'rest_framework',
    'drf_spectacular',
    'api',
]

# ── Middleware ─────────────────────────────────────────────────────────────────
MIDDLEWARE = [
    'django.middleware.common.CommonMiddleware',
]

ROOT_URLCONF = 'config.urls'
WSGI_APPLICATION = 'config.wsgi.application'

# ── Base de données ────────────────────────────────────────────────────────────
_DB_SCHEMA = config('DB_SCHEMA', default='__APP_SLUG__')

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'HOST':     config('DB_HOST',     default='postgres'),
        'PORT':     config('DB_PORT',     default=5432, cast=int),
        'NAME':     config('DB_NAME',     default='devdb'),
        'USER':     config('DB_USER',     default='devuser'),
        'PASSWORD': config('DB_PASSWORD', default='devpassword'),
        'OPTIONS': {
            # Isole les tables dans le schéma dédié à cette application.
            'options': f'-c search_path={_DB_SCHEMA},public',
        },
    }
}

DB_SCHEMA = _DB_SCHEMA
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
USE_TZ = True

# ── Django REST Framework ──────────────────────────────────────────────────────
REST_FRAMEWORK = {
    'DEFAULT_SCHEMA_CLASS': 'drf_spectacular.openapi.AutoSchema',
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'api.authentication.KeycloakJWTAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
}

SPECTACULAR_SETTINGS = {
    'TITLE': '__APP_TITLE__ API',
    'DESCRIPTION': 'Documentation interactive OpenAPI/Swagger',
    'VERSION': '1.0.0',
    'SERVE_INCLUDE_SCHEMA': False,
    'SECURITY': [{'BearerAuth': []}],
    'COMPONENTS': {
        'securitySchemes': {
            'BearerAuth': {
                'type': 'openIdConnect',
                'openIdConnectUrl': f'{KEYCLOAK_ISSUER_URI}/.well-known/openid-configuration',
            }
        }
    },
}

# ── Keycloak ───────────────────────────────────────────────────────────────────
KEYCLOAK_ISSUER_URI = config(
    'KEYCLOAK_ISSUER_URI',
    default='http://keycloak:8080/realms/ssolab',
)
