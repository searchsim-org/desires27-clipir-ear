import json
import shutil
from pathlib import Path

import egress_check
import license_check

REPO = Path(__file__).resolve().parents[2]


def make_repo(tmp: Path) -> Path:
    for f in ["LICENSES.md", "tools/ci/forbidden.txt", "tools/models/sources.json"]:
        (tmp / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / f, tmp / f)
    (tmp / "Sources").mkdir()
    return tmp


def test_real_repo_is_clean():
    assert egress_check.check(REPO) == []
    assert license_check.check(REPO) == []


def test_egress_flags_vendor_and_unknown_host(tmp_path):
    root = make_repo(tmp_path)
    (root / "Sources/A.swift").write_text(
        'import Sentry\nlet u = "https://api.example.net/x"\nlet ok = "ws://localhost:9478/ear/v1"\n'
        'let hf = "https://huggingface.co/m"\nlet level = amplitude * 2\nlet t = "ws://<mac>:9478"\n'
    )
    (root / "Sources/Info.plist").write_text(
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        "<string>http://www.apple.com/x</string>\n"
    )
    (root / "Sources/schema.py").write_text(
        'S = {"$schema": "https://json-schema.org/draft/2020-12/schema"}\nU = "https://json-schema.org/other"\n'
    )
    hits = egress_check.check(root)
    assert len(hits) == 4, hits  # the doctype line is exempt, a real apple.com URL is not
    assert any("sentry" in h for h in hits) and any("api.example.net" in h for h in hits)
    assert any("Info.plist:2" in h for h in hits)
    assert any("schema.py:2" in h for h in hits) and not any("schema.py:1" in h for h in hits)


def test_license_rejects_unlisted_and_disallowed(tmp_path):
    root = make_repo(tmp_path)
    (root / "Package.resolved").write_text(
        json.dumps({"pins": [{"identity": "grdb.swift"}, {"identity": "mystery"}]})
    )
    (root / "tools/models/models.lock.json").write_text(
        json.dumps(
            {
                "models": [
                    {"id": "ok", "licence": "Apache-2.0"},
                    {"id": "bad", "licence": "CC-BY-NC-4.0"},
                ]
            }
        )
    )
    errors = license_check.check(root)
    assert errors == [
        "mystery: not listed in LICENSES.md",
        "model bad: licence 'CC-BY-NC-4.0' not in allow-list",
    ]
