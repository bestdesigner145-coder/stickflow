# Stickflow

A sticky note for your Mac screen that stays visible and never gets in the way. Clicks pass through it, it fades under the cursor, and holding ⌥ turns it into paper you can edit.

Стикер на экране Mac, который всегда на виду и не мешает работать. Клики проходят сквозь него, под курсором он выцветает, а с зажатым ⌥ становится бумагой, которую можно править.

> Status: early development, stage 1 of 6. Not ready for everyday use yet.
> Статус: ранняя разработка, этап 1 из 6. Для ежедневной работы пока не готов.

## Build from source · Сборка из исходников

Requirements: macOS 14 or later, Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Stickflow.xcodeproj
```

Run the `Stickflow` scheme. The app has no Dock icon: look for the sticker icon in the menu bar.

The Xcode project is generated from `project.yml` and is not committed. Run `xcodegen generate` again after pulling changes that add or remove files.

Проект Xcode собирается из `project.yml` и в репозитории не хранится. После обновления, в котором появились или исчезли файлы, запустите `xcodegen generate` ещё раз.

## Tests · Тесты

```sh
swift test --package-path StickflowCore   # models, editor rules, geometry
xcodebuild test -project Stickflow.xcodeproj -scheme StickflowStoreTests -destination 'platform=macOS'   # storage
```

A debug build can also check itself: `Stickflow --self-check <folder>` creates stickers through the real editor, verifies what was saved and writes snapshots into the folder. It uses its own database. CI runs it on every push.

Отладочная сборка умеет проверять сама себя: `Stickflow --self-check <папка>` создаёт стикеры через настоящий редактор, сверяет сохранённое и кладёт снимки в папку. База у проверки своя. CI запускает её при каждом пуше.

## Layout · Структура

```
StickflowCore/   Swift package without AppKit: models, editor rules, geometry
App/             entry point, app delegate, menu bar, dependency container
Features/        Sticker (window, editor, state machine), Debug (tuning panel)
Services/        Store (GRDB), preferences, displays, hotkey, login item
Resources/       Localizable.xcstrings (EN, RU)
Tuning.swift     every tunable number in one place
```

Forking? Change the bundle identifier (`STICKFLOW_BUNDLE_ID` in `project.yml`) before you distribute a build.

## License · Лицензия

GPL-3.0. See `LICENSE`.
