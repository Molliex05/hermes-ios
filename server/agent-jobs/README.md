# Tâches planifiées des agents (invites)

Les tâches vivent dans `<profil>/cron/jobs.json` du serveur Hermes ; ces fichiers sont leurs invites, versionnées ici.
Règle commune, tirée de l'échec du « heartbeat » (octobre 2026) : **un envoi à Maxime est toujours un appel explicite à
`ios_notify`, jamais l'effet d'une livraison.** Les tâches livrent en `local` (journal visible dans Routines) : elles ne
dépendent plus d'une réponse exactement `[SILENT]`, et une réponse « rien à signaler » ne fait plus sonner le téléphone.

| Fichier | Profil | Déclencheur | Rôle |
|---|---|---|---|
| `hermes-alertes.prompt.fr.txt` | noriven | script `hermes_alertes.py` toutes les 15 min (aucun coût tant que rien ne change) | alertes proactives du serveur |
| `jarvis-tableau.prompt.fr.txt` | personnel | 5 passages par jour | met à jour le widget « À l'affiche » |
| `jarvis-courriels.prompt.fr.txt` | personnel | retirée le 2026-11-04 (voir plus bas) | tri des courriels, brouillons de réponse |
| `hermes-courriels.prompt.fr.txt` | noriven | retirée le 2026-11-04 (voir plus bas) | boîtes Polaris de Noriven : tri prudent, brouillons, widget, alerte si urgent |
| `hermes-matin.prompt.fr.txt` | noriven | chaque matin à 8 h 15, avec sa sortie précédente en contexte | point libre sur l'entreprise, en cartes, et courriels urgents ou à traiter |

```bash
# Alertes d'Hermès (script dans <profil>/scripts/, tâche créée en pause puis reprise)
hermes -p noriven cron create --name "Alertes serveur" --monitor-script hermes_alertes.py --deliver local --paused "every 15m" "$(cat hermes-alertes.prompt.fr.txt)"
# Tableau de Jarvis
hermes -p personnel cron create --name "Tableau À l'affiche" --deliver local --paused "0 7,10,13,16,19 * * *" "$(cat jarvis-tableau.prompt.fr.txt)"
```
Le profil doit aussi avoir l'outil `widget_publier` (jeu d'outils `widget_publier` du plugin `hermes-widgets`) et `ios_notify`
dans les jeux d'outils des tâches (`hermes tools enable … --platform cron`).

