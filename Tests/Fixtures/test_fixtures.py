import json
import wave
from pathlib import Path

import pytest

import generate

ROOT = Path(__file__).resolve().parent
NAMES = sorted(p.stem for p in (ROOT / "scripts").glob("*.src"))


@pytest.mark.parametrize("name", NAMES)
def test_sources_plant_ten_answerable_facts(name):
    voices, lines = generate.parse(ROOT / "scripts" / f"{name}.src")
    facts = [(text, f) for _, text, f in lines if f]
    assert len(facts) == 10
    assert len(set(voices.values())) >= (3 if name.startswith("meeting") else 2)
    assert generate.QUERY_VOICE not in voices.values()
    for text, f in facts:  # the answer is literally in the fact sentence
        assert any(m.lower() in text.lower() for m in f["must"].split("|")), text


@pytest.mark.parametrize("name", NAMES)
def test_facts_match_timeline(name):
    facts = json.loads((ROOT / f"{name}.facts.json").read_text())
    timeline = json.loads((ROOT / f"{name}.timeline.json").read_text())
    ends = {seg["t1"]: seg for seg in timeline}
    assert [f["t"] for f in facts] == sorted(f["t"] for f in facts)
    for f in facts:
        seg = ends[f["t"]]
        assert seg["speaker"] == f["speaker"]
        assert any(m.lower() in seg["text"].lower() for m in f["must_contain"])
    txt = (ROOT / "scripts" / f"{name}.txt").read_text().splitlines()
    assert txt == [seg["text"] for seg in timeline]


@pytest.mark.parametrize("name", NAMES)
def test_wavs_are_16k_mono_and_lectures_3_to_5_min(name):
    if not (ROOT / f"{name}.wav").exists():
        pytest.skip("WAVs not generated; run make fixtures")
    timeline = json.loads((ROOT / f"{name}.timeline.json").read_text())
    for suffix in ("", "_snr20", "_snr10"):
        with wave.open(str(ROOT / f"{name}{suffix}.wav")) as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2)
            seconds = w.getnframes() / 16000
            assert timeline[-1]["t1"] < seconds
            if name.startswith("lecture"):
                assert 180 <= seconds <= 300


def test_librispeech_sample():
    refs_path = ROOT / "librispeech_sample" / "refs.json"
    refs = json.loads(refs_path.read_text())
    assert len(refs) == 20 and len({r["speaker_id"] for r in refs}) == 20
    assert all(r["text"].strip() for r in refs)
    for r in refs:
        wav_path = ROOT / "librispeech_sample" / r["wav"]
        if not wav_path.exists():
            pytest.skip("LibriSpeech WAVs not extracted; run make fixtures")
        with wave.open(str(wav_path)) as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2)
