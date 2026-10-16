# Design decisions

Code comments cite these decisions as ADR-nnn. Each entry states the decision and the reason. Later entries can amend earlier ones; the amendment is noted on both.

## ADR-001: native Swift app with an optional Mac tier

The app is native Swift: the `EarCore` package plus a SwiftUI shell, with the Python `earbridge` service on a Mac. Audio-session edge cases (routes, interruptions, Bluetooth HFP) are the main risk and are easiest to handle natively, and llama.cpp and MLX have first-party Swift paths. `EarCore` has no UI framework dependency, which keeps a port to another platform possible. Android is not planned.

## ADR-002: device builds without TestFlight

Device builds are signed with the development team set in `apps/ios/ClipIREar/Signing.xcconfig` and installed from Xcode or `xcrun devicectl`. There is no TestFlight or App Store distribution. All app targets share one bundle identifier prefix. Background audio (`UIBackgroundModes: audio`) is an Info.plist key and needs no extra entitlement.

## ADR-003: design for 6 GB iPhones

The phone tier must fit an iPhone with 6 GB of memory. The phone LLM is chosen by measured fit, the Mac tier is the expected main path under `auto`, and the LLM, recognizer and voice should not all hold their peak memory at the same time.

## ADR-004: English only

Fixtures, intent rules and tests are English only. `IntentDetector` keeps one JSON rule table per locale (`intents.<lang>.json`), so a language can be added as data plus fixtures.

## ADR-005: macOS 15 floor for EarCore

`Package.swift` declares macOS 15 so the package builds and its tests run on macOS 15 hosts. Code that needs newer OS APIs must be wrapped in availability checks and chosen at runtime, and tests that need such APIs skip with a message. ADR-008 replaced the toolchain and iOS parts of this decision.

## ADR-006: Hugging Face CDN as a download host

Large files on huggingface.co redirect to `*.cdn.hf.co`. `cdn.hf.co` and its subdomains are on the download allow-list. The downloader checks the host of every redirect hop and the SHA-256 of every file.

## ADR-007: no sherpa-onnx speech synthesis on the phone

The prebuilt sherpa-onnx iOS framework statically links espeak-ng, which is GPL-3.0. `tools/deps/build_sherpa.sh` builds sherpa-onnx from source with `-DSHERPA_ONNX_ENABLE_TTS=OFF` (VAD, ASR and speaker embedding only). The phone spoke with `SystemSpeaker` (AVSpeechSynthesizer) until ADR-020 added Kokoro without espeak-ng.

## ADR-008: iOS 18 and Xcode 16.2; no Apple SpeechAnalyzer

Deployment targets are iOS 18 and macOS 15 so the app installs on iOS 18 phones and builds with Xcode 16.2 (Swift 6.0). The iOS 18 SDK has no SpeechAnalyzer, so `SherpaStreamingRecognizer` is the only speech recognizer on both tiers. Code uses iOS 18 SDK names, for example `AVAudioSession.CategoryOptions.allowBluetooth`. Adding Apple's recognizer later needs Xcode 26, iOS 26 and an `@available` engine. `make doctor` accepts Xcode 16.2 or later and 26.0 to 26.3.

## ADR-009: cached fixture clips

macOS `say` does not produce byte-identical audio from run to run for some voices. `Tests/Fixtures/generate.py` caches each clip by voice, rate and text, so repeated `make fixtures` runs on one machine are byte-identical. Facts and timelines are written in the same run and committed with `SHA256SUMS`; the WAV files are not committed. Tests read times from `timeline.json` and `facts.json`, never hard-coded values.

## ADR-010: simulator by default

`Signing.xcconfig` ships with an empty `DEVELOPMENT_TEAM`, and no team ID is stored in the repository. Builds, tests and `make demo` target the `EarSim` simulator. The simulator has no Bluetooth HFP, no microphone route switching, no background lock behaviour and no real memory limits, so its numbers do not stand in for a device.

## ADR-011: development process

An internal decision about the order of work. It has no effect on the code.

## ADR-012: fixture voice change

The `lecture_en_02` fixture uses the Rishi voice instead of Ralph. Ralph is a legacy formant voice, and results on it measured the voice rather than the recognizer.

## ADR-013: streaming Zipformer for speech recognition

`SherpaStreamingRecognizer` uses the English streaming Zipformer on both tiers. Its model is about 73 MB against about 680 MB for Nemotron-3.5-ASR-Streaming-0.6B, which leaves phone memory for the LLM. Nemotron stays in `sources.json` as an optional download and is not wired in.

## ADR-014: phone LLM

The default phone model is Gemma 4 E2B Q4_0, because no Q4_K_M build of it is published by Google or ggml-org. Qwen3-1.7B Q4_K_M is the low-memory option in Settings. Qwen3-0.6B Q8_0 is the small model for tests and the simulator. If the default causes memory kills on a 6 GB phone, the default moves to Qwen3-1.7B.

## ADR-015: earbridge speech and LLM stack

The PyPI sherpa-onnx wheel for macOS links espeak-ng and piper (GPL-3.0), and `ollama pull` contacts a registry outside the allow-list. So:

