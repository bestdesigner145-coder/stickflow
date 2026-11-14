# Stickflow — rules for the coding agent

Stickflow is a native macOS app: floating task stickers that never get in the way.

## Source of truth

The spec (ТЗ) is the source of truth. It lives in the Stickflow project on claude.ai as
`claude/TZ-sticker-flow.md`; `docs/stage-N.md` records what each stage delivered and
where the code deviates. If the code and the spec disagree, ask the author first, then
change the code or the spec. Never work around a macOS limitation silently: describe it
and offer one or two options (spec 0.4).

## How to work

- Work in the stages of spec section 14. Do not start a stage before the author accepts the previous one.
- Short branches, Conventional Commits (`feat:`, `fix:`, `chore:` …), squash-merge. **Never merge into `main` yourself.**
- Code and comments in English. UI strings in `Resources/Localizable.xcstrings`, Russian and English both.
- No secrets in the repository. No network requests without the user's consent (spec 0.8).
- Every number (timing, size, threshold) goes into `Tuning.swift`; debatable behaviour gets a switch in the debug Tuning panel.

## Layout

```
StickflowCore/   Swift package, no AppKit: models, editor rules, geometry, sticker state machine
App/             entry point, dependency container, launch arguments, menu bar
Features/        Sticker (window, editor), Debug (Tuning panel, self-check)
Services/        Store (GRDB), preferences, displays, hotkeys, test doubles' protocols
Tests/           store tests, snapshot tests
```

`AppEnvironment` is the only container; everything else gets its dependencies passed in.
The outside world sits behind protocols (`Clock`, `ScreenGeometry`, `PointerSource`,
`StickerStore`) so that tests can replace it.

## Before you push

```sh
xcodegen generate
swiftformat --lint . && swiftlint lint --strict
swift test --package-path StickflowCore
xcodebuild test -project Stickflow.xcodeproj -scheme Stickflow -destination 'platform=macOS'
```

CI runs the same steps plus a Release build with warnings as errors, a coverage
threshold for `StickflowCore` (90%), the self-check
(`Stickflow --self-check <dir>`) and the snapshot tests.

## Done means

- logic has tests; for a bug, the failing test comes first;
- new UI has snapshots in both themes;
- lint is clean, no new warnings;
- strings exist in Russian and English;
- new animations follow spec 6.7 and respect Reduce Motion;
- the PR says how to check the change by hand.
