# ShotPaste

Native, lokal arbeitende Bildschirmaufnahme für macOS und Windows.

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) ·
[Español](README.es.md) · [日本語](README.ja.md) ·
[한국어](README.ko.md) · [Русский](README.ru.md) ·
[Français](README.fr.md) · **Deutsch**

**Offizielle Website:** [shotpaste.com](https://www.shotpaste.com/)

ShotPaste bietet unabhängige native Anwendungen für macOS und Windows.
Aufnahmen, OCR, Bildschirmvideos, Verlauf, Zwischenablage und Einstellungen
bleiben auf dem Gerät. Das Projekt bietet weder Konten noch Telemetrie,
Cloud-Uploads, entfernten Speicher oder Synchronisierung.

## Funktionen

- **One Shot:** Bereich einmal auswählen und danach Screenshot,
  Scroll-Aufnahme, Aufnahme, Übersetzung oder Zwischenablageverlauf wählen.

  [![One-Shot-Modusauswahl](assets/readme/oneshot.gif)](assets/readme/oneshot.gif)

- **Screenshots und OCR:** Auswahl im eingefrorenen Bild, Fenstererkennung,
  lokale Texterkennung sowie konfigurierbares Format, Benennung, Skalierung,
  Mauszeiger und Desktopoptionen.

  [![Lokale OCR aus einem Screenshot](assets/readme/OCR.gif)](assets/readme/OCR.gif)

- **Übersetzung:** Text aus einem eingefrorenen One-Shot-Bereich mit lokaler OCR,
  automatischer Erkennung der Ausgangssprache, konfigurierbaren Zielsprachen und
  einem vom Benutzer eingerichteten Provider übersetzen. Nur der erkannte Text
  wird zur Übersetzung gesendet.

  [![Screenshot-Übersetzung](assets/readme/translate.gif)](assets/readme/translate.gif)

- **Integrierte Anmerkungen:** Auswahl, Formen, Pfeile, Text, Textmarker,
  Mosaik, Fokus, Zähler, Stift, Rückgängig/Wiederholen, QR, Kopieren und
  Anheften.

  [![Werkzeuge für integrierte Anmerkungen](assets/readme/inline.gif)](assets/readme/inline.gif)

- **Scroll-Aufnahme:** manuelles oder automatisches Scrollen, Live-Vorschau,
  Schutz vor Duplikaten und falscher Richtung sowie Zusammensetzen langer Bilder.

  [![Scroll-Aufnahme](assets/readme/scroll.gif)](assets/readme/scroll.gif)

- **Aufnahme:** Bereichsvideo oder GIF, Systemaudio, Mikrofon, Maus- und
  Klickeffekte, Tastenanzeige, Pause, Neustart, Verwerfen, Einzelbilder und
  Live-Zeichnen.

  [![Aufnahme mit Live-Anmerkungen](assets/readme/recording.gif)](assets/readme/recording.gif)

- **Quick Access und Pins:** konfigurierbare Karten, Kopieren/Speichern/Öffnen,
  Zieh- und Wischaktionen sowie stets sichtbare Bild-Pins.

  [![Quick-Access-Bild-Pin](assets/readme/quickaccess-pin.gif)](assets/readme/quickaccess-pin.gif)

  [![Mehrere stets sichtbare Bild-Pins](assets/readme/pin.gif)](assets/readme/pin.gif)

- **Zwischenablageverlauf:** lokaler SQLite-Verlauf für Screenshots,
  Aufnahmen, Text, Bilder und Dateien mit Suche, Filtern, Aufbewahrung und
  Bereinigung.

  [![Durchsuchbarer Aufnahme- und Zwischenablageverlauf](assets/readme/clipboard-history.gif)](assets/readme/clipboard-history.gif)

- **Anpassung:** globale Tastenkürzel, Aktionen nach der Aufnahme,
  Ausgabeordner, Darstellung, Diagnose, URL-Befehle und zehn Sprachen.

  [![ShotPaste-Einstellungen](assets/readme/settings.gif)](assets/readme/settings.gif)

Siehe [vollständige Funktionsliste](docs/FEATURES.md).

## Plattformen

| | macOS | Windows |
| --- | --- | --- |
| Voraussetzungen | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| Native Technologien | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32 und Windows-APIs für Aufnahme/OCR/Medien |
| Quellcode | `platforms/mac` | `platforms/windows` |

Die Anwendungen teilen Produktverhalten und Lokalisierungsressourcen, jedoch
weder Anwendungscode noch ein plattformübergreifendes UI-Framework.

## Erstellen

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Debug
```

Siehe [Projektstruktur und Build-Anleitung](docs/DEVELOPMENT.md).

## Downloads und Lizenz

Aktuelle macOS- und Windows-Pakete stehen unter
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases) bereit.
ShotPaste wird unter der [BSD-3-Klausel-Lizenz](LICENSE) veröffentlicht.

### Danksagungen und Quellhistorie

ShotPaste dankt [Snapzy](https://github.com/duongductrong/Snapzy) und
[ShareX](https://github.com/ShareX/ShareX). Ihre Open-Source-Arbeit war bei der
Entwicklung dieses Projekts eine wesentliche Hilfe und Inspiration.

Der macOS-Client ging unter der BSD-3-Klausel-Lizenz aus dem Snapzy-Commit
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274)
hervor und hat sich seitdem erheblich davon entfernt. Der Windows-Client ist
eine eigenständige native Umsetzung desselben ShotPaste-Produktablaufs, die
teilweise auch durch die Untersuchung von ShareX geprägt wurde.

Die erforderlichen Urheberrechts- und Lizenztexte von Drittanbietern sind in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) enthalten.

Hinweise zu Beiträgen, Hilfe und Sicherheitsmeldungen stehen in
[CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) und
[SECURITY.md](SECURITY.md).
