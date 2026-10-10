"""Client WebSocket minimal (bibliothèque standard) : poignée de main + une trame.
   python ws_client.py <hôte> <port> <chemin> [cookie]  → « 101 <écho> » ou « <code HTTP> »
   Variables : WS_HOST (en-tête Host), WS_ORIGIN (en-tête Origin), WS_HOLD (secondes à tenir la
   connexion ouverte sans rien envoyer, puis dit si elle est toujours là)."""
import base64, os, select, socket, sys, time

host, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cookie = sys.argv[4] if len(sys.argv) > 4 else ""
s = socket.create_connection((host, port), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
vhost = os.environ.get("WS_HOST") or f"{host}:{port}"
origin = os.environ.get("WS_ORIGIN", "")
req = (f"GET {path} HTTP/1.1\r\nHost: {vhost}\r\n" + (f"Origin: {origin}\r\n" if origin else "") + f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n" + (f"Cookie: {cookie}\r\n" if cookie else "") + "\r\n")
s.sendall(req.encode())
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode().split(" ")[1]
if status != "101":
    print(status)
    sys.exit(0)
hold = float(os.environ.get("WS_HOLD", "0"))
if hold:
    end = time.time() + hold
    alive = True
    while time.time() < end and alive:
        r, _, _ = select.select([s], [], [], min(5, end - time.time()))
        if r and s.recv(4096) == b"":
            alive = False
    print("101", f"tenue {hold:.0f} s :", "toujours ouverte" if alive else "FERMÉE par le serveur")
    sys.exit(0)
if os.environ.get("WS_NOECHO"):
    print("101")
    sys.exit(0)
msg = b"bonjour"
mask = os.urandom(4)
s.sendall(bytes([0x81, 0x80 | len(msg)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(msg)))
rest = buf.split(b"\r\n\r\n", 1)[1]
while len(rest) < 2 or len(rest) < 2 + rest[1]:
    rest += s.recv(4096)
print("101", rest[2:2 + rest[1]].decode())
