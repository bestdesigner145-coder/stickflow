#!/usr/bin/env python3
"""Copies a speech model from Hugging Face into a release of this repository.

Spec 7: the app downloads the model from GitHub Releases first and from
Hugging Face as a fallback. This script fetches every file of the model at a
pinned revision, works out sizes and SHA-256 sums, and writes:

  <out>/assets/    the files under flat names, ready for `gh release create`
  <out>/manifest.json   what the app needs: paths, sizes, sums, both sources
  <out>/notes.md   the text of the release, with the licence and the authors

Usage: mirror-model.py <source.json> <out-dir>
"""

import hashlib
import json
import os
import pathlib
import shutil
import sys
import urllib.request

HUB = "https://huggingface.co"


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def download(url, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(url, timeout=300) as response, open(target, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def main():
    source = json.loads(pathlib.Path(sys.argv[1]).read_text())
    out = pathlib.Path(sys.argv[2])
    repository = os.environ.get("GITHUB_REPOSITORY", "owner/repo")

    info = fetch_json(f"{HUB}/api/models/{source['repo']}/revision/{source['revision']}")
    revision = info["sha"]
    paths = sorted(entry["rfilename"] for entry in info["siblings"])
    print(f"{source['repo']} at {revision}: {len(paths)} files")

    files = []
    assets = out / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    for path in paths:
        if path.startswith(".git"):
            continue
        local = out / "files" / path
        size, digest = download(f"{HUB}/{source['repo']}/resolve/{revision}/{path}", local)
        asset = path.replace("/", "__").replace(" ", "_")
        shutil.copyfile(local, assets / asset)
        files.append({"path": path, "asset": asset, "size": size, "sha256": digest})
        print(f"  {size:>11}  {digest}  {path}")

    manifest = {
        "id": source["id"],
        "revision": revision,
        "license": "MIT",
        "sources": {
            "release": f"https://github.com/{repository}/releases/download/{source['tag']}/",
            "huggingFace": f"{HUB}/{source['repo']}/resolve/{revision}/",
        },
        "files": files,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    total = sum(entry["size"] for entry in files)
    (out / "notes.md").write_text(
        f"Speech recognition model for Stickflow: GigaAM-v3 `e2e_rnnt`, Core ML, fp16.\n\n"
        f"An unchanged copy of [{source['repo']}]({HUB}/{source['repo']}) at revision `{revision}`, "
        f"{len(files)} files, {total / 1e6:.0f} MB. The app downloads it on the first press of the microphone "
        f"and checks every file against its SHA-256 sum.\n\n"
        f"- Model: GigaAM-v3 © GigaChat Team / SaluteDevices, MIT licence — {HUB}/ai-sage/GigaAM-v3\n"
        f"- Core ML conversion © 2026 Sergey Makarov (smkrv), MIT licence\n\n"
        f"This is not a release of the app.\n"
    )

    # What the engine in the app has to match exactly.
    for name in ("model_info.json", "convert_info.json", "example_infer.py", "v3_e2e_rnnt.yaml"):
        local = out / "files" / name
        if local.exists():
            print(f"\n===== {name} =====")
            print(local.read_text())
    tokens = out / "files" / "tokens.json"
    if tokens.exists():
        loaded = json.loads(tokens.read_text())
        print(f"\n===== tokens.json: {type(loaded).__name__}, {len(loaded)} entries =====")
        print(json.dumps(loaded if isinstance(loaded, dict) else loaded[:80], ensure_ascii=False)[:3000])
    print("\n===== manifest.json =====")
    print((out / "manifest.json").read_text())


if __name__ == "__main__":
    main()
