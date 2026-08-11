# ShotPaste

Capture et enregistrement d’écran natifs et locaux pour macOS et Windows.

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) ·
[Español](README.es.md) · [日本語](README.ja.md) ·
[한국어](README.ko.md) · [Русский](README.ru.md) · **Français** ·
[Deutsch](README.de.md)

**Site officiel :** [shotpaste.com](https://www.shotpaste.com/)

ShotPaste propose des clients natifs indépendants pour macOS et Windows. Les
captures, l’OCR, les enregistrements, l’historique, le presse-papiers et les
réglages restent sur l’appareil. Le projet ne propose ni compte, ni télémétrie,
ni envoi vers le cloud, ni stockage distant, ni synchronisation.

## Fonctionnalités

- **One Shot :** sélectionnez une zone une seule fois, puis choisissez Capture,
  Capture avec défilement, Enregistrement ou Historique du presse-papiers.
- **Captures :** sélection sur image figée, ciblage des fenêtres, format,
  nommage, échelle, curseur et options du bureau configurables.
- **Annotation intégrée :** sélection, formes, flèches, texte, surligneur,
  mosaïque, projecteur, compteur, crayon, annuler/rétablir, OCR, QR, copie et
  épinglage.
- **Capture avec défilement :** défilement manuel ou automatique, aperçu en
  direct, contrôle des doublons et du sens, assemblage en image longue.
- **Enregistrement :** vidéo de zone ou GIF, son système, microphone, effets du
  pointeur, affichage des touches, pause, reprise, suppression, instantanés et
  dessin en direct.
- **Quick Access et épingles :** cartes configurables, copier/enregistrer/ouvrir,
  glisser, balayer, compte à rebours et images toujours visibles.
- **Historique du presse-papiers :** stockage SQLite local des captures,
  enregistrements, textes, images et fichiers, avec recherche, filtres,
  conservation et nettoyage.
- **Personnalisation :** raccourcis globaux, actions après capture, dossier de
  sortie, apparence, diagnostics, commandes URL et dix langues d’interface.

Consultez la [liste complète des fonctionnalités](docs/FEATURES.md).

## Galerie des fonctionnalités

| **One Shot** | **Captures** |
|:---:|:---:|
| [![Sélecteur de mode One Shot](assets/readme/one-shot.png)](assets/readme/one-shot.png) | [![Zone et barre d’outils de capture](assets/readme/screenshots.png)](assets/readme/screenshots.png) |
| **Annotation intégrée** | **Capture avec défilement** |
| [![Outils d’annotation intégrée](assets/readme/inline-annotation.png)](assets/readme/inline-annotation.png) | [![Zone de capture avec défilement](assets/readme/scrolling-capture.png)](assets/readme/scrolling-capture.png) |
| **Enregistrement** | **Quick Access et épingles** |
| [![Zone et options d’enregistrement](assets/readme/recording.png)](assets/readme/recording.png) | [![Carte Quick Access et image épinglée](assets/readme/quick-access-pins.png)](assets/readme/quick-access-pins.png) |
| **Historique du presse-papiers** | **Personnalisation** |
| [![Historique consultable des captures et du presse-papiers](assets/readme/clipboard-history.png)](assets/readme/clipboard-history.png) | [![Réglages de personnalisation des captures](assets/readme/customization.png)](assets/readme/customization.png) |

## Plateformes

| | macOS | Windows |
| --- | --- | --- |
| Prérequis | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| Technologies natives | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32 et API Windows de capture/OCR/média |
| Code source | `platforms/mac` | `platforms/windows` |

Les clients partagent le comportement du produit et les ressources de
localisation, mais pas le code de l’application ni un framework d’interface
multiplateforme.

## Compilation

macOS :

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell :

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

Consultez la [structure du projet et les instructions de
compilation](docs/DEVELOPMENT.md).

## Téléchargements et licence

Les paquets macOS et Windows actuels sont disponibles dans
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases). ShotPaste
est distribué sous [licence BSD à 3 clauses](LICENSE).

### Remerciements et historique du code source

ShotPaste remercie [Snapzy](https://github.com/duongductrong/Snapzy) et
[ShareX](https://github.com/ShareX/ShareX). Leurs travaux open source ont
constitué une aide et une source d’inspiration importantes pendant le
développement de ce projet.

Le client macOS est issu du commit Snapzy
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274),
publié sous licence BSD à 3 clauses, et s’en est depuis considérablement écarté.
Le client Windows est une implémentation native indépendante du même parcours
produit ShotPaste, également éclairée en partie par l’étude de ShareX.

Les mentions de copyright et textes de licence tiers qui doivent être conservés
figurent dans [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Consultez [CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) et
[SECURITY.md](SECURITY.md) pour contribuer, demander de l’aide ou effectuer un
signalement responsable.
