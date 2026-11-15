#!/usr/bin/env python3
"""Checks what `Stickflow --transcribe` printed (the CI job "asr").

Usage: check-transcripts.py <log>
Whatever was said must come back as Russian text; the phrase spoken by the
system voice must keep its key words.
"""

import re
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.startswith("TRANSCRIPT")]
if not lines:
    sys.exit("nothing was recognised")
problems = []
for line in lines:
    text = line.split("]:", 1)[-1].lower()
    if not re.search("[а-яё]{3,}", text):
        problems.append(f"no Russian text: {line}")
    if line.startswith("TRANSCRIPT said.wav"):
        for word in ("молоко", "маме", "созвон"):
            if word not in text:
                problems.append(f"«{word}» is missing: {line}")
for problem in problems:
    print(problem)
print(f"{len(lines)} transcripts, {len(problems)} problems")
sys.exit(1 if problems else 0)
