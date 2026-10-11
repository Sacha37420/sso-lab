"""Les deux entrées rendent-elles la même chose ? (contrat I5 : « aucune logique d'un seul côté »)

Appelle chaque opération par la route web ET par l'outil MCP, avec le même
appelant, et compare les objets rendus — succès comme erreurs. À lancer dans le
conteneur du harnais :   python /tests/compare.py <domaine> <uid> <app> [<job_id>]
"""
import asyncio
import json
import sys

sys.argv = [sys.argv[0]] + sys.argv[1:]
sys.path.insert(0, "/tests")
import importlib.util

spec = importlib.util.spec_from_file_location("client", "/tests/client.py")
src = open("/tests/client.py").read().replace("sys.exit(main())", "")
client = type(sys)("client")
exec(compile(src, "/tests/client.py", "exec"), client.__dict__)

domain, uid, app = sys.argv[1], sys.argv[2], sys.argv[3]
job = sys.argv[4] if len(sys.argv) > 4 else "0" * 16
BASE = "http://127.0.0.1:8000"
VOLATILE = {"last_activity"}


def norm(x):
    if isinstance(x, dict):
        return {k: norm(v) for k, v in x.items() if k not in VOLATILE}
    if isinstance(x, list):
        return [norm(v) for v in x]
    return x


PAIRS = [
    ("me", ("GET", "/me", None), ("whoami", {})),
    ("projects", ("GET", "/projects", None), ("list_apps", {})),
    ("check_name (refusé)", ("POST", "/projects/check-name", {"name": "lora"}), ("check_name", {"name": "lora"})),
    ("check_name (libre)", ("POST", "/projects/check-name", {"name": "zzzlibre"}), ("check_name", {"name": "zzzlibre"})),
    ("project", ("GET", f"/projects/{app}", None), ("status", {"app": app})),
    ("logs", ("GET", f"/projects/{app}/logs?tail=5", None), ("logs", {"app": app, "tail": 5})),
    ("logs (tail invalide)", ("GET", f"/projects/{app}/logs?tail=9999", None), ("logs", {"app": app, "tail": 9999})),
    ("env_set", ("PUT", f"/projects/{app}/env/CMP_CLE", {"value": "a b"}), ("env_set", {"app": app, "key": "CMP_CLE", "value": "a b"})),
    ("env_set (clé gérée)", ("PUT", f"/projects/{app}/env/DB_NAME", {"value": "x"}), ("env_set", {"app": app, "key": "DB_NAME", "value": "x"})),
    ("env_list", ("GET", f"/projects/{app}/env", None), ("env_list", {"app": app})),
    ("env_get", ("GET", f"/projects/{app}/env/CMP_CLE", None), ("env_get", {"app": app, "key": "CMP_CLE"})),
    ("env_get (clé gérée)", ("GET", f"/projects/{app}/env/DB_PASSWORD", None), ("env_get", {"app": app, "key": "DB_PASSWORD"})),
    ("env_unset", ("DELETE", f"/projects/{app}/env/CMP_AUTRE", None), ("env_unset", {"app": app, "key": "CMP_AUTRE"})),
    ("sql", ("POST", f"/projects/{app}/sql", {"query": "select 1 as un, current_user"}), ("sql", {"app": app, "query": "select 1 as un, current_user"})),
    ("sql (erreur)", ("POST", f"/projects/{app}/sql", {"query": "select * from pg_authid"}), ("sql", {"app": app, "query": "select * from pg_authid"})),
    ("projet d'un autre", ("GET", "/projects/storage", None), ("status", {"app": "storage"})),
    ("sql, projet d'un autre", ("POST", "/projects/storage/sql", {"query": "select 1"}), ("sql", {"app": "storage", "query": "select 1"})),
    ("deploy (sha invalide)", ("POST", f"/projects/{app}/deploy", {"sha": "main"}), ("deploy", {"app": app, "sha": "main"})),
    ("create (nom refusé)", ("POST", "/projects", {"name": "lora", "type": "django", "required_groups": ["developers"]}),
     ("create_app", {"name": "lora", "type": "django", "required_groups": ["developers"]})),
    ("create (groupe inconnu)", ("POST", "/projects", {"name": "zzzlibre", "type": "django", "required_groups": ["nexistepas"]}),
     ("create_app", {"name": "zzzlibre", "type": "django", "required_groups": ["nexistepas"]})),
    ("job", ("GET", f"/jobs/{job}?tail=3", None), ("job_status", {"job_id": job, "tail": 3})),
    ("job inconnu", ("GET", "/jobs/ffffffffffffffff", None), ("job_status", {"job_id": "ffffffffffffffff"})),
    ("ticket (scope lab)", ("POST", f"/projects/{app}/tickets", {"title": "t", "body": "b", "scope": "lab"}),
     ("open_ticket", {"app": app, "title": "t", "body": "b", "scope": "lab"})),
    ("ticket (titre vide)", ("POST", f"/projects/{app}/tickets", {"title": " ", "body": "b"}),
     ("open_ticket", {"app": app, "title": " ", "body": "b"})),
]

same = 0
for label, (method, path, body), (tool, args) in PAIRS:
    ws, wd = client.web_call(BASE, client.mint(uid, domain, "lab-admin"), method, path, body)
    ms, md = asyncio.run(client.mcp_call(BASE, client.mint(uid, domain, "lab-mcp"), tool, args))
    equal = norm(wd) == norm(md) and (ws == 200) == (ms == 200)
    same += equal
    kind = "succès" if ws == 200 else f"erreur {ws} {wd.get('error') if isinstance(wd, dict) else ''}"
    print(f"{'IDENTIQUE' if equal else 'DIFFÉRENT'}  {label:28s} {kind}")
    if not equal:
        print("   web :", json.dumps(wd, ensure_ascii=False)[:300])
        print("   mcp :", json.dumps(md, ensure_ascii=False)[:300])
print(f"{same}/{len(PAIRS)} opérations rendent le même objet par les deux entrées")
