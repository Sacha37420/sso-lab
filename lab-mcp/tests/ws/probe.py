"""Sonde lancée DANS un espace de travail : que peut-il joindre ?
   python probe.py tcp <hôte> <port> [...]   |   python probe.py https <url>"""
import socket, ssl, sys, urllib.request

mode = sys.argv[1]
if mode == "tcp":
    args = sys.argv[2:]
    for host, port in zip(args[0::2], args[1::2]):
        try:
            socket.create_connection((host, int(port)), timeout=3).close()
            print(f"  {host}:{port} JOIGNABLE")
        except Exception as e:
            print(f"  {host}:{port} injoignable ({type(e).__name__})")
else:
    for url in sys.argv[2:]:
        try:
            with urllib.request.urlopen(url, timeout=8, context=ssl.create_default_context()) as r:
                print(f"  {url} → HTTP {r.status}")
        except urllib.error.HTTPError as e:
            print(f"  {url} → HTTP {e.code}")
        except Exception as e:
            print(f"  {url} → ÉCHEC ({type(e).__name__}: {str(e)[:80]})")
