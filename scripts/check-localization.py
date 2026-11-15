#!/usr/bin/env python3
"""Checks the string catalog (spec 17.3, lint stage).

Fails when a key lacks a Russian or an English translation, or when the code asks
for a key the catalog does not have. Keys nobody uses are listed as a note.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
LANGUAGES = ("en", "ru")
SOURCE_DIRS = ("App", "Features", "Services")
KEY_PATTERN = re.compile(r'String\(localized:\s*"([^"\\]+)"')


def translated(entry: dict, language: str) -> bool:
    localization = entry.get("localizations", {}).get(language)
    if not localization:
        return False
    unit = localization.get("stringUnit")
    if unit:
        return unit.get("state") == "translated" and bool(unit.get("value", "").strip())
    # Plural and device variations carry their own string units.
    return "variations" in localization


def main() -> int:
    strings = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    problems = []

    for key, entry in sorted(strings.items()):
        for language in LANGUAGES:
            if not translated(entry, language):
                problems.append(f"{key}: no {language.upper()} translation")

    used = set()
    for directory in SOURCE_DIRS:
        for path in (ROOT / directory).rglob("*.swift"):
            used.update(KEY_PATTERN.findall(path.read_text(encoding="utf-8")))
    for key in sorted(used - strings.keys()):
        problems.append(f"{key}: used in code, missing from the catalog")

    for key in sorted(strings.keys() - used):
        print(f"note: {key} is not used in code")

    for problem in problems:
        print(f"error: {problem}")
    print(f"{len(strings)} keys, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
