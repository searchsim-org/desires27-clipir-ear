# Test fixtures (P0.7)

All audio is synthetic, made on macOS with `say` and `sox`; there is no third-party audio. English only (ADR-004).

`make fixtures` runs `generate.py`, which writes:

| File | What |
|---|---|
| `scripts/<name>.src` | Source, hand-written. Each line is `SPEAKER: text`; a fact line appends `## fact=… ## q=… ## must=a\|b`. The `# voices:` header maps speakers to `say` voices. |
| `scripts/<name>.txt` | Clean text, one utterance per line. The script to read aloud for a live-microphone test, and the WER reference. |
| `<name>.wav` | 16 kHz mono 16-bit, 175 wpm, 0.6 s between utterances and 1.0 s on a speaker change. |
| `<name>_snr20.wav`, `<name>_snr10.wav` | The same audio with café-like noise (`sox` brown noise, low-passed at 1.2 kHz) at 20 dB and 10 dB SNR. Speech level is measured over speech segments only. |
| `<name>.facts.json` | 10 planted facts: `t` (end of the fact utterance, in seconds), `fact`, `question`, `must_contain`, `speaker` (voice). |
| `<name>.timeline.json` | Per utterance: `t0`, `t1`, `speaker`, `text`. Use it for VAD counts and timing; never hard-code times. |
| `queries/<name>_qNN.wav`, `queries/en.json` | Each fact's question, spoken by Moira, a voice that never appears inside a fixture. |
| `SHA256SUMS` | Hashes of every output from the committed build. |

| Fixture | Voices | Length |
|---|---|---|
| lecture_en_01 | Samantha, Daniel | 3.5 min |
| lecture_en_02 | Karen, Rishi | 3.1 min |
| lecture_en_03 | Daniel, Tessa | 3.1 min |
| lecture_en_04 | Samantha, Rishi | 3.2 min |
| lecture_en_05 | Karen, Daniel | 3.2 min |
| meeting_en_01 | Samantha, Daniel, Karen | 2.4 min |

WAVs are not committed. The JSON and text files are committed. A repeat `make fixtures` is byte-identical because of the clip cache in `.build/`. A cold rebuild can move utterance times by up to about 35 ms, because some `say` voices are not bit-exact (ADR-009). The facts and timeline are always regenerated together with their WAV, so they stay consistent.

## LibriSpeech sample

`make fixtures` also fetches the pinned LibriSpeech test-clean parquet from Hugging Face (`make models ONLY=librispeech-test-clean`; 350 MB, SHA-256 in `models.lock.json`). `librispeech.py` then extracts 20 utterances, the first one by ID from each of the first 20 speakers, into `librispeech_sample/<id>.wav`. `refs.json`, with the reference transcripts, is committed; the WAVs are not. Re-extraction is byte-identical. LibriSpeech is by Panayotov et al., ICASSP 2015, licensed CC BY 4.0.
