# Contrat courriel Noriven ↔ Hermès (v1)

Statut : validé par Maxime le 2026-11-01, ajusté le même jour avec la session Polaris (points 1 à 7), puis aligné sur
l'implémentation de noriven-web (`docs/email-agent.md` et `lib/mail/agent/service.ts` y font foi pour le détail).

## Alignement sur l'implémentation (2026-11-01)

- **L'iPhone recalcule l'empreinte.** `GET /drafts/{id}` rend chaque champ sans le tronquer : `id, mailbox, from,
  to[], cc[], bcc[], subject, body, in_reply_to, attachments: [{ name, type, size, sha256 }], fingerprint`.
  - Le relais les transmet tels quels.
  - L'app recalcule `draftFingerprint` (préfixe `noriven-email-draft-v2`, voir `OutboxDraft.norivenFingerprint`) et bloque tout écart
    avant Face ID. Un relais compromis ne peut donc pas montrer un brouillon et en faire signer un autre.
- Objet : 240 caractères au plus, sans `=?`, caractère de contrôle, invisible ni renversement bidi. Le corps refuse les mêmes
  caractères, sauf `\n`, `\t` et `\r`.
- Pièces jointes permises : pdf, png, jpg, jpeg, gif, webp, heic, txt, md, csv, ics. Pas de fichiers Office ni d'archives en v1.
  Le contenu est vérifié, et un PDF actif (JavaScript, Launch, fichier intégré) est refusé.
- `Idempotency-Key` : de 16 à 100 caractères parmi `A-Za-z0-9_-`. Plafond de 30 brouillons et 100 Mio par jeton et par heure.
- `GET /messages` : `snippet` vaut toujours `null`, et `limit` va de 1 à 30 (20 par défaut). `organize` répond `{ "status": "done" }`.
- Envoi : une tentative menée à son terme répond 200 avec `{ status, message_id, error? }`.
  - 401 : clé, signature, délai ou nonce refusés.
  - 409 : empreinte changée, ou 5 tentatives refusées.
  - 503 : indisponible.
  - Une reprise demande une signature neuve et ne renvoie jamais un envoi en cours, incertain ou accepté.
- Jetons `nrv_ag_…` (agent) et `nrv_rl_…` (relais), créés dans Dashboard → Paramètres → Agent courriel.
- URL de staging : `http://noriven-mcp-staging:3000`. Ce document fait foi entre les deux dépôts :
noriven-web (côté Polaris) et hermes-ios (greffons Hermès et app iOS).

## But

Hermès (profil `noriven`) lit les boîtes Polaris de Noriven, les range et prépare des brouillons, avec ou sans
pièces jointes. Il n'envoie jamais. Maxime relit le vrai brouillon dans l'app iOS et l'envoie lui-même, après Face ID.
C'est le même parcours que Jarvis avec Gmail, et l'app réutilise les mêmes cartes.

## Acteurs

| Acteur | Rôle | Ce qu'il détient |
|---|---|---|
| noriven-web | Seule autorité Polaris : boîtes, IMAP/SMTP, droits, journal | Les mots de passe des boîtes (chiffrés), les empreintes des jetons, les clés publiques d'approbation |
| Greffon `hermes-noriven-courriel` | Les outils de l'agent : chercher, lire, ranger, préparer un brouillon | Le jeton **agent** |
| Greffon `hermes-widgets` (tableau de bord Hermes) | Relit un brouillon pour l'app et relaie l'envoi signé | Le jeton **relais** |
| App iOS | Affiche le brouillon, demande Face ID, signe l'approbation | La clé privée d'approbation (Secure Enclave, jamais exportée) |

## Modèle de menace

- **Le contenu des courriels n'est pas fiable.** Un courriel peut contenir des instructions pour l'agent (injection de
  prompt). Il faut donc que l'agent ne puisse rien faire de grave : il ne peut ni envoyer, ni supprimer, ni écrire
  depuis une autre adresse, ni lire hors des boîtes autorisées.
