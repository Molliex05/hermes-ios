# Cron jobs of the personal agent (Jarvis)

Prompts and creation commands for the scheduled jobs that run in the `personnel` profile. Nothing secret is stored here.

## Heartbeat (food and supplements, adapted to the work schedule)

One job instead of many: a single hourly pass reads a checklist, checks what Noryv has logged today, and either stays silent
(`[SILENT]`) or leaves one short note in the agent's Bot Chat. Reminders are rules in the prompt and in the agent's memory
(`Rappels : …`), not separate jobs, so the agent keeps one structure and one conversation. The pattern is the one OpenClaw
documents as a heartbeat (https://docs.openclaw.ai/gateway/heartbeat).

```bash
hermes -p personnel cron create --name "Heartbeat de Maxime" --deliver bot-chat:personnel --continuity \
  "0 7-21 * * *" "$(cat heartbeat-maxime.prompt.fr.txt)"
```

The job needs its own toolsets (Noryv for the nutrition log, the Google plugin for the work calendar); the CLI has no flag for
that, so set them once with the Hermes job API:

```python
from cron.jobs import update_job
update_job(JOB_ID, {"enabled_toolsets": ["memory", "noryv", "google_perso"]})
```

The email watcher keeps the profile default (`platform_toolsets.cron` with `no_mcp`): it reads untrusted mail and must not reach
Noryv. The heartbeat only reads Noryv and calendar data and never writes.

Each pass first builds the day's plan itself from the calendars (`Police` is the work schedule): type of day (rest, day, evening or night shift), when the agent is awake, meal windows around the shift, quiet hours. A separate morning planning job that stored the plan in memory was tried and dropped: memory cannot be written from an unattended run, and giving the job file access to carry the plan would widen what a calendar entry could influence. Recomputing is cheap and always follows a changed schedule.

A meal or a supplement is logged by telling Jarvis (a creatine intake is logged as a nutrition entry « Créatine »), which is how
the heartbeat knows it was taken. `hermes -p personnel cron run <id>` triggers one pass for testing.

During a work shift the heartbeat stays silent, with one exception per shift: a single reminder near the middle of the shift to
log what was eaten so far. Reminders for creatine and upcoming meals wait until after the shift.

## Daily summary

```bash
hermes -p personnel cron create --name "Résumé de la journée" --deliver bot-chat:personnel --continuity \
  "0 8 * * *" "$(cat resume-journee.prompt.fr.txt)"
# then, with the job API: enabled_toolsets = ["memory", "noryv", "google_perso", "meteo"]
```

Read-only. It runs once a day at 8 h (silent only when a night shift ended after 6 h and Maxime sleeps), and gathers the schedule, the weather, the training plan and the nutrition against his targets into one short message
delivered in the agent's Bot Chat. The agent's rules (`SOUL.md`) relay it nearly as is instead of cutting it to three sentences.

## Status (2026-10-24): proactive jobs paused

After two days of use the heartbeat, the separate creatine reminder and the email watcher's notifications were judged more noise
than value, and switched off (paused, or delivered `local` for the email watcher, which keeps filing mail silently). Why it was
noisy: every output delivered to the Bot Chat becomes a second model turn and a notification, so silence depends on the model
writing exactly `[SILENT]`; it wrote `[ S I L E N T ]` and "nothing urgent" variants that Hermes does not treat as silence. A
heartbeat also has nothing to say without data that Maxime does not log. A sturdier design would make a notification an explicit
tool call (never a side effect of a delivery). Only the daily summary stays.
