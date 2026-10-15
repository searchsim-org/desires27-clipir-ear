# ClipIR Ear

ClipIR Ear is a local-first assistant for your earbuds. It listens to a talk or meeting, keeps a short rolling transcript on your iPhone, and answers spoken questions such as "what did she just say?" in your ears. Audio, transcripts and inference stay on the phone and, optionally, a Mac on the same network.

Status: research prototype, English only, no App Store build.

## What runs where

| Part | Runs on | Does |
|---|---|---|
| `EarCore` (Swift package) | iPhone and macOS | The whole pipeline: capture, speech recognition, transcript store, retrieval, answers, speech, actions, privacy guards |
| ClipIR Ear app (`apps/ios/ClipIREar`) | iPhone, iOS 18 or later | SwiftUI screens over `EarCore` |
| `EarCLI` | macOS | Command-line runner; `earbridge` uses it for speech in and out |
| `earbridge` (Python, optional) | Mac on the same LAN or Tailscale network | WebSocket service that answers through a local Ollama model |

With a paired Mac in `auto` mode, a question goes to the Mac when the round trip is under 150 ms; if the Mac sends no answer within 3 s, the phone answers itself. Speech recognition is the sherpa-onnx streaming Zipformer with Silero VAD on both tiers. Both tiers answer with Gemma 4 E2B (Q4_0 GGUF), through llama.cpp on the phone and Ollama on the Mac. The phone speaks with Kokoro-82M on MLX and falls back to the best installed Apple voice.

## Requirements

- An Apple silicon Mac with macOS 15.6 or later.
- Xcode 16.2 or a later 16.x release, or Xcode 26.0 to 26.3 (Swift 6).
- Homebrew. `make bootstrap` installs uv, Python 3.12, Ollama, sox, ffmpeg, jq, git-lfs, xcbeautify and xcodegen.
- An iOS 18 simulator named `EarSim`. `make doctor` prints the command that creates it.
- About 5 GB of disk for the default models, plus about 360 MB for the Kokoro voice.
- For a device build: an iPhone on iOS 18 or later, and an Apple development team.

## Build and test

Run these from the repository root.

```sh
make doctor      # checks macOS, Xcode, Swift, the tools below and the EarSim simulator
make bootstrap   # installs the Homebrew tools and Python 3.12, syncs mac/earbridge, enables .githooks
make deps        # builds sherpa-onnx (speech synthesis off) and llama.cpp from source, fetches and patches Kokoro
make models      # downloads the default models into ~/Library/Application Support/ClipIREar/models
make fixtures    # renders the test lectures with macOS `say` and fetches the LibriSpeech sample
make test        # swift test, earbridge pytest, then the app tests on EarSim
make test-kokoro # Kokoro tests; they need xcodebuild because MLX loads Metal shaders
make ci          # lint, licence check, egress check, make test, make test-kokoro
```

`make models` downloads only from hosts in `tools/models/sources.json` and checks each SHA-256 against `tools/models/models.lock.json`. Optional models download by id, for example `make models ONLY="kokoro-82m kokoro-voice-af_heart"` for the Kokoro voice or `make models ONLY=gemma-4-e4b-it-q4_0` for the larger Mac model.

### Run in the simulator

```sh
make demo
```

This builds the app, installs it on `EarSim` and starts it on a recorded lecture fixture. The simulator has no Bluetooth headset route and speaks with the Apple voice, because MLX cannot run there. You can also run the `ClipIREar` scheme from `apps/ios/ClipIREar/ClipIREar.xcodeproj`; `make project` regenerates it from `project.yml`.

### Run on an iPhone

1. Set `DEVELOPMENT_TEAM` in `apps/ios/ClipIREar/Signing.xcconfig`.
2. Change the bundle identifiers in `apps/ios/ClipIREar/project.yml` to ones your team owns, then run `make project`.
3. Build and run the `ClipIREar` scheme on the phone from Xcode.
4. Copy the contents of `~/Library/Application Support/ClipIREar/models` into the app's `models` folder in Finder's file sharing view (the app's Documents directory).

### Run the Mac service

```sh
swift build -c release --product EarCLI          # earbridge runs this binary for speech
uv run --project mac/earbridge earbridge pair     # prints a QR code and an 8-character code
uv run --project mac/earbridge earbridge doctor --fix   # imports the pinned GGUF into Ollama
uv run --project mac/earbridge earbridge serve
```

Scan the QR code from the app's Mac screen. It carries the fingerprint of the Mac's self-signed certificate, and the phone accepts only that certificate.

## Repository layout

```
Package.swift            EarCore, EarCLI and EarTTSKokoro targets
Sources/EarCore          the pipeline (one folder per module)
Sources/EarTTSKokoro     Kokoro speaker, kept apart so EarCore builds without MLX
Sources/EarCLI           macOS command-line runner
Tests                    Swift tests and test fixture generators
apps/ios                 SwiftUI app, Live Activity widget, app tests
mac/earbridge            Python Mac service and its tests
docs                     architecture, protocol, schema, privacy, design decisions
docs/protocol            JSON Schema for every phone-to-Mac message
tools/deps               scripts that build or fetch binary dependencies
tools/models             model manifest, lock file and downloader
tools/harness            accuracy and latency suites (make harness, make report)
tools/ci                 licence and egress checks
```

Code comments cite design decisions as ADR-nnn (see [docs/DECISIONS.md](docs/DECISIONS.md)) and internal planning task IDs such as P4.2 or §8.1 that have no public document.

More detail: [architecture](docs/ARCHITECTURE.md), [phone to Mac protocol](docs/PROTOCOL.md), [data model](docs/SCHEMA.md), [privacy](docs/PRIVACY.md).

## Privacy

- The app writes no audio to disk unless you turn on Record.
- Transcript segments older than the retention window (30 minutes by default, 1 minute to 24 hours) are deleted unless pinned.
- Shaking the phone, tapping "Forget the last 10 minutes" or saying "forget the last N minutes" deletes recent segments.
- One guard opens every network connection and allows only localhost, the paired Mac, and model hosts during a download you start. CI rejects other hosts and analytics, telemetry and crash-reporting SDKs.
- Exports hold counts and latencies; question text, answers and the transcript only when you tick them.

[docs/PRIVACY.md](docs/PRIVACY.md) has the details and known gaps.

## Licences

ClipIR Ear is released under the Apache License 2.0 ([LICENSE](LICENSE)). The shipped build contains no GPL code. [LICENSES.md](LICENSES.md) lists the licence allow-list and every dependency and model; `tools/ci/license_check.py` enforces it.
