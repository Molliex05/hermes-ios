"""Talons de paie MaPaie.net -> iCloud, sur le Mac mini de Maxime.

Python 3.9 du système, bibliothèque standard seulement. L'identifiant MaPaie.net vit dans le trousseau (service
« mapaie.net ») ; il est lu au moment de se connecter et jamais écrit, journalisé ni renvoyé.

Dossier iCloud (convention constatée le 2026-11-18) :
    Finance/Paye/<AAAA>/<MM> - <Mois sans accent>/Paye (<date de paie>).pdf
La paie tombe le jeudi, chaque semaine ; elle paie la semaine travaillée (dimanche au samedi) finie 12 jours plus tôt.
Un talon peut reprendre d'anciennes semaines : ce sont des ajustements.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import http.cookiejar
import json
import os
import re
import subprocess
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, List, Optional, Tuple

ROOT = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Documents/Finance/Paye"
STATE = Path.home() / "Library/Application Support/hermes-paie"
MONTHS = ["Janvier", "Fevrier", "Mars", "Avril", "Mai", "Juin", "Juillet", "Aout", "Septembre", "Octobre", "Novembre", "Decembre"]
FIRST_PAY = dt.date(2026, 4, 30)   # le premier talon publié sur MaPaie.net
PAY_DELAY = dt.timedelta(days=12)  # fin de la semaine travaillée -> jour de paie
NAME = re.compile(r"^\.?Paye \((\d{4}-\d{2}-\d{2})\)( \(\d+\))?\.pdf(\.icloud)?$")
SHORT_MONTHS = {"janv": 1, "févr": 2, "fevr": 2, "mars": 3, "avr": 4, "mai": 5, "juin": 6, "juil": 7,
                "août": 8, "aout": 8, "sept": 9, "oct": 10, "nov": 11, "déc": 12, "dec": 12}
PERIOD = re.compile(r"Période travaillée (\d{4})-(\d{1,2}) du (\d{1,2}) ([a-zéû]+)\.? (\d{4}) au (\d{1,2}) ([a-zéû]+)\.? (\d{4})", re.I)
PDFTOTEXT = "/opt/homebrew/bin/pdftotext"

BASE = "https://m.mapaie.net"
LOGIN = BASE + "/fr/usager"
LIST = BASE + "/fr/compte/talon"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
KEYCHAIN_SERVICE = "mapaie.net"
LOGIN_PAUSE = dt.timedelta(hours=6)  # après un refus du site : pas de nouvel essai avant, pour ne pas bloquer le compte


class PaieError(Exception):
    """Un échec à dire tel quel à Jarvis (jamais de secret dedans)."""


# MARK: Classement

def month_folder(root: Path, day: dt.date) -> Path:
    """Le dossier du mois : celui qui existe déjà (« 08 - Aout »), sinon un nouveau à la même convention."""
    year = root / str(day.year)
    if year.is_dir():
        for child in sorted(year.iterdir()):
            if child.is_dir() and child.name.startswith(f"{day.month:02d} - "):
                return child
    return year / f"{day.month:02d} - {MONTHS[day.month - 1]}"


def target(root: Path, pay_date: dt.date) -> Path:
    return month_folder(root, pay_date) / f"Paye ({pay_date.isoformat()}).pdf"


def filed(root: Path) -> Dict[dt.date, List[Path]]:
    """Les talons déjà classés, par date de paie. Un fichier qu'iCloud a déchargé du Mac (« .Paye (…).pdf.icloud ») compte."""
    found: Dict[dt.date, List[Path]] = {}
    if not root.is_dir():
        return found
    try:
        os.listdir(root)
    except PermissionError:
        # macOS refuse l'accès (confidentialité) : sans ça, tout paraîtrait manquant et serait retéléchargé.
        raise PaieError("macOS refuse au service l'accès au dossier iCloud Finance/Paye (Accès complet au disque).") from None
    for path in root.rglob("*"):
        match = NAME.match(path.name)
        if match and path.is_file():
            found.setdefault(dt.date.fromisoformat(match.group(1)), []).append(path)
    return found


