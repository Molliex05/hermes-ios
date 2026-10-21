"""One-time Google authorization for a Hermes profile (run inside the container with HERMES_HOME set).

  python oauth_setup.py url        -> prints the consent URL (open it in a browser, accept, copy the final address)
  python oauth_setup.py exchange <final-address-or-code>   -> stores GOOGLE_REFRESH_TOKEN in the profile's .env
  python oauth_setup.py check      -> proves the stored access works (prints the Gmail address and calendar zone)

GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET must already be in the profile (app: Mon agent → Clés et identifiants).
Nothing secret is printed.
"""
import base64, hashlib, json, os, secrets, sys
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

from hermes_cli.config import save_env_value                      # noqa: E402
from hermes_constants import get_hermes_home                      # noqa: E402

import importlib.util                                              # noqa: E402
_spec = importlib.util.spec_from_file_location("google_api", Path(__file__).resolve().parent / "google_api.py")
api = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(api)

REDIRECT = "http://localhost:8765/"
PENDING = get_hermes_home() / "google_oauth_pending.json"


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "url":
        client = api._env("GOOGLE_CLIENT_ID")
        if not client:
            sys.exit("GOOGLE_CLIENT_ID est absent du profil.")
        verifier = secrets.token_urlsafe(48)
        PENDING.write_text(json.dumps({"verifier": verifier})); PENDING.chmod(0o600)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        print("https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
            "client_id": client, "redirect_uri": REDIRECT, "response_type": "code", "scope": " ".join(api.SCOPES),
            "access_type": "offline", "prompt": "consent", "code_challenge": challenge, "code_challenge_method": "S256"}))
    elif command == "exchange":
        value = (argv[2] if len(argv) > 2 else "").strip()
        code = parse_qs(urlparse(value).query).get("code", [value])[0] if "code=" in value else value
        verifier = json.loads(PENDING.read_text())["verifier"]
        response = api._http("POST", api.TOKEN_URL, data={
            "client_id": api._env("GOOGLE_CLIENT_ID"), "client_secret": api._env("GOOGLE_CLIENT_SECRET"), "code": code,
            "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": REDIRECT})
        data = response.json()
        if response.status_code != 200 or not data.get("refresh_token"):
            sys.exit("Échange refusé : %s" % data.get("error_description", data.get("error", response.status_code)))
        missing = [s for s in api.SCOPES if s not in str(data.get("scope", "")).split()]
        if missing:
            sys.exit("Autorisation incomplète, il manque : " + ", ".join(m.rsplit("/", 1)[-1] for m in missing))
        save_env_value("GOOGLE_REFRESH_TOKEN", data["refresh_token"]); PENDING.unlink(missing_ok=True)
        print("OK : autorisation enregistrée (gmail.modify, calendar.events, calendar.calendarlist.readonly).")
        # Google adds `refresh_token_expires_in` only to tokens of apps in Testing (7 days). Its absence means a durable token.
        print("Jeton limité à 7 jours (mode test) :", "OUI (%s s)" % data["refresh_token_expires_in"] if "refresh_token_expires_in" in data else "non, durable")
    elif command == "check":
        profile = api._http("GET", "https://gmail.googleapis.com/gmail/v1/users/me/profile",
                            headers={"Authorization": "Bearer " + api._access_token()}).json()
        print("Gmail :", profile.get("emailAddress"), "| agenda :", api.calendar_timezone())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