1. Speech recognition runs in `EarCLI asr-stream`, the Swift `EarCore` build with the same Silero VAD and Zipformer as the phone, as a subprocess fed PCM16 on stdin and emitting JSON lines.
2. Speech synthesis runs in `EarCLI tts-stream` (AVSpeechSynthesizer), which returns 24 kHz PCM per sentence.
3. The LLM is Ollama on localhost through its native `/api/chat` API with thinking off, serving GGUF files from `make models` that `earbridge doctor --fix` imports with `ollama create`.

`earbridge` therefore has no Python ML dependencies, and it needs the `EarCLI` release binary (`swift build -c release --product EarCLI`).

## ADR-016: earbridge runtime dependencies

The common Python web stack failed the licence check: httpx pulls certifi (MPL-2.0), pydantic and FastAPI pull typing-extensions (PSF-2.0), and python-zeroconf is LGPL-2.1. `earbridge` depends only on `websockets` 15.0.1 and `qrcode` 8.2. It uses `json` and dataclasses for messages, `sqlite3` for the store, `urllib` for Ollama, the `websockets` HTTP hook for `/health` and `/ear/v1/export`, and macOS `dns-sd` for Bonjour. Without a validation framework, `protocol.py` checks every inbound message before use, and the JSON Schemas in `docs/protocol` are tested on both sides.

## ADR-017: Mac tier default model

`earbridge` defaults to `clipir-gemma4-e2b`, the same GGUF as the phone, run on the Mac GPU with the Mac-tier budget of 6,000 tokens and 140 words. On a 32 GB Apple silicon Mac, Gemma 4 E4B missed the first-word latency target while E2B met it with the same answer quality. `earbridge serve --model clipir-gemma4-e4b` selects the larger model.

## ADR-018: actions run on the phone

`ActionDetector` on the phone recognises note, reminder, calendar, pin and web-search requests; calendar and pin requests match by phrase, with dates from `NSDataDetector`. When a question goes to the Mac, `earbridge` flags action requests (`brain.is_action`) with `answer.action {question, intent}` instead of an answer, and the phone runs the same approval flow. Approval needs the phone's microphone and speaker, and execution needs its EventKit stores, so the Mac never touches reminders or calendars. Web search is recorded only.

## ADR-019: TLS by QR, no speaker labels, English strings

1. `earbridge serve` uses TLS by default with a self-signed RSA-2048 certificate made by `/usr/bin/openssl`. The pairing QR and the Bonjour TXT record carry its SHA-256 fingerprint, and `BridgeClient` accepts only that certificate. Pairing by typed code carries no fingerprint and uses plain `ws://`, meant for `--no-tls` over an encrypted link such as Tailscale. Tests run `--no-tls` on localhost.
2. Speaker enrolment is deferred. Segments keep `speaker = 'unknown'`, and exports carry no speaker labels.
3. UI strings are English SwiftUI `Text` literals, which act as localisation keys, with accessibility labels on controls without visible text. Adding a language means adding a String Catalog.

## ADR-020: Kokoro voice on the phone, Apple voice as fallback

Answers on the phone use Kokoro-82M through KokoroSwift 1.0.11 and MisakiSwift 1.0.6 on MLX, in the separate `EarTTSKokoro` target so `EarCore` and `EarCLI` stay free of MLX. MisakiSwift converts English to phonemes with lexicons and a small BART model (Apache-2.0) instead of espeak-ng, which keeps ADR-007's licence rule. This amends ADR-007 for the phone.

- `tools/deps/fetch_kokoro.sh` checks out pinned commits and patches them for Xcode 16.2: it lowers the tools version, drops `nonisolated` on type declarations, and renames the packages' `Resources` folders to `Assets` because iOS codesign rejects a bundle folder named Resources.
- `FallbackSpeaker` speaks one sentence at a time through Kokoro and uses the best installed Apple voice for a sentence Kokoro does not finish within 6 s. Three such sentences in a row, a render with no audio, or a memory warning switch Kokoro off for the pipeline's life.
- Answers speak their first clause early (`SentenceSplitter(firstClause:)`), because Kokoro cannot start mid-sentence.
- The default voice is `af_heart`.
- `EarTTSKokoro` compiles in Swift 5 language mode because KokoroSwift's types are not Sendable; `KokoroSpeaker` serialises every call to them on one queue.
- MLX cannot create its Metal device in the iOS Simulator, so the simulator always speaks with the Apple voice.
- Kokoro tests run only under xcodebuild (`make test-kokoro`); `swift test` skips them.
- The model files add about 360 MB to the phone. Loading the weights takes about a second on the main actor when a pipeline is built. A memory warning while listening switches Kokoro off; its weights and MLX's buffer cache are freed when listening stops.
- The Mac tier still speaks with the Apple voice.

## ADR-021: Voice web search from the phone with the user's own Brave Search key

- The phone calls the Brave Search API (`api.search.brave.com`) with the query text alone and asks for three results. Search works without a Mac.
- Web search is off until the user pastes a Brave Search API key in Settings. The app keeps the key in the Keychain on this device only, and `EgressGuard` allows the host only while the setting is on.
- "Search the web for …" runs at once, without a spoken confirmation. The on-phone model sums up the results, and the answer starts "According to ⟨domain⟩".
- Results are used for one answer and never stored. The answer is stored like any other answer.
- `tools/ci/egress_check.py` allows the API host in `Sources/EarCore/Actions/WebSearch.swift` only.
