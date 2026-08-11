# ShotPaste

Captura y grabación de pantalla nativa y local para macOS y Windows.

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **Español** ·
[日本語](README.ja.md) · [한국어](README.ko.md) ·
[Русский](README.ru.md) · [Français](README.fr.md) ·
[Deutsch](README.de.md)

**Sitio web oficial:** [shotpaste.com](https://www.shotpaste.com/)

ShotPaste ofrece clientes nativos independientes para macOS y Windows. Las
capturas, el OCR, las grabaciones, el historial, el portapapeles y la
configuración permanecen en el dispositivo. El proyecto no ofrece cuentas,
telemetría, subida a la nube, almacenamiento remoto ni sincronización.

## Funciones

- **One Shot:** selecciona una zona una vez y elige Captura, Captura con
  desplazamiento, Grabación o Historial del portapapeles.
- **Capturas:** selección congelada, detección de ventanas, formato, nombres,
  escala, cursor y opciones del escritorio.
- **Anotación integrada:** selección, formas, flechas, texto, resaltador,
  mosaico, foco, contador, lápiz, deshacer/rehacer, OCR, QR, copiar y fijar.
- **Captura con desplazamiento:** desplazamiento manual/automático, vista
  previa, protección de dirección y duplicados, y unión de imágenes largas.
- **Grabación:** vídeo de región o GIF, audio del sistema, micrófono, efectos
  del ratón, teclas, pausa, reinicio, descarte, instantáneas y tinta en vivo.
- **Quick Access y fijados:** tarjetas configurables, copiar/guardar/abrir,
  arrastrar, deslizar, temporizador e imágenes siempre visibles.
- **Historial del portapapeles:** SQLite local para capturas, grabaciones,
  texto, imágenes y archivos, con búsqueda, filtros, retención y limpieza.
- **Personalización:** atajos globales, acciones posteriores, carpeta de salida,
  apariencia, diagnóstico, comandos URL y diez idiomas.

Consulta la [lista completa de funciones](docs/FEATURES.md).

## Plataformas

| | macOS | Windows |
| --- | --- | --- |
| Requisitos | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| Tecnología nativa | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32 y API de captura/OCR/multimedia de Windows |
| Código | `platforms/mac` | `platforms/windows` |

Los clientes comparten el comportamiento del producto y los recursos de idioma,
pero no el código de la aplicación ni un framework de interfaz multiplataforma.

## Compilación

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

Consulta la [estructura y guía de compilación](docs/DEVELOPMENT.md).

## Descargas y licencia

Los paquetes actuales para macOS y Windows están en
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases). ShotPaste
usa la [licencia BSD de 3 cláusulas](LICENSE).

### Agradecimientos e historial del código fuente

ShotPaste agradece a [Snapzy](https://github.com/duongductrong/Snapzy) y
[ShareX](https://github.com/ShareX/ShareX). Su trabajo de código abierto aportó
una ayuda e inspiración importantes durante el desarrollo de este proyecto.

El cliente para macOS partió del commit de Snapzy
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274),
publicado bajo la licencia BSD de 3 cláusulas, y desde entonces ha divergido de
forma considerable. El cliente para Windows es una implementación nativa e
independiente del mismo flujo de producto de ShotPaste, basada en parte en el
estudio de ShareX.

Los textos obligatorios de copyright y licencia de terceros se conservan en
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Consulta [CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) y
[SECURITY.md](SECURITY.md) para contribuir, pedir ayuda o informar de forma
responsable.