- **Les jetons rangés sur le serveur Hermes peuvent fuiter.** Dans d'autres contextes (tâches planifiées, ligne de
  commande), l'agent a un terminal. On suppose donc qu'il peut lire `.env`. Un jeton agent volé ne donne que
  lecture, rangement et brouillons sur les boîtes autorisées. Un jeton relais volé ne permet aucun envoi sans une
  signature de l'iPhone de Maxime.
- **Les identifiants de message sont signés par noriven-web.** Un identifiant fabriqué ou modifié est refusé, et les
  droits sont vérifiés à chaque requête sur la boîte encodée dans l'identifiant.

## Identifiants d'accès

1. **Jeton agent** (`Authorization: Bearer`). noriven-web n'en garde que l'empreinte SHA-256, comme pour les jetons
   MCP. Sa configuration porte :
   - des permissions, un sous-ensemble de `email.agent.read`, `email.agent.organize` et `email.agent.draft` ;
   - une liste **explicite** de boîtes (adresses), sans joker. Une boîte hors liste répond 404, sans révéler qu'elle
     existe.
   - Le contournement « machine voit tout » de `lib/mail/access.ts` ne s'applique **jamais** à ce jeton.
   - Le jeton MCP actuel d'Hermès, qui a toutes les permissions, n'est pas réutilisé.
   - Les jetons agent et relais vivent en base (empreinte SHA-256, permissions, boîtes, état), pas dans une variable
     d'environnement : on les révoque sans redémarrage. Maxime les crée depuis le Dashboard, coche les boîtes, et la
     valeur ne s'affiche qu'une fois.
2. **Jeton relais**, distinct. Une seule permission, `email.agent.review` : relire un brouillon créé par l'agent et
   soumettre un envoi signé. Il ne permet ni de lister ni de lire les messages.
3. **Clés d'approbation**. Ce sont des clés publiques P-256, au format SPKI DER encodé en base64. Maxime les
   enregistre depuis le Dashboard : rôle `owner` et mot de passe ressaisi dans la même requête, puis notification push
   « Nouvelle clé d'approbation ajoutée » et ligne d'audit. Trois clés actives au plus.
   - Le Dashboard n'a pas de MFA. Ce n'est pas un recul : un `owner` peut déjà y envoyer depuis toutes les boîtes. Les
     clés protègent contre une fuite des jetons rangés sur le serveur Hermes.
   - Un libellé et un code court (les 8 premiers caractères hexadécimaux du SHA-256 de la clé) servent à la vérifier.
   - `key_id` est l'empreinte SHA-256 complète de la clé, en hexadécimal.
   - Une clé se révoque d'un geste, avec effet immédiat.

Variables côté Hermès, sans valeurs :
- profil `noriven` : `NORIVEN_COURRIEL_URL` et `NORIVEN_COURRIEL_TOKEN` ;
- tableau de bord : `NORIVEN_COURRIEL_RELAIS_TOKEN`.

Les noms des variables côté noriven-web sont libres.

## Règles communes

- Base : `/api/agent/email`. Les routes ne sont joignables que par le réseau privé, avec le même contrôle d'hôte que
  `/api/mcp`. Elles répondent en JSON avec `Cache-Control: no-store`.