def expected_pay_days(today: dt.date, first: Optional[dt.date] = None) -> List[dt.date]:
    days, day = [], first or FIRST_PAY
    while day <= today:
        days.append(day)
        day += dt.timedelta(days=7)
    return days


def file_pdf(root: Path, pay_date: dt.date, data: bytes) -> Optional[Path]:
    """Range un talon. Refuse ce qui n'est pas un PDF ; n'écrase jamais un talon déjà classé (renvoie None).
    L'écriture passe par un fichier temporaire du même dossier, renommé d'un coup : iCloud ne voit jamais un PDF à moitié écrit."""
    if not data.startswith(b"%PDF-"):
        raise PaieError("Le fichier reçu n'est pas un PDF.")
    if pay_date in filed(root):
        return None
    path = target(root, pay_date)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.partiel")
    temporary.write_bytes(data)
    os.replace(temporary, path)
    return path


def periods(text: str) -> List[Tuple[str, dt.date, dt.date]]:
    """Les semaines travaillées d'un talon : (« 2026-16 », début, fin). Plusieurs = ajustements d'anciennes semaines."""
    out: List[Tuple[str, dt.date, dt.date]] = []
    for m in PERIOD.finditer(text):
        try:
            start = dt.date(int(m.group(5)), SHORT_MONTHS[m.group(4).lower()], int(m.group(3)))
            end = dt.date(int(m.group(8)), SHORT_MONTHS[m.group(7).lower()], int(m.group(6)))
        except (KeyError, ValueError):
            continue
        code = f"{m.group(1)}-{int(m.group(2)):02d}"
        if all(code != seen for seen, _, _ in out):
            out.append((code, start, end))
    return out


def weeks_of(pay_date: dt.date, text: str) -> Dict[str, object]:
    """La semaine que ce jeudi paie normalement (finie 12 jours plus tôt) et les anciennes qu'il ajuste."""
    found = periods(text)
    own = next((p for p in found if p[2] == pay_date - PAY_DELAY), None)
    describe = lambda p: {"semaine": p[0], "du": p[1].isoformat(), "au": p[2].isoformat()}
    return {"semaine_payee": describe(own) if own else None,
            "ajustements": [describe(p) for p in found if own is None or p[0] != own[0]]}


def pdf_text(path: Path) -> str:
    if not os.access(PDFTOTEXT, os.X_OK):
        return ""
    result = subprocess.run([PDFTOTEXT, "-layout", str(path), "-"], capture_output=True, text=True, timeout=30)
    return result.stdout if result.returncode == 0 else ""


def local_pdf(path: Path, wait: float = 60) -> Path:
    """Le chemin d'un PDF présent sur le Mac ; un talon qu'iCloud a déchargé est d'abord rapatrié."""
    if path.suffix == ".pdf":
        return path
    real = path.with_name(path.name[1:-len(".icloud")])
    subprocess.run(["/usr/bin/brctl", "download", str(real)], capture_output=True, timeout=30)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if real.is_file() and real.stat().st_size > 0:
            return real
        time.sleep(1)
    raise PaieError("iCloud n'a pas rendu ce talon à temps. Réessaie dans une minute.")


# MARK: MaPaie.net

class _Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links: List[List[str]] = []
        self.forms: List[Dict[str, object]] = []
        self._in_link = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "a" and a.get("href"):
            self.links.append([a["href"], ""]); self._in_link = True
        elif tag == "form":
            self.forms.append({"action": a.get("action") or "", "fields": {}})
        elif tag == "input" and self.forms and a.get("name"):
            fields = self.forms[-1]["fields"]
            if a.get("type") == "hidden":
                fields[a["name"]] = a.get("value") or ""  # type: ignore[index]
            elif a.get("type") == "password":
                fields[a["name"]] = None  # type: ignore[index]

    def handle_endtag(self, tag):
        if tag == "a":
            self._in_link = False

    def handle_data(self, data):
        if self._in_link and self.links:
            self.links[-1][1] += data


