# {{NOM}}

{{PRÉSENTATION : une ou deux phrases, ce que c'est et pour qui.}}

![{{NOM}}](docs/capture.png)

## Fonctions

- {{UNE FONCTION PAR PUCE, DU POINT DE VUE DE L'UTILISATEUR}}

## Installer

Télécharge [{{FICHIER}}](https://github.com/mdany75/{{NOM}}/releases/latest/download/{{FICHIER_URL}})
(toujours la dernière version), puis {{ÉTAPES}}.

{{CONFIGURATION REQUISE, AUTORISATIONS AU PREMIER LANCEMENT}}

## Reconstruire

{{OUTILS NÉCESSAIRES}}

```bash
./build.sh
```

Produit `build/{{FICHIER}}`.

## Tests

```bash
{{COMMANDE_TESTER}}
```

## Organisation

- `{{DOSSIER}}` : {{rôle}}
- `docs/` : capture d'écran, cahier des charges

<!-- {{FICHIER_URL}} : le nom du fichier joint à la Release, où GitHub a remplacé les espaces
     par des points (« Transfert Infuse.dmg » → « Transfert.Infuse.dmg »). Supprimer la section
     « Reconstruire » s'il n'y a rien à construire, « Tests » s'il n'y a pas de tests, et la
     capture s'il n'y a pas d'interface. Supprimer ce commentaire. -->
