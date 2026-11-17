#!/usr/bin/env python3
"""Turns the frames of the demo run into a short video (spec 17.5a).

The run is filmed in real time, but the download and the work of the models
on a virtual Mac without a GPU take minutes. Those stretches are shown
faster: each becomes at most FAST_FRAMES frames, and the caption in the
picture says how long it really took. Everything else stays real time.

Usage: make-demo-video.py <demo dir>
  <demo dir>/frames/00000.jpg …   the frames, one every FRAME seconds
  <demo dir>/times.txt            "<frame index> <unix seconds>" per frame
  <demo dir>/demo.txt             the log of DemoRun, with the phases
Writes <demo dir>/frames.txt, the input of ffmpeg's concat demuxer.
"""

import datetime
import pathlib
import sys

FRAME = 0.4
FAST_FRAMES = 25
# Phases of DemoRun that are waiting, by the start of their caption.
FAST = ("Жму «Скачать»", "Распознаю речь", "Enter:")


def main():
    demo = pathlib.Path(sys.argv[1])
    times = {}
    for line in (demo / "times.txt").read_text().splitlines():
        index, seconds = line.split()
        times[int(index)] = int(seconds)
    phases = []
    for line in (demo / "demo.txt").read_text().splitlines():
        parts = line.split(" ", 3)
        if len(parts) < 4 or not parts[0][:4].isdigit():
            continue
        moment = datetime.datetime.strptime(" ".join(parts[:3]), "%Y-%m-%d %H:%M:%S %z").timestamp()
        phases.append((moment, parts[3].startswith(FAST)))
    frames = sorted(demo.glob("frames/*.jpg"))

    def is_fast(index):
        moment = times.get(index)
        if moment is None:
            return False
        current = False
        for start, fast in phases:
            if start <= moment:
                current = fast
        return current

    chosen = []
    run = []
    for frame in frames:
        index = int(frame.stem)
        if is_fast(index):
            run.append(frame)
            continue
        if run:
            step = max(1, len(run) // FAST_FRAMES)
            chosen += run[::step]
            run = []
        chosen.append(frame)
    if run:
        chosen += run[:: max(1, len(run) // FAST_FRAMES)]
    lines = [f"file '{frame.resolve()}'\nduration {FRAME}" for frame in chosen]
    if chosen:
        lines.append(f"file '{chosen[-1].resolve()}'")
    (demo / "frames.txt").write_text("\n".join(lines) + "\n")
    print(f"{len(frames)} frames, {len(chosen)} in the video, {len(chosen) * FRAME:.0f} s")


if __name__ == "__main__":
    main()