def parse_list(html: str) -> Dict[dt.date, str]:
    """La liste des talons publiés : date de paie -> numéro du talon (/fr/compte/detail-talon/<numéro>)."""
    page = _Links(); page.feed(html)
    out: Dict[dt.date, str] = {}
    for href, text in page.links:
        number = re.search(r"/detail-talon/(\d+)$", href)
        day = re.fullmatch(r"\s*(\d{4}-\d{2}-\d{2})\s*", text)
        if number and day:
            try:
                out[dt.date.fromisoformat(day.group(1))] = number.group(1)
            except ValueError:
                continue
    return out


def _keychain() -> Tuple[str, str]:
    attrs = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE], capture_output=True, text=True)
    account = re.search(r'"acct"<blob>="(.*)"', attrs.stdout)
    secret = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], capture_output=True, text=True)
    if attrs.returncode or secret.returncode or not account or not secret.stdout.strip():
        raise PaieError("L'identifiant MaPaie.net est introuvable dans le trousseau du Mac.")
    return account.group(1), secret.stdout.rstrip("\n")


class MaPaie:
    """Une session MaPaie.net : se connecter, lister, télécharger, se déconnecter. Les témoins restent en mémoire."""

    def __init__(self, opener=None):
        self.opener = opener or urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.opener.addheaders = [("User-Agent", UA), ("Accept-Language", "fr-CA,fr;q=0.9")]

    def _open(self, url: str, data: Optional[bytes] = None):
        try:
            return self.opener.open(url, data=data, timeout=30)
        except Exception as error:
            raise PaieError(f"MaPaie.net ne répond pas ({type(error).__name__}).") from None

    def _html(self, url: str, data: Optional[bytes] = None) -> Tuple[str, str]:
        with self._open(url, data) as response:
            return response.geturl(), response.read(3_000_000).decode("utf-8", "replace")

    def login(self) -> None:
        _, html = self._html(LOGIN)
        page = _Links(); page.feed(html)
        form = next((f for f in page.forms if "connexion" in str(f["action"])), None)
        if not form or "Password" not in form["fields"]:
            raise PaieError("La page de connexion de MaPaie.net a changé : le script doit être revu.")
        fields = {name: value for name, value in form["fields"].items() if value is not None}  # type: ignore[union-attr]
        user, password = _keychain()
        fields.update({"Username": user, "Password": password, "RememberMe": "true"})
        data = urllib.parse.urlencode(fields).encode()
        del password, fields
        url, html = self._html(urllib.parse.urljoin(LOGIN, str(form["action"])), data)
        del data
        after = _Links(); after.feed(html)
        if any("Password" in f["fields"] for f in after.forms) or "/fr/compte" not in url:
            raise LoginRefused("MaPaie.net a refusé la connexion : le mot de passe a peut-être changé.")

    def talons(self) -> Dict[dt.date, str]:
        url, html = self._html(LIST)
        if "/fr/compte" not in url:
            raise PaieError("La session MaPaie.net s'est fermée avant la liste des talons.")
        return parse_list(html)

    def pdf(self, number: str) -> bytes:
        with self._open(f"{BASE}/fr/compte/detail-talon/{number}") as response:
            data = response.read(20_000_000)
            if "pdf" not in response.headers.get("Content-Type", "") or not data.startswith(b"%PDF-"):
                raise PaieError("MaPaie.net n'a pas renvoyé un PDF pour un talon.")
            return data

    def logout(self) -> None:
        try:
            self._open(BASE + "/fr/usager/deconnexion").close()
        except PaieError:
            pass


class LoginRefused(PaieError):
    pass


# MARK: Synchronisation

def _read_state() -> Dict[str, str]:
    try:
        return json.loads((STATE / "etat.json").read_text())
    except Exception:
        return {}


def _write_state(state: Dict[str, str]) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    temporary = STATE / ".etat.json.partiel"
    temporary.write_text(json.dumps(state))
    os.replace(temporary, STATE / "etat.json")


