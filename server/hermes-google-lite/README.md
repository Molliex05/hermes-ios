# hermes-google-lite — Gmail (read + drafts) and Google Calendar for Hermès

Tools: `gmail_chercher`, `gmail_lire`, `gmail_brouillon`, `agenda_lister`, `agenda_creer` (toolset `google_perso`).

**No sending.** Every request passes a closed allowlist in `google_api.py`: list/read messages, create a draft, read the primary calendar, list/create events. There is no code path to send mail, delete, modify, or invite (events are created without attendees, `sendUpdates=none`). Tests assert this (`tests/test_google_lite.py`). The guard is in software: the OAuth scopes themselves (`gmail.compose`) can send, so the refresh token must stay in the profile `.env` and the plugin must stay the only Google surface. Not installed on `api_server` (the dashboard's email assistant).

Limits: 10 drafts and 10 events per hour. Mail and event text is returned flagged as untrusted.

## Install (once per profile; Jarvis = `personnel`)
```sh
P=/opt/data/profiles/personnel
cp -r hermes-google-lite /opt/data/plugins/ && chown -R hermes:hermes /opt/data/plugins/hermes-google-lite
ln -sfn /opt/data/plugins/hermes-google-lite $P/plugins/hermes-google-lite
hermes -p personnel plugins enable hermes-google-lite
```

## Authorize (once)
1. Google Cloud Console: project → enable **Gmail API** and **Google Calendar API** → OAuth consent screen (External, your account as test user, then **Publish app** so the refresh token does not expire after 7 days) → Credentials → OAuth client ID, type **Desktop app**.
2. In Hermès iOS, Jarvis → Clés et identifiants → custom keys `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.
3. In the container: `HERMES_HOME=/opt/data/profiles/personnel /opt/hermes/.venv/bin/python /opt/data/plugins/hermes-google-lite/oauth_setup.py url`, open the URL, accept, copy the final address (it fails to load on localhost: that is expected), then `… oauth_setup.py exchange "<address>"` and `… oauth_setup.py check`.

Rollback: `hermes -p personnel plugins disable hermes-google-lite`, revoke access at myaccount.google.com/permissions.
