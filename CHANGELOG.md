# Changements

## 0.1.0 — 2026-11-03

Fondations de l’application.

### Ajouté
- Fenêtre principale (1440 × 900 par défaut, 1100 × 700 au minimum), interface claire.
- Barre latérale bleu nuit fidèle aux croquis : groupes Découverte, Diagnostic, Suivi et
  Accès, plages enregistrées, Réglages, interface active, version et pastille de mise à jour.
- Barre d’outils du contenu : titre de l’écran, recherche globale, actions propres à l’écran.
- Quatorze écrans provisoires (« En construction ») qui décrivent ce qu’ils feront.
- Thème (couleurs, polices, rayons, styles de boutons) et composants communs : panneau,
  intertitre, ligne clé-valeur, puce, pastille d’état, étiquette de port, courbe, état vide.
- Moteur d’adressage : adresses IPv4, plages (CIDR, début-fin, adresse seule, listes, limite de
  65 536 adresses), calculateur de sous-réseaux et découpage, adresses MAC, table des fabricants
  et détection des adresses MAC aléatoires.
- Modèles partagés : appareil, plage enregistrée, profils de scan (Rapide, Complet, Ports
  courants, Personnalisé).
- Détection de l’interface active (sans trafic réseau) ; au premier lancement, la plage
  proposée est celle de son réseau.
- Enregistrement des plages et des noms personnalisés dans
  `~/Library/Application Support/NetScope/etat.json`.
- Captures hors écran (`--snapshot <dossier>`) et données de démonstration (`--demo`).
- Tests du moteur (`NetScopeSelfTest`), icône, `build.sh`.