def summary(root: Path, today: dt.date, published: Optional[Dict[dt.date, str]] = None) -> Dict[str, object]:
    """Ce qui est classé, ce qui manque encore et pourquoi."""
    found = filed(root)
    expected = expected_pay_days(today)
    out: Dict[str, object] = {
        "classes": len(found),
        "dernier_classe": max(found).isoformat() if found else None,
        "jeudis_sans_talon_classe": [d.isoformat() for d in expected if d not in found],
    }
    if published is not None:
        out["publies_sur_mapaie"] = len(published)
        out["jeudis_sans_talon_publie"] = [d.isoformat() for d in expected if d not in published]
    return out


def synchronize(root: Path = ROOT, today: Optional[dt.date] = None, session: Optional[MaPaie] = None) -> Dict[str, object]:
    """Range dans iCloud chaque talon publié qui manque. Une seule synchronisation à la fois."""
    today = today or dt.date.today()
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / "verrou", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise PaieError("Une synchronisation est déjà en cours.") from None
        state = _read_state()
        refused = state.get("connexion_refusee")
        if refused and dt.datetime.now() - dt.datetime.fromisoformat(refused) < LOGIN_PAUSE:
            raise PaieError(f"MaPaie.net a refusé la connexion le {refused[:16].replace('T', ' à ')}. "
                            "Pas de nouvel essai pendant 6 h pour ne pas bloquer le compte ; vérifie le mot de passe du trousseau.")
        if not root.is_dir():
            raise PaieError("Le dossier iCloud Finance/Paye est introuvable sur le Mac.")
        session = session or MaPaie()
        try:
            session.login()
        except LoginRefused:
            state["connexion_refusee"] = dt.datetime.now().isoformat(timespec="minutes")
            _write_state(state)
            raise
        added: List[Dict[str, object]] = []
        try:
            published = session.talons()
            if not published:
                raise PaieError("La liste des talons de MaPaie.net est vide ou illisible : le site a peut-être changé.")
            have = filed(root)
            for day in sorted(published):
                if day in have:
                    continue
                path = file_pdf(root, day, session.pdf(published[day]))
                if path:
                    added.append({"date": day.isoformat(), **weeks_of(day, pdf_text(path))})
        finally:
            session.logout()
        state.pop("connexion_refusee", None)
        state["derniere_synchronisation"] = dt.datetime.now().isoformat(timespec="minutes")
        _write_state(state)
        return {"ok": True, "nouveaux": added, **summary(root, today, published)}


def read(root: Path, pay_date: dt.date) -> bytes:
    """Le PDF d'un talon classé, par sa date de paie seulement : rien d'autre du Mac n'est lisible."""
    paths = filed(root).get(pay_date)
    if not paths:
        raise PaieError(f"Aucun talon classé pour le {pay_date.isoformat()}.")
    data = local_pdf(sorted(paths, key=lambda p: p.suffix != ".pdf")[0]).read_bytes()
    if not data.startswith(b"%PDF-"):
        raise PaieError("Le fichier classé n'est pas un PDF lisible.")
    return data


def read_text(root: Path, pay_date: dt.date) -> str:
    """Le texte d'un talon classé, colonnes alignées comme sur le papier (pdftotext -layout)."""
    paths = filed(root).get(pay_date)
    if not paths:
        raise PaieError(f"Aucun talon classé pour le {pay_date.isoformat()}.")
    text = pdf_text(local_pdf(sorted(paths, key=lambda p: p.suffix != ".pdf")[0]))
    if not text.strip():
        raise PaieError("Le texte de ce talon n'a pas pu être extrait sur le Mac.")
    return text


def status(root: Path = ROOT, today: Optional[dt.date] = None) -> Dict[str, object]:
    state = _read_state()
    return {"ok": True, **summary(root, today or dt.date.today()),
            "derniere_synchronisation": state.get("derniere_synchronisation"),
            "connexion_refusee": state.get("connexion_refusee")}


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["synchroniser"]:
        try:
            print(json.dumps(synchronize(), ensure_ascii=False, indent=1))
        except PaieError as error:
            sys.exit(f"Échec : {error}")
    elif sys.argv[1:] == ["etat"]:
        print(json.dumps(status(), ensure_ascii=False, indent=1))
    else:
        sys.exit("Usage : paie.py synchroniser | etat")
