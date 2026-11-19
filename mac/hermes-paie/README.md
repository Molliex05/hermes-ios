# hermes-paie (Mac mini)

Service qui range les talons MaPaie.net de Maxime dans iCloud (`Documents/Finance/Paye/<AAAA>/<MM> - <Mois>/Paye (<date>).pdf`)
et les rend à Jarvis par Tailscale. Python 3.9 du système, bibliothèque standard seulement.

- `paie.py` : connexion (identifiant du trousseau, service `mapaie.net`), liste, téléchargement, classement. `paie.py synchroniser | etat` à la main.
- `service.py` : une requête par connexion, lancé par launchd (inetd) sur le port 8790. Accepte seulement noriven-vps
  par l'adresse Tailscale du Mac, avec le jeton du trousseau `hermes-paie-service`. Routes : `GET /etat`, `POST /synchroniser`, `GET /talon/AAAA-MM-JJ`.
- `launcher.c` : le programme que launchd démarre. macOS n'ouvre le dossier iCloud qu'à lui (Accès complet au disque, accordé par Maxime) ;
  il lance `service.py` en enfant. `install.sh` ne le recompile que si sa source change, sinon l'accès serait à redonner.
- Rien ne tourne entre deux appels. Après un refus de connexion de MaPaie.net, aucun nouvel essai pendant 6 h.

Installer ou mettre à jour : `./install.sh`. Tests : `/usr/bin/python3 -I -m unittest discover -s tests`.
Journal (une ligne par appel, sans contenu) : `~/Library/Logs/hermes-paie.log`.
