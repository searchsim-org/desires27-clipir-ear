# Licence policy and inventory

## Allow-list (shipped build)
Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause, ISC, CC-BY-4.0 (models/data), OpenMDW-1.1 (NVIDIA models), Nordic 5-Clause BSD (nRF Connect SDK, firmware only), Apple platform APIs.

## Not allowed in the shipped build
GPL-2.0/3.0, LGPL, AGPL (e.g. Open Interpreter 01), CC-BY-NC-* (e.g. openWakeWord pretrained models, Moonshine legacy non-English models), "Gemma Terms of Use" models (Gemma 3n, EmbeddingGemma — use Gemma 4, which is Apache-2.0), source-available runtimes (Cactus), SDKs requiring vendor access keys (Porcupine), any analytics/telemetry/crash SDK.

`tools/ci/license_check.py` (Phase 0) parses `Package.resolved`, `mac/earbridge/uv.lock` and `tools/models/models.lock.json` against this file and fails CI on anything not listed below.

## Inventory (keep current; one row per dependency and per model)

| Component | Version / tag | Licence | Used in | Added by task |
|---|---|---|---|---|
| llama.cpp (ggml-org) | b11624 (af0579c), built from source by tools/deps/build_llama.sh | MIT | EarCore (LLM, embeddings) | P0.5 |
| sherpa-onnx (k2-fsa) + onnxruntime | v1.13.8 built with TTS off (ADR-007) + onnxruntime 1.28.2 static (csukuangfj/onnxruntime-libs build of Microsoft onnxruntime) | Apache-2.0 / MIT | EarCore (VAD, ASR, speaker emb.), earbridge | P0.5 |
| GRDB.swift | 7.8.0 (last release on swift-tools 6.0, ADR-008) | MIT | EarCore (SQLite, FTS5) | P0.5 |
| mlx-swift (ml-explore) | 0.30.2 (Package.resolved) | MIT | EarTTSKokoro (Kokoro inference on the GPU, ADR-020) | TTS |
| swift-numerics | 1.1.1 (Package.resolved; mlx-swift dependency) | Apache-2.0 | EarTTSKokoro | TTS |
| ZIPFoundation | 0.9.20 (Package.resolved) | MIT | EarTTSKokoro (voices.npz) | TTS |
| KokoroSwift (mlalma/kokoro-ios) | 1.0.11 @ 4d6d1d8, patched by tools/deps/fetch_kokoro.sh | MIT | EarTTSKokoro | TTS |
| MisakiSwift | 1.0.6 @ b7477b1, patched; bundled lexicons and BART G2P weights from hexgrad/misaki (Apache-2.0) | Apache-2.0 | EarTTSKokoro (English G2P, no espeak-ng) | TTS |
| MLXUtilsLibrary | 0.0.6 @ cb6b744 | Apache-2.0 | EarTTSKokoro (npz reader) | TTS |
| Kokoro-82M weights + voices | mlx-community/Kokoro-82M-bf16 @ a71e4d3, hexgrad/Kokoro-82M @ f3ff357 (models.lock.json) | Apache-2.0 | phone answer voice (ADR-020) | TTS |
| swift-opus (libopus) | pin | BSD | EarCore (pendant, Phase 9) | P9.1 |
| websockets | 15.0.1 (uv.lock) | BSD-3-Clause | earbridge WebSocket server + export endpoint (ADR-016) | P5.1 |
| qrcode | 8.2 (uv.lock) | BSD-3-Clause | earbridge pairing QR | P5.1 |
| colorama | uv.lock (qrcode dependency, Windows only) | BSD-3-Clause | — | P5.1 |
| pytest, ruff, pyarrow, jsonschema (dev/tooling only, not shipped) | pins in uv.lock | MIT / MIT / Apache-2.0 / MIT | tests, lint, LibriSpeech extraction, schema validation | P0.1, P0.7, P5.1 |
| xcodegen (tooling only, generates apps/ios/ClipIREar/ClipIREar.xcodeproj) | 2.46.0 (Homebrew) | MIT | make project | P0.2 |
| whisper.cpp (ggml-org) `whisper-cli` (evaluation tooling only, not shipped) | 1.9.1 (Homebrew bottle, ggml 0.15.3, Metal) | MIT | tools/harness/run_corpus_asr.py --system whisper-large-v3-turbo | corpus WER evaluation |
| OpenAI Whisper large-v3-turbo, ggml f16 (ggerganov/whisper.cpp) | HF rev 5359861 | MIT | Mac-tier ASR evaluation only, never in the app | corpus WER evaluation |
| CTranslate2 + faster-whisper `feature_extractor.py` (evaluation tooling on a CPU cluster only, not shipped; faster-whisper installed --no-deps, its PyAV/tqdm deps are not used) | ctranslate2 4.8.3, faster-whisper 1.2.1, numpy 2.5.4, PyYAML 6.0.3 | MIT / MIT / BSD-3-Clause / MIT | tools/harness/run_corpus_asr.py --system ct2-whisper-large-v3-turbo | corpus WER evaluation |
| OpenAI Whisper large-v3-turbo, CTranslate2 conversion (mobiuslabsgmbh/faster-whisper-large-v3-turbo) | HF rev 0a363e9 | MIT | cluster ASR evaluation only, never in the app | corpus WER evaluation |
| LibriSpeech test-clean (openslr/librispeech_asr parquet) | HF rev 2b9f393 | CC-BY-4.0 | ASR evaluation data (20 utterances, not committed) | P0.7 |
| Silero VAD v5 | pin | MIT | both tiers | P2.1 |
| NVIDIA Nemotron-3.5-ASR-Streaming-0.6B | pin | OpenMDW-1.1 | both tiers | P2.3 |
| sherpa-onnx streaming Zipformer (en) | pin | Apache-2.0 | phone fallback, CI | P2.3 |
| 3D-Speaker ERes2Net (speaker embedding) | pin | Apache-2.0 | phone (P2.6) | P2.6 |
| nomic-embed-text-v1.5 (GGUF) | pin | Apache-2.0 | both tiers | P3.3 |
| Gemma 4 E2B instruct (GGUF Q4_K_M) | pin | Apache-2.0 | phone | P3.5 |
| Qwen3-0.6B instruct (GGUF) | pin | Apache-2.0 | CI only | P3.6 |
| Kyutai Pocket TTS | pin | MIT (voices: per-voice) | both tiers | P4.2 |
| Kokoro-82M | pin | Apache-2.0 | both tiers (alt) | P4.2 |
| Omi firmware (BasedHardware/omi) | pin commit | MIT | firmware/pendant | P9.3 |
| Zephyr RTOS / nRF Connect SDK | pin | Apache-2.0 / Nordic 5-Clause BSD | firmware/pendant | P9.3 |
| OpenPineBuds (BES SDK) | — | shared-source, **not redistributable** — patch only, never commit the SDK | firmware/pinebuds | P10.1 |
