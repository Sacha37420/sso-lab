"""Serveur SMTP JETABLE pour les essais de l'email d'essai (bibliothèque standard).

  2525  accepte, AUTH exigé (utilisateur « bon », mot de passe lu dans SMTP_TEST_PASSWORD)
  2526  STARTTLS, puis refuse toute authentification (535)
  2527  muet : accepte la connexion TCP et ne dit jamais rien
  2587  STARTTLS obligatoire avant AUTH, puis comme 2525
  2465  TLS implicite, puis comme 2525
  2528  accepte SANS authentification (profil « none »)
  2529  sans authentification, refuse le destinataire (550)

Chaque message accepté est noté dans /tmp/mails.log (expéditeur, destinataires, sujet) ; chaque
ligne reçue du client dans /tmp/smtp-wire.log, sauf ce qui suit AUTH (jamais le secret au journal).
"""
import base64, os, socketserver, ssl, threading, time

PASSWORD = os.environ.get("SMTP_TEST_PASSWORD", "")
CERT, KEY = "/tmp/smtp.crt", "/tmp/smtp.key"


def make(port, *, tls=None, auth="required", rcpt_ok=True, mute=False):
    class H(socketserver.StreamRequestHandler):
        def say(self, line):
            self.wfile.write((line + "\r\n").encode()); self.wfile.flush()

        def handle(self):
            if tls == "implicit":
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT, KEY)
                self.connection = ctx.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile("rb"); self.wfile = self.connection.makefile("wb")
            if mute:
                time.sleep(120); return
            self.say("220 smtp-test-server ESMTP essai")
            authed, secure, sender, rcpts = auth == "none", tls != "starttls", "", []
            while True:
                raw = self.rfile.readline()
                if not raw:
                    return
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                with open("/tmp/smtp-wire.log", "a") as fh:
                    fh.write(f"{port} " + (line.split(" ", 2)[0] + " " + line.split(" ", 2)[1] + " <masqué>" if line.upper().startswith("AUTH ") and len(line.split(" ")) > 2 else line)[:120] + "\n")
                up = line.upper()
                if up.startswith("EHLO"):
                    caps = ["250-smtp-test-server"]
                    if tls == "starttls" and not secure:
                        caps.append("250-STARTTLS")
                    if auth != "none" and secure:
                        caps.append("250-AUTH PLAIN")
                    caps.append("250 SIZE 1000000")
                    for c in caps:
                        self.say(c)
                elif up == "STARTTLS" and tls == "starttls":
                    self.say("220 Go ahead")
                    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT, KEY)
                    self.connection = ctx.wrap_socket(self.connection, server_side=True)
                    self.rfile = self.connection.makefile("rb"); self.wfile = self.connection.makefile("wb")
                    secure = True
                elif up.startswith("AUTH PLAIN"):
                    try:
                        _, user, pw = base64.b64decode(line.split(" ", 2)[2]).decode().split("\0")
                    except Exception:
                        user = pw = ""
                    if auth == "refuse" or user != "bon" or pw != PASSWORD:
                        # Un serveur réel ne répète pas le secret ; celui-ci le fait EXPRÈS, pour
                        # vérifier que le moteur l'efface du détail rendu.
                        self.say(f"535 5.7.8 Authentication failed for {user} (reçu : {line.split(' ', 2)[2]} / {pw})")
                    else:
                        authed = True; self.say("235 2.7.0 Authentication successful")
                elif up.startswith("MAIL FROM"):
                    if not authed:
                        self.say("530 5.7.0 Authentication required")
                    else:
                        sender = line.split(":", 1)[1].strip(); self.say("250 OK")
                elif up.startswith("RCPT TO"):
                    if rcpt_ok:
                        rcpts.append(line.split(":", 1)[1].strip()); self.say("250 OK")
                    else:
                        self.say("550 5.1.1 Mailbox unavailable")
                elif up == "DATA":
                    self.say("354 End data with <CR><LF>.<CR><LF>")
                    subject = ""
                    while True:
                        d = self.rfile.readline().decode("utf-8", "replace").rstrip("\r\n")
                        if d == ".":
                            break
                        if d.lower().startswith("subject:"):
                            subject = d
                    with open("/tmp/mails.log", "a") as fh:
                        fh.write(f"port={port} de={sender} à={rcpts} {subject}\n")
                    self.say("250 2.0.0 OK queued")
                elif up == "QUIT":
                    self.say("221 Bye"); return
                elif up == "RSET":
                    self.say("250 OK")
                else:
                    self.say("502 5.5.2 Command not recognized")

    class S(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    threading.Thread(target=S(("0.0.0.0", port), H).serve_forever, daemon=True).start()


make(2525); make(2526, tls="starttls", auth="refuse"); make(2527, mute=True); make(2587, tls="starttls")
make(2465, tls="implicit"); make(2528, auth="none"); make(2529, auth="none", rcpt_ok=False)
print("serveur SMTP de test prêt", flush=True)
threading.Event().wait()
