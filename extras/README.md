# Extras

Fichiers à copier selon le type de projet, puis à adapter.

## app-mac — application macOS en Swift (SwiftPM, sans Xcode)

- `build.sh` → à la racine du projet. Remplacer les `{{…}}` en tête de fichier (`APP_NAME`, `PRODUCT`).
  Compile en release, assemble l'application dans un dossier temporaire, la signe avec le
  certificat « Developer ID Application » du trousseau (ad hoc s'il manque), produit
  `build/<Nom>.dmg`, le notarise chez Apple (profil `notarisation` de `notarytool`) et,
  avec `--install`, remplace `/Applications/<Nom>.app`.
- `scripts/make-icon.swift` → dessine l'icône ; adapter les couleurs et le motif.
- `Resources/Info.plist` → changer le nom, l'identifiant (`com.danymenard.<nom>`), la version
  et les descriptions d'usage (accès aux volumes réseau, dossiers…).

## LICENSE-MIT

À copier en `LICENSE` à la racine d'un dépôt public, en remplaçant `{{ANNÉE}}`.

## Après la création d'un projet

`git rm -r extras STANDARD.md`, supprimer `Sources/` et `Tests/` s'ils ne servent pas, puis
remplir `README.md`, `CLAUDE.md` et `CHANGELOG.md` : aucun `{{…}}` ne doit rester.
