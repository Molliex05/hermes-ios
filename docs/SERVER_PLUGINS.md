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
- **Calendars**: reading covers every calendar shown in the account (own, shared, work), merged by start time with each event's calendar name; hidden and holiday calendars are skipped unless named. Writing (create, modify, delete) targets the calendar given as `calendrier` (a name or part of one, « Personnel » by default) and works only on calendars where the account is owner or editor: a read-only calendar (public holidays, someone else's shared agenda) is refused, as is an ambiguous name. Guests are never notified (`sendUpdates=none`), edits are limited to 10 an hour and deletions to 5; Google keeps deleted events 30 days in the calendar bin. Unattended runs (the email watcher) may only create events in the main calendar and cannot edit or delete.
- **Untrusted content**: mail and event text is returned with a warning and must never be treated as instructions. The tools are blocked on the `api_server` platform.
- **Credentials** are `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `GOOGLE_REFRESH_TOKEN` in the profile's `.env`, never in the repository. `oauth_setup.py url|exchange|check` runs the consent flow with PKCE. Scopes are `gmail.modify`, `calendar.events` and `calendar.calendarlist.readonly`; the OAuth client must be published ("In production") or its refresh token expires after 7 days, which `check` reports.
- Tests: `python3 -m unittest discover -s tests` in the plugin folder (fake Google, offline).

### Email watcher (Jarvis)

`scripts/jarvis_courriels.py` is a cron *monitor script*: it prints one stable line per message received in the last 3 days (`id | sender | subject`), so Hermes wakes the agent only when the text changes, that is when mail arrives. Archiving or labelling never changes it, and a quiet mailbox costs nothing. Install it in `<profile>/scripts/` and create the job paused, then resume it:

```bash
hermes -p personnel cron create --name "Courriels de Maxime" --monitor-script jarvis_courriels.py --deliver local --paused "every 5m" "<prompt>"
```

The prompt tells the agent to read each new message (untrusted content), file it, create calendar events for confirmed appointments (checking the work calendar for conflicts), and call `ios_notify` only when Maxime should know now. Its final answer is a one-line-per-message journal shown in Routines. Maxime's feedback is saved as `Courriels : …` rules in the agent's memory (see its `SOUL.md`). Unattended runs cannot edit or delete calendar events (`CRON_BLOCKED`), and the profile's cron toolsets are reduced to memory, Google, push, weather and MCP tools (`hermes tools disable … --platform cron`), so no terminal or browser reads attacker-controlled mail.
