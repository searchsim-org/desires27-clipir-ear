"""Licence check (HANDOVER §2.6): every locked dependency and model must carry an allow-listed licence.

Sources of truth: LICENSES.md (allow-list line + inventory table) for packages in Package.resolved and
mac/earbridge/uv.lock (runtime dependencies only; dev tools are not shipped), and the "licence" field
of each entry in tools/models/models.lock.json.
Usage: python3 tools/ci/license_check.py [root]
"""

import json
import re
import sys
import tomllib
from pathlib import Path


def parse_licenses_md(text: str) -> tuple[set[str], dict[str, str]]:
    allow_line = text.split("## Allow-list", 1)[1].split("\n## ", 1)[0]
    allow = {re.sub(r"\s*\(.*?\)", "", t).strip().lower() for t in allow_line.strip().split(",")}
    inventory = {}
    for row in re.findall(r"^\|([^|\n]+)\|[^|\n]*\|([^|\n]+)\|", text, re.M):
        comp, lic = row[0].strip(), row[1].strip()
        if comp in ("Component", "---") or set(comp) <= {"-"}:
            continue
        for name in re.split(r"[,+]", comp):
            if name.strip():
                inventory[name.strip().split()[0].lower()] = lic
    return allow, inventory


def licence_ok(lic: str, allow: set[str]) -> bool:
    tokens = [re.sub(r"\s*\(.*?\)", "", t).strip().lower() for t in lic.split("/")]
    return all(t in allow for t in tokens if t)


def swift_packages(root: Path) -> list[str]:
    p = root / "Package.resolved"
    return [pin["identity"] for pin in json.loads(p.read_text())["pins"]] if p.exists() else []


def uv_runtime_packages(lock: Path) -> list[str]:
    if not lock.exists():
        return []
    pkgs = {p["name"]: p for p in tomllib.loads(lock.read_text())["package"]}
    roots = [
        p
        for p in pkgs.values()
        if p.get("source", {}).get("editable") or p.get("source", {}).get("virtual")
    ]
    seen, stack = set(), [d["name"] for r in roots for d in r.get("dependencies", [])]
    while stack:  # walk runtime deps only; dev-dependencies are not shipped
        name = stack.pop()
        if name not in seen:
            seen.add(name)
            stack += [d["name"] for d in pkgs.get(name, {}).get("dependencies", [])]
    return sorted(seen)


def check(root: Path) -> list[str]:
    allow, inventory = parse_licenses_md((root / "LICENSES.md").read_text())
    errors = []
    for name in swift_packages(root) + uv_runtime_packages(root / "mac/earbridge/uv.lock"):
        lic = inventory.get(name.lower())
        if lic is None:
            errors.append(f"{name}: not listed in LICENSES.md")
        elif not licence_ok(lic, allow):
            errors.append(f"{name}: licence '{lic}' not in allow-list")
    lock = root / "tools/models/models.lock.json"
    for m in json.loads(lock.read_text()).get("models", []) if lock.exists() else []:
        if not licence_ok(m.get("licence", ""), allow):
            errors.append(f"model {m.get('id')}: licence '{m.get('licence')}' not in allow-list")
    return errors


if __name__ == "__main__":
    errors = check(Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
    print("\n".join(errors) or "license_check: OK")
    sys.exit(1 if errors else 0)
