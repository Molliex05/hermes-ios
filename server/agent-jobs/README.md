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

