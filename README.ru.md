# ShotPaste

Нативный инструмент локального захвата и записи экрана для macOS и Windows.

[English](README.md) · [Tiếng Việt](README.vi.md) ·
[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) ·
[Español](README.es.md) · [日本語](README.ja.md) ·
[한국어](README.ko.md) · **Русский** · [Français](README.fr.md) ·
[Deutsch](README.de.md)

**Официальный сайт:** [shotpaste.com](https://www.shotpaste.com/)

ShotPaste содержит независимые нативные клиенты для macOS и Windows. Снимки,
OCR, записи, история, буфер обмена и настройки остаются на устройстве. Проект
не предоставляет учётные записи, телеметрию, облачную загрузку, удалённое
хранилище или синхронизацию.

## Возможности

- **One Shot:** один раз выберите область, затем используйте снимок, прокрутку,
  запись или историю буфера обмена.

  [![Выбор режима One Shot](assets/readme/oneshot.gif)](assets/readme/oneshot.gif)

- **Снимки и OCR:** замороженная область выбора, распознавание окон и текста
  на устройстве, формат, имена, масштаб, курсор и параметры рабочего стола.

  [![Локальное OCR снимка](assets/readme/OCR.gif)](assets/readme/OCR.gif)

- **Встроенные аннотации:** выбор, фигуры, стрелки, текст, маркер, мозаика,
  прожектор, счётчик, карандаш, отмена/повтор, QR, копирование и закрепление.

  [![Инструменты встроенных аннотаций](assets/readme/inline.gif)](assets/readme/inline.gif)

- **Захват прокрутки:** ручная/автоматическая прокрутка, предпросмотр, защита от
  смены направления и дубликатов, склейка длинных изображений.

  [![Захват прокрутки](assets/readme/scroll.gif)](assets/readme/scroll.gif)

- **Запись:** видео области или GIF, системный звук, микрофон, эффекты мыши,
  показ клавиш, пауза, перезапуск, удаление, снимки и рисование в реальном времени.

  [![Запись с аннотациями в реальном времени](assets/readme/recording.gif)](assets/readme/recording.gif)

- **Quick Access и закрепления:** настраиваемые карточки, копирование/сохранение/
  открытие, перетаскивание, жесты и изображения поверх окон.

  [![Закрепление изображения из Quick Access](assets/readme/quickaccess-pin.gif)](assets/readme/quickaccess-pin.gif)

  [![Несколько изображений поверх окон](assets/readme/pin.gif)](assets/readme/pin.gif)

- **История буфера обмена:** локальная SQLite для снимков, записей, текста,
  изображений и файлов с поиском, фильтрами, сроком хранения и очисткой.

  [![История снимков и буфера обмена с поиском](assets/readme/clipboard-history.gif)](assets/readme/clipboard-history.gif)

- **Настройка:** глобальные сочетания клавиш, действия после захвата, папка
  вывода, оформление, диагностика, URL-команды и десять языков.

  [![Настройки ShotPaste](assets/readme/settings.gif)](assets/readme/settings.gif)

См. [полный список функций](docs/FEATURES.md).

## Платформы

| | macOS | Windows |
| --- | --- | --- |
| Требования | macOS 13+, Apple Silicon | Windows 10 2004+, x64 |
| Нативные технологии | SwiftUI, AppKit, ScreenCaptureKit, Vision | WPF, Win32 и API Windows для захвата/OCR/медиа |
| Исходный код | `platforms/mac` | `platforms/windows` |

Клиенты разделяют поведение продукта и ресурсы локализации, но не код
приложения и не кроссплатформенный UI-фреймворк.

## Сборка

macOS:

```bash
./scripts/build_and_run.sh build
./scripts/run-tests.sh
```

Windows PowerShell:

```powershell
./scripts/build-windows.ps1 -Configuration Debug
```

См. [структуру проекта и инструкции по сборке](docs/DEVELOPMENT.md).

## Загрузки и лицензия

Актуальные пакеты для macOS и Windows доступны в
[GitHub Releases](https://github.com/shotpaste/shotpaste/releases). ShotPaste
выпускается по [лицензии BSD 3-Clause](LICENSE).

### Благодарности и история исходного кода

ShotPaste благодарит проекты [Snapzy](https://github.com/duongductrong/Snapzy)
и [ShareX](https://github.com/ShareX/ShareX). Их открытый исходный код оказал
существенную помощь и послужил источником вдохновения при разработке проекта.

Клиент для macOS берёт начало от коммита Snapzy
[`a6f8edf01a48e9dd9bdc4212b0e3472725219274`](https://github.com/duongductrong/Snapzy/commit/a6f8edf01a48e9dd9bdc4212b0e3472725219274),
опубликованного по лицензии BSD 3-Clause, и с тех пор значительно изменился.
Клиент для Windows представляет собой независимую нативную реализацию того же
рабочего процесса ShotPaste, при разработке которой также частично учитывался
опыт ShareX.

Обязательные уведомления об авторских правах и тексты лицензий сторонних
компонентов сохранены в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Правила участия, получения помощи и ответственного сообщения об ошибках см. в
[CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) и
[SECURITY.md](SECURITY.md).
