"""Serveur de TEST : le serveur livré, avec une identité de test.

Lancé à la place de la commande de l'image, dans le conteneur jetable
`lab-mcp-test` (tests/ y est monté ; il n'est PAS dans l'image) :

    docker run --rm --name lab-mcp-test … -v …/lab-mcp/tests:/tests:ro lab-mcp:test python /tests/harness.py

Ce que ça change par rapport au serveur en service — et rien d'autre :
  • la CLÉ de vérification des jetons est une clé RSA générée ici, au lieu des
    clés du realm. Tout le reste de l'authentification tourne tel quel
    (signature, expiration, émetteur, `typ`, `azp == lab-mcp`, `.devs`) ;
  • oauth-hub et l'API GitHub sont les doubles de tests/doubles.py.

Le code livré (labmcp/) n'a AUCUN mode « identité forcée » : ni variable
d'environnement, ni option. L'ancre de confiance n'y est pas configurable
(labmcp/config.py). Le remplacement se fait ici, par programme, depuis un
fichier qui n'existe pas dans l'image.
"""
import logging
import sys

import uvicorn
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, "/tests")
import doubles  # noqa: E402

from labmcp import auth, config  # noqa: E402
from labmcp.server import build  # noqa: E402

KEY_FILE = "/tmp/test-issuer-key.pem"

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
with open(KEY_FILE, "wb") as fh:
    fh.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                               serialization.NoEncryption()))


class _TestKeys:
    """Tient lieu de PyJWKClient : rend la clé publique de test."""

    class _K:
        key = key.public_key()

    def get_signing_key_from_jwt(self, _token):
        return self._K


_orig_init = auth.Authenticator.__init__


def _patched_init(self, *args, **kwargs):
    _orig_init(self, *args, **kwargs)
    self._jwks = _TestKeys()


auth.Authenticator.__init__ = _patched_init

logging.basicConfig(level=logging.INFO, stream=sys.stdout, format="%(message)s")
logging.getLogger("httpx").setLevel(logging.WARNING)
doubles.start()
cfg = config.load()
print(f"[harness] SERVEUR DE TEST — clé de test, doubles oauth-hub/GitHub — racine {cfg.root}", flush=True)
import asyncio  # noqa: E402
import os  # noqa: E402

from labmcp import engine as engine_module  # noqa: E402

if os.environ.get("TEST_PG_LOCKED") == "1":
    # ESSAI de l'ouverture réelle d'un pgAdmin contre une instance PostgreSQL JETABLE sans
    # « trust » (le relais de test pointe vers elle). Le garde-fou réel lit les instances du lab,
    # qui sont encore en « trust » : il est remplacé ICI, pas dans le code livré.
    async def _locked(self):
        return True
    engine_module.Engine._pg_locked = _locked
    print("[harness] garde-fou pg_trust remplacé : instance PostgreSQL de test", flush=True)

if os.environ.get("TEST_REMOTE_DOUBLE"):
    # Double LOCAL de scripts/app-remote.sh (I4 v8), tant que la fondation ne l'a pas livré : rend,
    # par projet, la ligne JSON contractuelle lue dans un fichier que le test réécrit.
    import json  # noqa: E402

    async def _remote_raw(self, app):
        with open("/tmp/remote-calls.log", "a") as fh:
            fh.write(app + "\n")
        await asyncio.sleep(float(os.environ.get("TEST_REMOTE_DELAY", "0")))
        try:
            return json.load(open(os.environ["TEST_REMOTE_DOUBLE"])).get(app)
        except (OSError, ValueError):
            return None
    engine_module.Engine._remote_raw = _remote_raw
    print("[harness] app-remote.sh remplacé par un double local", flush=True)

app = build(cfg)
if os.environ.get("TEST_WS_TOKEN_FOR"):
    # Jeton d'espace injecté pour (uid, app) SANS conteneur : sert à éprouver ce qu'un jeton
    # d'espace voit et peut appeler quand aucune app jetable ne peut être créée.
    import secrets as _secrets  # noqa: E402
    from labmcp.access import digest as _digest  # noqa: E402
    from labmcp.workspaces import Workspace as _Workspace  # noqa: E402
    _uid, _app = os.environ["TEST_WS_TOKEN_FOR"].split(":")
    _tok = "labws_" + _secrets.token_urlsafe(32)
    app.engine.ws._ws[_uid] = _Workspace(uid=_uid, app=_app, token_hash=_digest(_tok), opened_by=_uid, with_github=False)
    _fd = os.open("/tmp/tok_ws", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(_fd, _tok.encode()); os.close(_fd)
    print(f"[harness] jeton d'espace de test injecté pour {_uid}:{_app}", flush=True)
asyncio.run(app.engine.startup())
uvicorn.run(app, host="0.0.0.0", port=8000, log_level="warning", access_log=False)