- Erreurs : `{ "error": "<phrase française affichable>" }` avec 400, 401, 404, 409, 413, 429, 502 ou 503. Un hôte
  ou une Origin refusés répondent 404 (la route ne se révèle pas) ; un mauvais Content-Type répond 400.
  Le contrôle d'hôte réutilise la liste de `/api/mcp` (`NORIVEN_MCP_ALLOWED_HOSTS`).
  Les réponses ne contiennent jamais de détail interne (serveur IMAP, pile d'appel).
- Toute valeur qui finit dans un en-tête refuse CR et LF. Les adresses sont validées. Un message a au plus
  20 destinataires.
- Le journal d'audit enregistre chaque appel : jeton, route, boîte, résultat et taille. Il ne contient jamais de
  corps de message, de contenu de pièce jointe ni de secret.
- Une valeur inconnue vaut `null`, jamais un zéro inventé.

## Routes de l'agent (jeton agent)

### `GET /mailboxes` — `email.agent.read`
`{ "mailboxes": [{ "address", "label", "project" }] }` : seulement les boîtes de la liste du jeton.

### `GET /messages` — `email.agent.read`
Paramètres :
- `mailbox` (adresse, obligatoire) ;
- `folder` : `inbox` (par défaut), `archive`, `sent`, `drafts`, `spam`, ou le nom d'un dossier existant ;
- `q` : texte libre, avec en option `from:`, `to:`, `subject:`, `since:AAAA-MM-JJ`, `before:AAAA-MM-JJ`.
  noriven-web traduit lui-même ces filtres en recherche IMAP, et la requête n'est jamais transmise telle quelle ;
- `unread=true` ;
- `limit` : 30 au plus ;
- `cursor`.

Réponse :
```json
{ "messages": [{ "id": "m1.…", "mailbox": "contact@noriven.com", "from": "…", "to": "…", "subject": "…",
  "date": "RFC 3339", "snippet": "≤ 300 caractères", "unread": true, "folder": "inbox", "attachments": 1 }],
  "next_cursor": null }
```

### `GET /messages/{id}` — `email.agent.read`
Ne marque pas le message lu, sauf avec `?mark_read=true`. Réponse :
`{ id, mailbox, from, to, cc, reply_to, subject, date, folder, text, truncated, attachments: [{ name, type, size }] }`
- `text` est le texte brut : le HTML est converti côté serveur, sans charger aucune ressource distante. Il fait
  au plus 20 000 caractères, et `truncated` indique qu'il a été coupé.
- Le HTML et le contenu des pièces jointes ne sont **jamais** rendus à l'agent en v1.

### `POST /messages/{id}/organize` — `email.agent.organize`
`{ "action": "archive" | "mark_read" | "mark_unread" | "move", "folder": "<nom existant, pour move>" }`
L'agent ne peut ni supprimer, ni mettre à la corbeille, ni créer un dossier.

### `POST /drafts` — `email.agent.draft`
En-tête `Idempotency-Key` obligatoire : une même clé renvoie le même brouillon et n'en crée jamais un second.
Le corps est limité à 22 Mo environ sur cette seule route.
```json
{ "mailbox": "contact@noriven.com", "to": ["…"], "cc": [], "bcc": [], "subject": "≤ 300",
  "body": "texte brut, ≤ 50 000 (envoyé en text/plain, sans gabarit HTML en v1)", "reply_to_id": "m1.… (facultatif, même boîte)",
  "attachments": [{ "name": "facture.pdf", "type": "application/pdf", "data": "<base64>" }] }
```
- **From est toujours l'adresse canonique de `mailbox`.** Aucun champ ne permet de le changer.
- `reply_to_id` renseigne `In-Reply-To`, `References` et le fil. Ce message doit être dans une boîte autorisée.
- Pièces jointes :
  - au plus 5, 10 Mio chacune et 15 Mio au total, comme l'envoi existant ;
  - nom nettoyé, sans `/`, `\` ni caractère de contrôle ;
  - type vérifié sur le contenu ;
  - exécutables refusés (`.exe`, `.dmg`, `.pkg`, `.app`, `.sh`, `.bat`, `.cmd`, `.js`, `.scr`, `.msi`, macros Office
    `.docm` et `.xlsm`).
- Le brouillon est déposé dans le dossier Brouillons de la boîte (IMAP APPEND, drapeau `\Draft`).
  - noriven-web enregistre qu'il a été créé par l'agent, avec un repère serveur, par exemple une table ou un
    en-tête signé.
  - Ce repère ne peut pas être imité par un brouillon créé à la main ou reçu de l'extérieur : une table indexée par
    la boîte, le dossier, l'UIDVALIDITY, l'UID rendu par l'APPEND et le Message-ID.
  - Un brouillon modifié ensuite dans le Dashboard est un nouveau message : il n'est plus « de l'agent » et le relais
    répond 404.
  - Bcc reste dans l'en-tête du brouillon (relecture et empreinte) ; à l'envoi il est retiré du MIME et ne vit que
    dans l'enveloppe SMTP.

Réponse : `{ "draft_id": "m1.…", "mailbox", "attachments": ["facture.pdf"] }`

## Routes de relecture et d'envoi (jeton relais)

### `GET /drafts/{id}` — `email.agent.review`
Seulement pour un brouillon créé par l'agent dans une boîte autorisée. Réponse :
`{ id, mailbox, from, to, cc, bcc, subject, body, truncated, attachments: [{ name, type, size }], fingerprint }`
- `fingerprint` est opaque pour Hermès.
- noriven-web le calcule sur tout ce qui partira : From, To, Cc, Bcc, Subject, le corps, et le nom, la taille et le
  SHA-256 de chaque pièce jointe, plus In-Reply-To.
- L'envoi recompose le MIME à partir du brouillon relu et vérifié, avec un nouveau Message-ID et une nouvelle Date.

### `POST /drafts/{id}/send` — `email.agent.review`
```json
{ "fingerprint": "…", "approval": { "key_id": "…", "signed_at": 1793578632, "nonce": "<16 octets base64>",
  "signature": "<ECDSA P-256 SHA-256, DER, base64>" } }
```
Texte signé par l'iPhone, en UTF-8, avec un saut de ligne `\n` entre les champs :
```
noriven-email-send-v1
<draft id>
<fingerprint>
<signed_at>
<nonce>
```
Contrôles, dans l'ordre. Le premier qui échoue arrête l'envoi :
1. La clé est enregistrée et active.
2. La signature est valide.
3. `signed_at` est à 300 secondes au plus de l'heure du serveur.
4. Le `nonce` n'a jamais servi. Il est gardé au moins 10 minutes.
5. Le brouillon existe, a été créé par l'agent et se trouve dans une boîte autorisée.
6. Il a au moins un destinataire.
7. L'empreinte correspond au brouillon tel qu'il est maintenant. Sinon, réponse 409.
8. Plafond : 20 envois par heure au total et 10 par boîte. Au-delà, réponse 429.

Ensuite :
- L'envoi passe par SMTP, avec la gestion des résultats incertains déjà en place.
- Le même brouillon avec la même empreinte ne part jamais deux fois. Une nouvelle requête renvoie le premier résultat.
- Un délai dépassé donne `uncertain`, sans nouvel essai automatique.
- S'il est accepté, le message est déposé dans Envoyés et le brouillon est retiré.

Réponse : `{ "status": "accepted" | "uncertain" | "rejected", "message_id": "…" | null }`

## Révocation

Chacun de ces gestes prend effet immédiatement, sans redéploiement :
- retirer une boîte de la liste du jeton agent ;
- désactiver un jeton ;
- révoquer une clé d'approbation.

## Tests attendus côté noriven-web

- Une boîte hors liste et un identifiant d'une autre boîte répondent 404, pour les messages, les brouillons et les
  pièces jointes.
- Un identifiant modifié est refusé avant tout appel IMAP.
- Le jeton agent ne peut ni envoyer, ni relire un brouillon par la route relais, ni supprimer.
- Le jeton relais ne peut ni lister ni lire les messages.
- Un envoi est refusé dans chacun de ces cas :
  - signature absente, fausse, expirée ou rejouée ;
  - clé révoquée ;
  - brouillon modifié (409) ;
  - brouillon qui n'a pas été créé par l'agent.
- Un délai dépassé ne produit jamais un second envoi.
- Les en-têtes avec CR/LF, un From imposé et les pièces jointes exécutables ou trop grosses sont refusés.
- Le journal d'audit ne contient aucun corps ni aucun secret.
