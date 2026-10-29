# Tâches planifiées des agents (invites)

Les tâches vivent dans `<profil>/cron/jobs.json` du serveur Hermes ; ces fichiers sont leurs invites, versionnées ici.
Règle commune, tirée de l'échec du « heartbeat » (octobre 2026) : **un envoi à Maxime est toujours un appel explicite à
`ios_notify`, jamais l'effet d'une livraison.** Les tâches livrent en `local` (journal visible dans Routines) : elles ne
dépendent plus d'une réponse exactement `[SILENT]`, et une réponse « rien à signaler » ne fait plus sonner le téléphone.

| Fichier | Profil | Déclencheur | Rôle |
|---|---|---|---|
| `hermes-alertes.prompt.fr.txt` | noriven | script `hermes_alertes.py` toutes les 15 min (aucun coût tant que rien ne change) | alertes proactives du serveur |
| `jarvis-tableau.prompt.fr.txt` | personnel | 5 passages par jour | met à jour le widget « À l'affiche » |
| `jarvis-courriels.prompt.fr.txt` | personnel | script `jarvis_courriels.py` toutes les 5 min | tri des courriels, brouillons de réponse |

```bash
# Alertes d'Hermès (script dans <profil>/scripts/, tâche créée en pause puis reprise)
hermes -p noriven cron create --name "Alertes serveur" --monitor-script hermes_alertes.py --deliver local --paused "every 15m" "$(cat hermes-alertes.prompt.fr.txt)"
# Tableau de Jarvis
hermes -p personnel cron create --name "Tableau À l'affiche" --deliver local --paused "0 7,10,13,16,19 * * *" "$(cat jarvis-tableau.prompt.fr.txt)"
```
Le profil doit aussi avoir l'outil `widget_publier` (jeu d'outils `widget_publier` du plugin `hermes-widgets`) et `ios_notify`
dans les jeux d'outils des tâches (`hermes tools enable … --platform cron`).
