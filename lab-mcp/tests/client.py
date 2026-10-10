"""Clients de test des DEUX entrées du moteur.

  MCP (client officiel du SDK, Streamable HTTP) :
    python /tests/client.py --domain D --uid devtest mcp <outil> ['{"arg": …}']
    python /tests/client.py --domain D --token-file F mcp <outil> […]        jeton réel ou jeton d'espace
    python /tests/client.py --domain D --uid devtest mcp --list
  Web :
    python /tests/client.py --domain D --uid devtest web GET /me
    python /tests/client.py --domain D --uid devtest web POST /projects/x/sql '{"query": "select 1"}'

`--uid` forge un jeton signé par la clé de TEST du harnais (azp = lab-mcp pour
`mcp`, lab-admin pour `web` ; `--claims` surcharge). Sortie : `OK <json>` ou
`ERREUR <statut> <json>` — la même forme pour les deux entrées, ce qui permet de
les comparer ligne à ligne (tests/compare.py).
"""
import argparse
import asyncio
import json
import sys
import time

import httpx
import jwt
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def mint(uid: str, domain: str, azp: str, **over) -> str:
    claims = {"iss": f"https://{domain}/auth/realms/ssolab", "exp": int(time.time()) + 300, "typ": "Bearer",
              "azp": azp, "preferred_username": uid, "email": f"{uid}@ssolab.local", "groups": ["developers"]}
    claims.update(over)
    return jwt.encode(claims, open("/tmp/test-issuer-key.pem").read(), algorithm="RS256")


async def mcp_call(base: str, token: str, tool: str | None, args: dict) -> tuple[int, object]:
    headers = {"Authorization": f"Bearer {token}"}
    # Un refus d'authentification est une réponse HTTP, que le client MCP rendrait en exception opaque.
    probe = httpx.post(base + "/mcp", headers={**headers, "Accept": "application/json, text/event-stream"},
                       json={"jsonrpc": "2.0", "id": 0, "method": "ping"}, timeout=20)
    if probe.status_code in (401, 403):
        return probe.status_code, probe.json()
    async with streamablehttp_client(base + "/mcp", headers=headers, timeout=1500, sse_read_timeout=1500) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            if tool is None:
                return 200, sorted(t.name for t in (await s.list_tools()).tools)
            res = await s.call_tool(tool, args)
            text = "\n".join(c.text for c in res.content if getattr(c, "type", "") == "text")
            if res.isError:
                raw = text.split(": ", 1)[1] if text.startswith("Error executing tool") else text
                try:
                    return -1, json.loads(raw)
                except ValueError:
                    return -1, {"error": "(non structuré)", "detail": text}
            return 200, json.loads(text)


def web_call(base: str, token: str, method: str, path: str, body: dict | None) -> tuple[int, object]:
    r = httpx.request(method, base + "/mcp/api" + path, headers={"Authorization": f"Bearer {token}"},
                      json=body if body is not None else None, timeout=120)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {"brut": r.text[:200]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid")
    ap.add_argument("--token-file")
    ap.add_argument("--claims", default="{}")
    ap.add_argument("--base", default="http://127.0.0.1:8000")
    ap.add_argument("--domain", required=True)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("entry", choices=["mcp", "web"])
    ap.add_argument("rest", nargs="*")
    a = ap.parse_args()
    azp = "lab-mcp" if a.entry == "mcp" else "lab-admin"
    token = (open(a.token_file).read().strip() if a.token_file
             else mint(a.uid, a.domain, **{"azp": azp, **json.loads(a.claims)}))
    if a.entry == "mcp":
        tool = None if a.list else a.rest[0]
        args = json.loads(a.rest[1]) if len(a.rest) > 1 else {}
        status, data = asyncio.run(mcp_call(a.base, token, tool, args))
    else:
        method, path = a.rest[0], a.rest[1]
        body = json.loads(a.rest[2]) if len(a.rest) > 2 else None
        status, data = web_call(a.base, token, method, path, body)
    ok = status == 200
    print(("OK " if ok else f"ERREUR {status} ") + json.dumps(data, ensure_ascii=False))
    return 0 if ok else 1


sys.exit(main())
