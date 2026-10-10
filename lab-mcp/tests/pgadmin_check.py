"""Ce que contient et accepte un pgAdmin par dev, vu par son API (bibliothèque standard).
   python pgadmin_check.py <base, ex. http://127.0.0.1:8901/pg/mcpdev> <cookie de session du lab> <fichier du mot de passe>"""
import http.cookiejar, json, re, sys, urllib.error, urllib.request

base, lab_cookie, pw_file = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
password = open(pw_file).read().strip()
cookies = dict([lab_cookie.split("=", 1)])   # cookie du lab + ceux que pgAdmin pose, dans UN en-tête
op = urllib.request.build_opener()


def call(method, path, data=None, token=None):
    req = urllib.request.Request(base + path, method=method, data=json.dumps(data).encode() if data is not None else None)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("X-pgA-CSRFToken", token)
    req.add_header("Cookie", "; ".join(f"{k}={v}" for k, v in cookies.items()))
    try:
        r = op.open(req, timeout=40)
    except urllib.error.HTTPError as e:
        r = e
    for line in r.headers.get_all("Set-Cookie") or []:
        k, v = line.split(";", 1)[0].split("=", 1)
        cookies[k.strip()] = v
    return r.status if hasattr(r, "status") else r.code, r.read().decode("utf-8", "replace")


st, page = call("GET", "/browser/")
login = "login" in page.lower() and "password" in page.lower() and "csrf" not in page.lower()
print("page du navigateur d'objets :", st, "| écran de connexion :", "OUI" if "/login" in page[:3000] else "non")
st, js = call("GET", "/browser/js/utils.js")
m = re.search(r"csrf_token'\]\s*=\s*'([^']+)'", js)
token = m.group(1) if m else None
print("jeton CSRF de pgAdmin :", "obtenu" if token else "INTROUVABLE")
st, body = call("GET", "/browser/server_group/nodes/", token=token)
def items(text):
    j = json.loads(text)
    return j.get("data") or j.get("result") or []


groups = items(body) if st == 200 else []
gid = next((g["_id"] for g in groups if g.get("label") == "Lab"), groups[0]["_id"] if groups else 1)
st, body = call("GET", f"/browser/server/nodes/{gid}/", token=token)
servers = items(body) if st == 200 else []
for s in servers:
    print("serveur préenregistré :", s["label"], "| connecté :", s.get("connected"), "| utilisateur :", (s.get("user") or {}).get("name") or s.get("username"))
if not servers:
    print("AUCUN serveur", st, body[:200]); sys.exit(1)
sid = servers[0]["_id"]
st, body = call("GET", f"/browser/server/obj/{gid}/{sid}", token=token)
obj = json.loads(body) if st == 200 else {}
print("fiche :", {k: obj.get(k) for k in ("host", "port", "db", "username", "save_password", "passexec_cmd", "passfile")})
st, body = call("POST", f"/browser/server/connect/{gid}/{sid}", data={}, token=token)
print("connexion SANS mot de passe :", st, re.sub(r"\s+", " ", body)[:90])
st, body = call("POST", f"/browser/server/connect/{gid}/{sid}", data={"password": "mauvais-mot-de-passe"}, token=token)
print("connexion, MAUVAIS mot de passe :", st, re.sub(r"\s+", " ", body)[:110])
st, body = call("POST", f"/browser/server/connect/{gid}/{sid}", data={"password": password, "save_password": True}, token=token)
print("connexion, BON mot de passe (en demandant de l'enregistrer) :", st, "| connecté :", json.loads(body).get("data", {}).get("connected") if st == 200 else body[:120])
st, body = call("GET", f"/browser/database/nodes/{gid}/{sid}/", token=token)
print("bases visibles :", sorted(d["label"] for d in items(body)) if st == 200 else (st, body[:120]))
st, body = call("GET", f"/browser/server/obj/{gid}/{sid}", token=token)
obj = json.loads(body) if st == 200 else {}
print("après connexion — mot de passe enregistré :", obj.get("save_password"))
