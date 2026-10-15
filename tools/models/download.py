"""Download pinned models (HANDOVER P0.4, ADR-006). Run via `make models`, never directly.

- Every URL and every redirect hop must be on sources.json `allowed_hosts` (suffix match).
- SHA-256 is checked against sources.json, then models.lock.json; a file with no published hash is
  recorded on first download (trust on first use) and enforced from then on.
- Files land in ~/Library/Application Support/ClipIREar/models/<dir>/. *.tar.bz2 is unpacked there.
Usage: make models [ONLY="id1 id2"]   (ONLY may name default=false entries)
"""

import hashlib
import json
import os
import sys
import tarfile
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
MODELS_DIR = Path.home() / "Library/Application Support/ClipIREar/models"
CHUNK = 1 << 20


def host_allowed(url: str, hosts: list[str]) -> bool:
    u = urlparse(url)
    h = (u.hostname or "").lower()
    return u.scheme == "https" and any(h == a or h.endswith("." + a) for a in hosts)


class _GuardedRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, hosts):
        self.hosts = hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not host_allowed(newurl, self.hosts):
            raise PermissionError(f"redirect to non-allow-listed host: {urlparse(newurl).hostname}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url: str, out: Path, hosts: list[str]) -> str:
    """Stream url to out; return its SHA-256. Refuses any non-allow-listed hop."""
    if not host_allowed(url, hosts):
        raise PermissionError(f"host not allow-listed: {url}")
    opener = urllib.request.build_opener(_GuardedRedirects(hosts))
    digest, part = hashlib.sha256(), out.with_name(out.name + ".part")
    with opener.open(url, timeout=60) as r, open(part, "wb") as f:
        total, done = int(r.headers.get("Content-Length") or 0), 0
        while chunk := r.read(CHUNK):
            f.write(chunk)
            digest.update(chunk)
            done += len(chunk)
            if total:
                print(f"\r  {out.name}: {done * 100 // total}%", end="", flush=True)
    print()
    part.replace(out)
    return digest.hexdigest()


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def install(entry: dict, root: Path, lock: dict, hosts: list[str], fetch=fetch) -> None:
    """Download one entry if missing, verify it, record it in lock (mutated)."""
    name = Path(urlparse(entry["url"]).path).name
    dest = root / entry["dir"] / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    expected = entry.get("sha256") or lock.get(entry["id"], {}).get("sha256")
    if dest.exists() and expected and sha256_of(dest) == expected:
        print(f"  ok   {entry['id']} (cached)")
    else:
        got = fetch(entry["url"], dest, hosts)
        if expected and got != expected:
            dest.unlink()
            raise ValueError(f"{entry['id']}: sha256 {got} != expected {expected}")
        expected = got
        print(
            f"  got  {entry['id']}"
            + ("" if entry.get("sha256") else " (hash recorded on first use)")
        )
    if name.endswith(".tar.bz2"):
        with tarfile.open(dest) as t:
            t.extractall(dest.parent, filter="data")
    lock[entry["id"]] = {
        "file": f"{entry['dir']}/{name}",
        "url": entry["url"],
        "size": dest.stat().st_size,
        "sha256": expected,
        "licence": entry["licence"],
    }


def main(argv: list[str]) -> int:
    if os.environ.get("CLIPIR_EAR_MAKE_MODELS") != "1":
        print("refusing: run via `make models` (explicit user action, HANDOVER §2.5)")
        return 2
    sources = json.loads((HERE / "sources.json").read_text())
    lock_path = HERE / "models.lock.json"
    lock = (
        {m["id"]: m for m in json.loads(lock_path.read_text())["models"]}
        if lock_path.exists()
        else {}
    )
    only = set(argv)
    unknown = only - {m["id"] for m in sources["models"]}
    if unknown:
        print(f"unknown model id(s): {', '.join(sorted(unknown))}")
        return 2
    chosen = [m for m in sources["models"] if (m["id"] in only if only else m["default"])]
    print(f"models → {MODELS_DIR}")
    try:
        for entry in chosen:
            install(entry, MODELS_DIR, lock, sources["allowed_hosts"])
    finally:  # keep what succeeded even if a later download fails
        out = {"models": [{"id": k, **v} if "id" not in v else v for k, v in sorted(lock.items())]}
        lock_path.write_text(json.dumps(out, indent=2) + "\n")
    print(f"lock: {lock_path} ({len(lock)} entries)")
    print(
        "iOS: copy the folder into the app's Documents via Finder → iPhone → Files (UIFileSharingEnabled)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
