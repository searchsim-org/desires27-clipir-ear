"""Static egress check (HANDOVER §2.5): forbidden patterns + URL hosts outside the allow-list.

Usage: python3 tools/ci/egress_check.py [root]   → exit 1 and one line per hit on failure.
The runtime ConnectionLedger (P1.7) covers what a static grep cannot.
"""

import json
import re
import sys
from pathlib import Path

SCAN_DIRS = ["Sources", "Tests", "apps", "mac", "tools"]
SKIP_DIRS = {
    ".venv",
    ".build",
    "DerivedData",
    "__pycache__",
    "node_modules",
    "ci",
}  # ci = these checkers
CODE_SUFFIXES = {
    ".swift",
    ".py",
    ".json",
    ".plist",
    ".toml",
    ".sh",
    ".yml",
    ".yaml",
    ".txt",
    ".h",
    ".c",
}
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"}
# Apple plist doctype names a DTD, it is never fetched
DOCTYPE_RE = re.compile(
    r"^<!DOCTYPE plist PUBLIC .* \"http://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd\">$"
)
# JSON Schema "$schema" values are identifiers, never fetched
SCHEMA_ID_RE = re.compile(r'"\$schema": "https://json-schema\.org/draft/[0-9-]+/schema"')
URL_RE = re.compile(r"\b(?:https?|wss?)://([^/\s\"'`:)>\]]+)", re.I)


def iter_files(root: Path):
    for d in SCAN_DIRS:
        for p in (root / d).rglob("*"):
            if (
                p.is_file()
                and p.suffix in CODE_SUFFIXES
                and not SKIP_DIRS & set(p.relative_to(root).parts)
            ):
                yield p


def load_patterns(root: Path) -> list[str]:
    lines = (root / "tools/ci/forbidden.txt").read_text().splitlines()
    return [ln.strip().lower() for ln in lines if ln.strip() and not ln.startswith("#")]


def allowed_hosts(root: Path) -> set[str]:
    return LOCAL_HOSTS | set(
        json.loads((root / "tools/models/sources.json").read_text())["allowed_hosts"]
    )


def check(root: Path) -> list[str]:
    patterns, hosts, hits = load_patterns(root), allowed_hosts(root), []
    for p in iter_files(root):
        rel = p.relative_to(root)
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            low = line.lower()
            if DOCTYPE_RE.match(line.strip()):
                continue
            line = SCHEMA_ID_RE.sub("", line)
            hits += [f"{rel}:{n}: forbidden '{pat}'" for pat in patterns if pat in low]
            for host in URL_RE.findall(line):
                host = host.lower()
                # ponytail: placeholders like ws://<mac> or ${HOST} are not hosts; real ones must be allow-listed
                if not re.match(r"^[a-z0-9.\-\[\]:]+$", host) or host in hosts:
                    continue
                if not any(host.endswith("." + h) for h in hosts):
                    hits.append(f"{rel}:{n}: host '{host}' not in allow-list")
    return hits


if __name__ == "__main__":
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    hits = check(root)
    print("\n".join(hits) or "egress_check: OK")
    sys.exit(1 if hits else 0)
