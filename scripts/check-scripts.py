#!/usr/bin/env python3
"""Finds shell variables written right before a non-ASCII character.

The bash of macOS (3.2) reads the bytes of "«" or a Cyrillic letter as part of
the variable's name: "$commit»" becomes the unset variable "commit\\xc2" and
`set -u` stops the script (spec 18.10 E1). Such variables need braces:
"${commit}»".
"""
import pathlib
import re
import sys

BARE = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])")


def main():
    problems = []
    files = sorted(pathlib.Path("scripts").glob("*.sh")) + sorted(pathlib.Path(".github/workflows").glob("*.yml"))
    for path in files:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for match in BARE.finditer(line):
                problems.append(f"{path}:{number}: {match.group(0)} needs braces before a non-ASCII character")
    print("\n".join(problems) if problems else f"{len(files)} files, 0 problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
