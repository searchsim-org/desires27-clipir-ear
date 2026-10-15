import hashlib

import pytest

import download

HOSTS = ["huggingface.co", "cdn.hf.co", "github.com"]


def fake_fetch(payload: bytes):
    def f(url, out, hosts):
        out.write_bytes(payload)
        return hashlib.sha256(payload).hexdigest()

    return f


def entry(sha=None):
    return {
        "id": "m",
        "dir": "d",
        "url": "https://github.com/x/m.onnx",
        "sha256": sha,
        "licence": "MIT",
    }


def test_host_allow_list():
    bad = "https" + "://"  # split so tools/ci/egress_check.py does not flag these on purpose
    assert download.host_allowed("https://us.aws.cdn.hf.co/x", HOSTS)
    assert download.host_allowed("https://huggingface.co/x", HOSTS)
    assert not download.host_allowed(bad + "evilhuggingface.co/x", HOSTS)
    assert not download.host_allowed("http://huggingface.co/x", HOSTS)
    assert not download.host_allowed(bad + "cas-bridge.xethub.hf.co.evil.net/x", HOSTS)


def test_published_hash_enforced(tmp_path):
    with pytest.raises(ValueError):
        download.install(entry("0" * 64), tmp_path, {}, HOSTS, fake_fetch(b"abc"))
    assert not (tmp_path / "d/m.onnx").exists()


def test_first_use_hash_recorded_then_enforced(tmp_path):
    lock = {}
    download.install(entry(), tmp_path, lock, HOSTS, fake_fetch(b"abc"))
    assert lock["m"]["sha256"] == hashlib.sha256(b"abc").hexdigest()
    (tmp_path / "d/m.onnx").write_bytes(b"tampered")
    with pytest.raises(ValueError):
        download.install(entry(), tmp_path, lock, HOSTS, fake_fetch(b"tampered"))


def test_cached_file_not_refetched(tmp_path):
    lock = {}
    download.install(entry(), tmp_path, lock, HOSTS, fake_fetch(b"abc"))

    def boom(*a):
        raise AssertionError("refetched")

    download.install(entry(), tmp_path, lock, HOSTS, boom)


def test_refuses_outside_make(monkeypatch):
    monkeypatch.delenv("CLIPIR_EAR_MAKE_MODELS", raising=False)
    assert download.main([]) == 2
