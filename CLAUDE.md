# CLAUDE.md — {{NOM}}

{{PRÉSENTATION : une ou deux phrases, ce que fait le projet et pour qui.}}

Type de projet : `{{TYPE : app-mac, outil, shell, powershell, site ou autre}}`

Ce projet suit le standard commun des projets de Dany (`/standard-projet` le vérifie).

## Commandes

| Action | Commande |
| --- | --- |
| Construire | `{{COMMANDE_CONSTRUIRE : ./build.sh, ou « rien à construire »}}` |
| Tester | `{{COMMANDE_TESTER : une commande autonome, vérifiée, ou « pas de tests »}}` |

Les fichiers produits vont dans `build/`, ignoré par git. Rien de compilé n'est commité.

## Publier une version

Dans cet ordre :

1. Mettre le numéro à jour dans le projet ({{OÙ : Resources/Info.plist, VERSION= dans le script…}})
   et ajouter la section `## X.Y — date` dans `CHANGELOG.md`.
2. `{{COMMANDE_CONSTRUIRE}}` (produit `build/{{FICHIER}}`) et `{{COMMANDE_TESTER}}` : tout
   doit passer avant d'envoyer quoi que ce soit.
3. `git status`, puis `git add` des fichiers voulus (pas `git add -A` à l'aveugle),
   `git commit -m "Version X.Y" && git push origin main`
4. `git tag -a vX.Y -m "Version X.Y" && git push origin vX.Y`
5. `NOTES="$(~/.claude/skills/standard-projet/scripts/notes-version.sh X.Y)" && gh release create vX.Y "build/{{FICHIER}}" --verify-tag --title "{{NOM}} X.Y" --notes "${NOTES}"`
   (en deux temps : si la section du CHANGELOG manque, rien n'est publié).

{{SANS FICHIER D'INSTALLATION (site, outil sans build.sh) : retirer « (produit build/…) »,
l'argument "build/{{FICHIER}}" de l'étape 5 et la phrase sur le lien ci-dessous. Supprimer
cette consigne.}}

Le README pointe vers `releases/latest/download/{{FICHIER_URL}}` (GitHub remplace les
espaces du nom par des points).

## Règles

- Répondre et écrire (commits, README, textes de l'interface) en français.
- {{RÈGLES PROPRES AU PROJET : par exemple « ne jamais écrire sous /Volumes pendant les tests ». Supprimer la puce s'il n'y en a pas.}}
- Avant de pousser une fonctionnalité : construction et tests réussis, README et CHANGELOG à
  jour, capture d'écran (`docs/capture.png`) refaite si l'interface a changé, et une nouvelle
  version si ce qu'on installe a changé.
- Pousser sur `main` directement ; un commit qui casse se corrige par `git revert`, jamais
  en réécrivant l'historique.

## Organisation

- `{{DOSSIER}}` : {{rôle}}
- `docs/` : capture d'écran, cahier des charges
