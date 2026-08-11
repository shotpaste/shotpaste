# ShotPaste

Native, lokal arbeitende Bildschirmaufnahme für macOS und Windows.

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) ·
[Español](README.es.md) · [日本語](README.ja.md) ·
[한국어](README.ko.md) · [Русский](README.ru.md) ·
[Français](README.fr.md) · **Deutsch**

ShotPaste bietet unabhängige native Anwendungen für macOS und Windows.
Aufnahmen, OCR, Bildschirmvideos, Verlauf, Zwischenablage und Einstellungen
bleiben auf dem Gerät. Das Projekt bietet weder Konten noch Telemetrie,
Cloud-Uploads, entfernten Speicher oder Synchronisierung.

## Funktionen

- **One Shot:** Bereich einmal auswählen und danach Screenshot,
  Scroll-Aufnahme, Aufnahme oder Zwischenablageverlauf wählen.
- **Screenshots:** Auswahl im eingefrorenen Bild, Fenstererkennung sowie
  konfigurierbares Format, Benennung, Skalierung, Mauszeiger und Desktopoptionen.
- **Integrierte Anmerkungen:** Auswahl, Formen, Pfeile, Text, Textmarker,
  Mosaik, Fokus, Zähler, Stift, Rückgängig/Wiederholen, OCR, QR, Kopieren und
  Anheften.
- **Scroll-Aufnahme:** manuelles oder automatisches Scrollen, Live-Vorschau,
  Schutz vor Duplikaten und falscher Richtung sowie Zusammensetzen langer Bilder.
- **Aufnahme:** Bereichsvideo oder GIF, Systemaudio, Mikrofon, Maus- und
  Klickeffekte, Tastenanzeige, Pause, Neustart, Verwerfen, Einzelbilder und
  Live-Zeichnen.
- **Quick Access und Pins:** konfigurierbare Karten, Kopieren/Speichern/Öffnen,
  Zieh- und Wischaktionen, Countdown und stets sichtbare Bild-Pins.
- **Zwischenablageverlauf:** lokaler SQLite-Verlauf für Screenshots,
  Aufnahmen, Text, Bilder und Dateien mit Suche, Filtern, Aufbewahrung und
  Bereinigung.
- **Anpassung:** globale Tastenkürzel, Aktionen nach der Aufnahme,
  Ausgabeordner, Darstellung, Diagnose, URL-Befehle und zehn Sprachen.

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
./scripts/build-windows.ps1 -Configuration Debug
```

Siehe [Projektstruktur und Build-Anleitung](docs/DEVELOPMENT.md).

## Downloads und Lizenz

Aktuelle macOS- und Windows-Pakete stehen unter
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases) bereit.
ShotPaste wird unter der [BSD-3-Klausel-Lizenz](LICENSE) veröffentlicht.
Danksagungen und Quellhistorie stehen in [NOTICE.md](NOTICE.md), die Lizenzen
der Abhängigkeiten in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Hinweise zu Beiträgen, Hilfe und Sicherheitsmeldungen stehen in
[CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) und
[SECURITY.md](SECURITY.md).
