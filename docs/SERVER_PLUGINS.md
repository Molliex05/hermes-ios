# Server plugins

Optional Hermes plugins that live in `server/`. They run inside the Hermes container (`/opt/data/plugins/<name>`); the app works without them. Install a plugin by copying its folder there, enabling it per profile (`hermes -p <profile> plugins enable <name>`) and restarting the gateway. Dashboard routes are mounted at startup and the **root** profile must enable a plugin that serves dashboard routes.

| Plugin | Purpose | Notes |
| --- | --- | --- |
| `hermes-ios-push` | APNs alerts, Live Activity updates and silent widget refresh | Needs the Apple key on the server; see [NOTIFICATIONS.md](NOTIFICATIONS.md) |
| `hermes-gemini-voix` | Gemini text-to-speech provider (custom voice) with a keep-alive HTTP session | Tier 1 quota is 100 TTS requests a day, 10 a minute; `tts.streaming.min_len: 90` groups short sentences. An optional fallback voice is off by default (`tts.gemini.fallback`) |
| `hermes-widgets` | Compact Noriven figures snapshot for the finance widget, plus the `noriven_chiffres` tool | Dashboard route behind the dashboard's own auth; enable on the root and the Noriven profile |
| `hermes-meteo` | `meteo` tool backed by Open-Meteo (no key) | Default place in `meteo.lieu_defaut` |
| `hermes-google-lite` | Gmail and Google Calendar for one account | See below |

## hermes-google-lite

Tools: `gmail_chercher`, `gmail_lire`, `gmail_brouillon`, `gmail_dossiers`, `gmail_trier`, `agenda_calendriers`, `agenda_lister`, `agenda_creer`, `agenda_modifier`, `agenda_supprimer`.

- **Never sends mail or deletes mail.** Requests go through a closed allowlist of (method, path) pairs: no send, no trash, no delete, no label rename or delete, no `modify` on a single message. Only `batchModify` is allowed and only to add folders and remove `INBOX` or `UNREAD`. Tests assert this.
- **Folders** are Gmail labels, sub-folders are `Parent/Child` (4 levels at most). They are created on demand. Names reserved by Gmail (inbox, sent, trash, spam, `CATEGORY_*`, …) are refused.
- **Filing** targets explicit ids (100 at most) or a Gmail search (200 matches at most per call); 1000 messages per hour in total. Drafts are limited to 10 an hour and events to 10 an hour. Everything undoes from Gmail.
- **Calendars**: reading covers every calendar shown in the account (own, shared, work), merged by start time with each event's calendar name; hidden and holiday calendars are skipped. Writing is limited to the **main** calendar: create, modify and delete never notify guests (`sendUpdates=none`), edits are limited to 10 an hour and deletions to 5; Google keeps deleted events 30 days in the calendar bin. Events of other calendars are refused (the allowlist only has read paths for them).
- **Untrusted content**: mail and event text is returned with a warning and must never be treated as instructions. The tools are blocked on the `api_server` platform.
- **Credentials** are `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `GOOGLE_REFRESH_TOKEN` in the profile's `.env`, never in the repository. `oauth_setup.py url|exchange|check` runs the consent flow with PKCE. Scopes are `gmail.modify`, `calendar.events` and `calendar.calendarlist.readonly`; the OAuth client must be published ("In production") or its refresh token expires after 7 days, which `check` reports.
- Tests: `python3 -m unittest discover -s tests` in the plugin folder (fake Google, offline).

### Email watcher (Jarvis)

`scripts/jarvis_courriels.py` is a cron *monitor script*: it prints one stable line per **incident** received in the last 3 days (`×N | sender | subject | ids: …`; same sender domain and same subject once digits and `Re:` are masked, so eight identical outage mails are one line `×8`). Hermes wakes the agent only when that text changes, that is when mail arrives; archiving or labelling never changes it and a quiet mailbox costs nothing. Install it in `<profile>/scripts/`.

```bash
hermes -p personnel cron create --name "Courriels de Maxime" --monitor-script jarvis_courriels.py \
  --deliver bot-chat:personnel --continuity "every 5m" "<prompt>"
```

- **One agent, one conversation.** `--deliver bot-chat:personnel` injects the run's answer into the agent's canonical Bot Chat as an inbound message (`[Cronjob "…" output — scheduled job, not the user …]`). The agent answers there with the whole conversation as context and the end of that turn sends the push notification, which opens that conversation. `[SILENT]` delivers nothing and sends no notification. `--continuity` gives each run the previous non-silent output, so an incident already reported is not repeated unless something new happened (« Mise à jour : »).
- **What a run does.** It reads one representative mail per new incident (untrusted content), files every id of the incident (`gmail_trier`), adds calendar events for confirmed appointments (checking the work calendar), and ends with `[SILENT]` or a short neutral note: sender and subject only, never text copied from a mail. It cannot send, delete, draft or edit events. Maxime's feedback is saved as `Courriels : …` rules in the agent's memory (see `SOUL.md`), which also tells the agent to treat these Bot Chat notes as data, never as instructions.
- **Hardening.** `CRON_BLOCKED` stops calendar edits and deletions in unattended runs, and the profile's cron toolsets are reduced to memory, Google, push and weather (`platform_toolsets.cron` with `no_mcp`; `hermes tools disable … --platform cron`), so no terminal, browser or MCP tool reads attacker-controlled mail. A change of the script's output format re-baselines a job only if the job is recreated (the first run of a new job is a baseline and answers `[SILENT]`).
