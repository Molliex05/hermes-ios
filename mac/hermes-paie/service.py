"""Service « paie » du Mac mini, réveillé par launchd à chaque appel (inetd : la connexion arrive sur l'entrée standard).

Rien ne tourne entre deux appels. Une seule requête par connexion, puis le processus se termine.
Accepté seulement :
- arrivé par l'adresse Tailscale du Mac (ou en local pour les essais) ;
- venant du serveur noriven-vps (ou du Mac lui-même) ;
- avec le jeton du trousseau (service « hermes-paie-service »).

Routes :
  GET  /etat                  ce qui est classé et ce qui manque (sans se connecter à MaPaie.net)
  POST /synchroniser          range dans iCloud les talons publiés qui manquent
  GET  /talon/AAAA-MM-JJ      le PDF d'un talon classé (par sa date seulement : aucun chemin de fichier n'est accepté)
  GET  /texte/AAAA-MM-JJ      son texte, colonnes alignées (pdftotext -layout)
"""
from __future__ import annotations

import datetime as dt
import hmac
import json
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paie  # noqa: E402

MAC_TAILSCALE = "100.110.134.51"
SERVER_TAILSCALE = "100.106.8.32"
LOCAL = "127.0.0.1"
TOKEN_SERVICE = "hermes-paie-service"
LOG = Path.home() / "Library/Logs/hermes-paie.log"


def log(line: str) -> None:
    """Une ligne par appel : route, réponse, durée. Jamais de jeton, de montant ni de contenu de talon."""
    try:
        with LOG.open("a") as out:
            out.write(f"{dt.datetime.now().isoformat(timespec='seconds')} {line}\n")
    except OSError:
        pass


def token() -> str:
    result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", TOKEN_SERVICE, "-w"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def allowed(peer: str, local: str) -> bool:
    return (local == MAC_TAILSCALE and peer == SERVER_TAILSCALE) or (local == LOCAL and peer == LOCAL)


def respond(method: str, path: str, headers: dict, peer: str, local: str, expected_token: str):
    """(statut, type, corps) d'une requête. Séparé du réseau pour les tests."""
    def answer(status: int, body: dict):
        return status, "application/json; charset=utf-8", json.dumps(body, ensure_ascii=False).encode()

    if not allowed(peer, local):
        return answer(403, {"ok": False, "erreur": "Origine refusée."})
    given = headers.get("authorization", "")
    if not expected_token or not hmac.compare_digest(given.encode(), f"Bearer {expected_token}".encode()):
        return answer(401, {"ok": False, "erreur": "Jeton refusé."})
    try:
        if method == "GET" and path == "/etat":
            return answer(200, paie.status())
        if method == "POST" and path == "/synchroniser":
            return answer(200, paie.synchronize())
        match = re.fullmatch(r"/(talon|texte)/(\d{4}-\d{2}-\d{2})", path)
        if method == "GET" and match:
            try:
                day = dt.date.fromisoformat(match.group(2))
            except ValueError:
                return answer(400, {"ok": False, "erreur": "Date invalide."})
            if match.group(1) == "texte":
                return answer(200, {"ok": True, "date": day.isoformat(), "texte": paie.read_text(paie.ROOT, day)})
            return 200, "application/pdf", paie.read(paie.ROOT, day)
        return answer(404, {"ok": False, "erreur": "Route inconnue."})
    except paie.PaieError as error:
        return answer(502 if isinstance(error, paie.LoginRefused) else 409, {"ok": False, "erreur": str(error)})
    except Exception as error:
        return answer(500, {"ok": False, "erreur": f"Erreur inattendue sur le Mac ({type(error).__name__})."})


def main() -> None:
    # Filet : un appel ne vit jamais plus de 3 minutes (une invite de macOS restée sans réponse, un site qui traîne).
    signal.alarm(180)
    started = time.monotonic()
    connection = socket.socket(fileno=0)
    connection.settimeout(20)
    peer, local = connection.getpeername()[0], connection.getsockname()[0]
    method = path = "?"
    try:
        reader = connection.makefile("rb")
        request = reader.readline(4096).decode("latin-1").strip()
        parts = request.split(" ")
        method, path = (parts[0], parts[1].split("?")[0]) if len(parts) == 3 else ("?", "?")
        headers = {}
        for _ in range(50):
            line = reader.readline(8192).decode("latin-1")
            if line in ("\r\n", "\n", ""):
                break
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        status, kind, body = respond(method, path, headers, peer, local, token())
    except Exception as error:
        status, kind, body = 400, "application/json; charset=utf-8", json.dumps({"ok": False, "erreur": f"Requête illisible ({type(error).__name__})."}).encode()
    head = f"HTTP/1.1 {status} OK\r\nContent-Type: {kind}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n"
    try:
        connection.sendall(head.encode() + body)
    finally:
        connection.close()
    log(f"{peer} {method} {path} -> {status} en {time.monotonic() - started:.1f} s")


if __name__ == "__main__":
    main()