## Mise en place (déployé le 2026-10-29)
- Plugin `hermes-widgets` : copié dans `/opt/data/plugins/hermes-widgets` (copie de l'ancien : `/opt/data/ios-push/hermes-widgets.bak-20261029.tgz`). Il était **désactivé** pour Jarvis
  (`plugins.disabled`) : activé à la main dans `personnel/config.yaml`. `noriven_chiffres` n'est enregistré que pour le profil `noriven`.
- L'assistant courriel du tableau de bord (plateforme `api_server`) ne reçoit pas `widget_publier` : on ajoute le jeu d'outils à
  `known_plugin_toolsets.api_server` de chaque profil (un jeu connu et absent de la liste de la plateforme reste éteint). Le code refuse aussi cette plateforme.
- **Ne pas utiliser `hermes tools disable … --platform api_server` pour ça** : la commande réécrit toute la liste de la plateforme et a retiré `no_mcp`
  de la liste de l'assistant d'Hermès (donc ouvert ses outils MCP). Les configs ont été restaurées ; `hermes tools list` ne modifie rien.
- Tâche « Alertes serveur » (noriven, id `a86140f8b6f0`, toutes les 15 min, livraison locale) : le script est dans `noriven/scripts/`.
  Un échec du script n'apparaît que dans `hermes cron list` (livraison locale) ; ajouter `--failure-deliver` si on veut être prévenu.
- Tâche « Courriels de Maxime » (personnel, `cc6b2f2cf1ed`) : nouvelle invite (brouillons, notification explicite) ; l'ancienne est dans `personnel/cron/jobs.json.bak-assistants-20261029`.
- Pas de tâche « Tableau » pour Jarvis : l'agenda Google est lu par le serveur sans modèle (`agenda.py`) ; l'agent complète le tableau pendant qu'il travaille déjà.
- `apns.json` : `widgets_refresh_minutes` à 30 (copie : `apns.json.bak-20261029`).

- Déployé le 2026-10-29 (soir) : météo de Saint-Constant (`weather.py`, plugin 0.4.0, copie `hermes-widgets.bak-meteo-20261029`), option `ajouter` de
  `widget_publier` (copie `hermes-widgets.bak-ajouter-20261029`), consigne « widget d'abord, notification seulement si urgent » dans le SOUL de Jarvis
  seulement (copie `SOUL.md.bak-widgetvu-20261029` ; Hermès garde « Pour PRÉVENIR » pour ses alertes serveur) et nouvelle invite de « Courriels de Maxime ».
  Le bouton « Vu » du widget est local à l'iPhone : l'agent n'en est pas informé.
- Déployé le 2026-11-01 : « Vu » passe par le serveur (plugin 0.5.0, `POST /board/seen`, copie `hermes-widgets.bak-vu-20261101`). Les lignes vues
  quittent le tableau (un `ajouter` ne les ramène plus) et les ids Gmail qu'elles portaient (`courriels`) sont déposés dans
  `personnel/widgets/a_classer/` ; `jarvis_courriels.py` les archive et les marque lus sans modèle (copie `jarvis_courriels.py.bak-vu-20261101`).
  Consigne « Vu » du SOUL de Jarvis (`SOUL.md.bak-vu-20261101`) et invite de « Courriels de Maxime » (`jobs.json.bak-vu-20261101`) mises à jour.
- Déployé le 2026-11-01 (soir) : cartes courriel (boîte, courriel lu, tri) et consignes de brouillon de Jarvis (SOUL, copie
  `SOUL.md.bak-envoi-20261101`) ; `gmail_brouillon` accepte `pieces_jointes`, limitées aux dossiers `attachments` et `images`
  du profil (plugin `hermes-google-lite` 0.5.0, copie `hermes-google-lite.bak-envoi-20261101`) ; envoi d'un brouillon par
  Maxime depuis l'app : `GET/POST /api/plugins/hermes-widgets/drafts/<profil>/<id>[/send]` (`outbox.py`, plugin 0.6.0, copie
  `hermes-widgets.bak-envoi-20261101`), avec empreinte, 20 envois par heure, journal `personnel/widgets/envois.jsonl`.
  L'agent n'a toujours aucun chemin d'envoi.

- Déployé le 2026-11-01 (22 h 45, lancé par Maxime) : « Courriels Noriven » (noriven, tâche `041840e66b1b`, copies `*.bak-veille-20261101`). Script `hermes-noriven-courriel/scripts/hermes_courriels.py` copié dans
  `noriven/scripts/`. Il lit les boîtes par l'API agent de noriven-web (jeton agent seulement, jamais le jeton relais) et se souvient
  3 jours des courriels vus en boîte de réception : ranger ne réveille pas l'agent. Les « Vu » du widget (`noriven/widgets/a_classer/`)
  sont marqués lus puis archivés sans modèle. Le tableau accepte les ids `m1.…` de Noriven (`hermes-widgets` 0.7.1).
  `hermes -p noriven cron create --name "Courriels Noriven" --monitor-script hermes_courriels.py --deliver local --paused "every 5m" "$(cat hermes-courriels.prompt.fr.txt)"`

- Retiré le 2026-11-04, à la demande de Maxime (trop lourd, alertes pour de vieux courriels) : « Courriels de Maxime » et « Courriels Noriven ». Copies dans
  `<profil>/skill-backups/courriels-5min-20261104/jobs.json`. Sans ces tâches, plus rien ne vide `<profil>/widgets/a_classer/` : un « Vu » du widget n'archive plus le courriel.
- Déployé le 2026-11-04 : « Point du matin » (noriven, `4146b1236c72`), livré dans le Bot Chat. Il remplace la surveillance par un seul passage quotidien sur les courriels Noriven.
  `hermes -p noriven cron create --name "Point du matin" --deliver bot-chat --continuity "15 8 * * *" "$(cat hermes-matin.prompt.fr.txt)"`
