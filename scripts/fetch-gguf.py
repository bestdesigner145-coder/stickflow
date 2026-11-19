#!/usr/bin/env python3
"""Downloads one GGUF file of a Hugging Face repository and checks it.

    scripts/fetch-gguf.py <repo> <pattern> <out.gguf> [<facts.json>]

Picks the file whose name ends with <pattern> (the language model, never a
vision projector), pins the repository's revision, downloads the file with
curl (which resumes) and checks its SHA-256 against the one Hugging Face
publishes. Writes what the app's manifest needs into <facts.json>.
"""
import hashlib
import json
import subprocess
import sys
import urllib.request


def main():
    repo, pattern, out = sys.argv[1], sys.argv[2], sys.argv[3]
    facts_path = sys.argv[4] if len(sys.argv) > 4 else None
    with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}?blobs=true", timeout=60) as answer:
        info = json.load(answer)
    revision = info["sha"]
    files = [s for s in info.get("siblings", [])
             if s["rfilename"].lower().endswith(pattern.lower()) and "mmproj" not in s["rfilename"].lower()]
    # The shortest name is the plain quant, not a "UD-" or imatrix variant of it.
    files.sort(key=lambda s: (len(s["rfilename"]), s["rfilename"]))
    if not files:
        sys.exit(f"{repo}: no file ends with {pattern}")
    chosen = files[0]
    name = chosen["rfilename"]
    expected = (chosen.get("lfs") or {}).get("sha256")
    size = chosen.get("size") or (chosen.get("lfs") or {}).get("size")
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{name}"
    print(f"{repo}@{revision[:12]}: {name}, {size} bytes", flush=True)
    subprocess.run(["curl", "-fL", "--retry", "5", "--retry-all-errors", "-C", "-", "-o", out, url], check=True)
    digest = hashlib.sha256()
    with open(out, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 22), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if expected and actual != expected:
        sys.exit(f"{name}: SHA-256 {actual} is not the published {expected}")
    if facts_path:
        with open(facts_path, "w") as stream:
            json.dump({"repo": repo, "revision": revision, "file": name, "size": size, "sha256": actual, "url": url},
                      stream, indent=2)
    print(f"ok, sha256 {actual}")


if __name__ == "__main__":
    main()
