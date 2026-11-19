#!/usr/bin/env python3
"""Copies the structuring model (one GGUF file) into a release of this repository.

Spec 18.10 A2 and 11.4: the app downloads the model from GitHub Releases
first and from Hugging Face as a fallback, checks it with SHA-256 and resumes
a broken download. A release file may not exceed 2 GB, so the model is cut
into pieces; each piece has its own sum, and Hugging Face serves the same
bytes by range.

Writes:
  <out>/assets/          the pieces, ready for `gh release create`
  <out>/manifest.json    what the app needs (Resources/Models/<id>.json)
  <out>/notes.md         the text of the release, with the licence

Usage: mirror-gguf.py <source.json> <out-dir>
"""

import hashlib
import json
import os
import pathlib
import sys
import urllib.request

HUB = "https://huggingface.co"
PIECE = 512 * 1024 * 1024


def main():
    source = json.loads(pathlib.Path(sys.argv[1]).read_text())
    out = pathlib.Path(sys.argv[2])
    repository = os.environ.get("GITHUB_REPOSITORY", "owner/repo")
    assets = out / "assets"
    assets.mkdir(parents=True, exist_ok=True)

    with urllib.request.urlopen(f"{HUB}/api/models/{source['repo']}/revision/{source['revision']}", timeout=60) as response:
        revision = json.load(response)["sha"]
    url = f"{HUB}/{source['repo']}/resolve/{revision}/{source['file']}"
    print(f"{source['repo']} at {revision}: {source['file']}")

    whole = hashlib.sha256()
    parts = []
    offset = 0
    stem = source["id"]
    with urllib.request.urlopen(url, timeout=600) as response:
        index = 0
        while True:
            piece = hashlib.sha256()
            size = 0
            name = f"{stem}.gguf.part{index:02d}"
            with open(assets / name, "wb") as target:
                while size < PIECE:
                    chunk = response.read(min(1 << 20, PIECE - size))
                    if not chunk:
                        break
                    target.write(chunk)
                    piece.update(chunk)
                    whole.update(chunk)
                    size += len(chunk)
            if size == 0:
                (assets / name).unlink()
                break
            parts.append({"asset": name, "offset": offset, "size": size, "sha256": piece.hexdigest()})
            print(f"  {name}  {size:>11}  {piece.hexdigest()}")
            offset += size
            index += 1

    manifest = {
        "id": source["id"],
        "name": source["name"],
        "revision": revision,
        "license": source["license"],
        "sources": {
            "release": f"https://github.com/{repository}/releases/download/{source['tag']}/",
            "huggingFace": f"{HUB}/{source['repo']}/resolve/{revision}/",
        },
        "files": [{"path": source["file"], "size": offset, "sha256": whole.hexdigest(), "parts": parts}],
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "notes.md").write_text(
        f"Model that sorts dictation into tasks for Stickflow: {source['name']}, GGUF {source['quantization']}.\n\n"
        f"An unchanged copy of `{source['file']}` from [{source['repo']}]({HUB}/{source['repo']}) at revision "
        f"`{revision}`, {offset / 1e9:.2f} GB, cut into {len(parts)} pieces of at most 512 MB "
        f"(a release file may not exceed 2 GB). The app joins them and checks every piece and the whole file "
        f"against their SHA-256 sums.\n\n"
        f"- Model: {source['credit']}, {source['license']} licence\n\n"
        f"This is not a release of the app.\n"
    )
    print("\n===== manifest.json =====")
    print((out / "manifest.json").read_text())


if __name__ == "__main__":
    main()
