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
uvicorn.run(build(cfg), host="0.0.0.0", port=8000, log_level="warning", access_log=False)
