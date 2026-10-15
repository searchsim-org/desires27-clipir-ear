# Architecture

ClipIR Ear has three parts: the `EarCore` Swift package, a thin SwiftUI app over it, and an optional Mac service, `earbridge`. One pipeline answers questions in two places, the phone tier and the Mac tier.

## Overview

```
 Audio in: Bluetooth earbuds (HFP, 16 kHz mono), the phone microphone, or a WAV fixture
                 |  PCM16 mono 16 kHz with monotonic timestamps
 +---------------v------------------- iPhone: ClipIR Ear app ------------------------+
 | AudioSessionManager -> CaptureSource (mic | file | stdin)                         |
 |   -> SileroVAD -> SherpaStreamingRecognizer -> SQLiteTranscriptStore              |
 |      (GRDB: audio_segments + FTS5 + embeddings, RetentionPolicy)                  |
 | push to talk -> QueryRouter -> IntentDetector -> ContextAssembler                 |
 |   -> Answerer (LlamaAnswerer on the phone, or the Mac through BridgeClient)       |
 |   -> SentenceSplitter -> Speaker (FallbackSpeaker: Kokoro, then Apple voice)      |
 | ActionDetector -> ApprovalGate -> EarActionExecutor                               |
 | EgressGuard + ConnectionLedger, LatencyTrace, Exporter                            |
 +---------------+-------------------------------------------------------------------+
                 |  wss://<mac>:9478/ear/v1  (JSON control frames + binary PCM frames)
 +---------------v------------------- Mac: earbridge (Python) -----------------------+
 | websockets server, Bonjour via dns-sd, self-signed TLS                            |
 | EarCLI asr-stream (same VAD and Zipformer as the phone)                           |
 | Ollama /api/chat (local GGUF, default Gemma 4 E2B)                                |
 | EarCLI tts-stream (AVSpeechSynthesizer, 24 kHz PCM)                               |
 | ear.db mirror (sqlite3, same tables as the phone)                                 |
 +-----------------------------------------------------------------------------------+
```

## Two tiers, one pipeline

On the phone tier everything runs on the iPhone: Silero VAD and the streaming Zipformer through sherpa-onnx, Gemma 4 E2B Q4_0 through llama.cpp, and Kokoro-82M on MLX for the voice. Settings offer Qwen3-1.7B Q4_K_M as a low-memory model. Tests and the simulator use Qwen3-0.6B.

On the Mac tier the phone streams PCM to `earbridge`. The Mac recognises the question with the same Zipformer, answers with an Ollama model, synthesises speech, and streams text and audio back.

`TierPolicy` picks the tier per question:

- `auto` (default): the Mac when it is connected and the measured round trip is under 150 ms, otherwise the phone.
- `phone`: always the phone.
- `mac`: the Mac when connected, otherwise the phone.

The phone keeps decoding the question locally while it streams it to the Mac. If no `answer.token` arrives within 3 s of `query.end`, or the Mac sends `error` or disconnects, the phone sends `query.cancel`, plays a fallback earcon and answers on the device. Each `voice_queries` row records the tier that answered and whether a fallback happened.

Budgets per tier:

| | Phone | Mac |
|---|---|---|
| Prompt budget | 2,000 tokens | 6,000 tokens |
| Answer length in the system prompt | 80 words | 140 words |
| Transcript window cap | 1,200 tokens | 1,200 tokens |

## Interaction modes

- Ambient. You tap Start listening. Final transcript segments go into the store, and segments older than the retention window are deleted unless pinned. A Live Activity shows the listening state.
- Query (push to talk). Start a question with the on-screen button or the AirPods stem press (the play/pause remote command while the app owns now-playing). The app plays an earcon, recognises the question, routes it to an intent, answers and speaks.
- Whisper-back. Answers are spoken sentence by sentence. The first chunk may end at a comma so speech starts sooner. A new question cancels the current answer.
- Proactive cues (off by default). When a final segment mentions a keyword from your notes or pinned segments, the app whispers a short cue. `CueEngine` allows at most 6 cues per hour and one per keyword per hour.

## Intents and context

`IntentDetector` matches the question against the regex table in `Sources/EarCore/Assets/intents.en.json`. The Mac reads the same file. Intents: `explainLast`, `expand`, `summarizeWindow`, `whoSaid`, `translate`, `noteThis`, `remindMe`, `searchWeb`, `freeform`.

`ContextAssembler` builds the prompt from three sources:

1. A transcript window ending at the question: 60 s for `explainLast` and the default, 180 s for `expand`, N minutes for `summarizeWindow` (2 when no number is given), 300 s for `whoSaid`.
2. Up to 5 retrieved segments outside the window, ranked by FTS5 BM25 plus cosine similarity from `nomic-embed-text-v1.5` embeddings. `explainLast` skips retrieval. The Mac tier uses FTS5 only.
3. Pinned segments as notes, up to 400 tokens.

When the prompt exceeds the budget, the assembler drops retrieved segments first, then the oldest window segments. Prompt templates live in `Sources/EarCore/Assets/Prompts`. The model ends its answer with a `SOURCE:` line (`transcript`, `notes`, `general` or `none`), which is stored as `knowledge_tier` and not spoken.

## Actions

`ActionDetector` recognises note, reminder, calendar, pin and web-search requests on the phone. The phone reads the proposal aloud and waits for a spoken yes (`ApprovalGate`), then `EarActionExecutor` writes the note to the local store or the reminder or event through EventKit. Web search is recorded only; this build never searches. When a question goes to the Mac, `earbridge` flags action requests with `answer.action` and the phone runs the same approval flow. "Forget the last N minutes" and "stop listening" run without approval.

## EarCore modules

| Module | Responsibility | Key types |
|---|---|---|
| `Audio` | AVAudioSession setup, route and interruption handling, conversion to 16 kHz mono Int16, output with ducking | `AudioSessionManager`, `PCMConverter`, `AudioOutput` |
| `Capture` | Frame sources and the explicit recorder | `CaptureSource`, `MicCaptureSource`, `FileCaptureSource`, `StdinCaptureSource`, `Recorder` |
| `VAD` | Speech and silence events | `VoiceActivityDetector`, `SileroVAD`, `EnergyVAD` (tests) |
| `ASR` | Streaming recognition | `StreamingRecognizer`, `SherpaStreamingRecognizer`, `ScriptedRecognizer` (tests) |
| `Memory` | SQLite store, retention, purges, voice queries, notes | `SQLiteTranscriptStore`, `RetentionPolicy`, `Segment`, `VoiceQuery` |
| `Retrieval` | Window, lexical and vector retrieval, budgeting, embeddings | `ContextAssembler`, `EmbeddingIndexer`, `HashEmbedder` (tests) |
| `Query` | Push-to-talk state machine and intents | `QueryRouter`, `Intent`, `IntentDetector` |
| `Answer` | Prompts, llama.cpp engine, streaming, sentence splitting | `Answerer`, `LlamaAnswerer`, `LlamaEmbedder`, `MockAnswerer`, `PromptBuilder`, `SentenceSplitter` |
| `TTS` | Sentence-streamed speech and earcons | `Speaker`, `SystemSpeaker`, `FallbackSpeaker`, `Earcon` |
| `Actions` | Detection, spoken approval, execution, cues | `ActionDetector`, `ApprovalGate`, `EarActionExecutor`, `EventKitStore`, `CueEngine` |
| `Sync` | Pairing, Bonjour, WebSocket client, codec, tier policy | `PairingInfo`, `PairingStore`, `BonjourBrowser`, `BridgeClient`, `ProtocolCodec`, `TierPolicy`, `RemoteRecognizer` |
| `Export` | Derived-measure export | `Exporter` |
| `Telemetry` | Latency stages, memory and thermal sampling, MetricKit intake | `LatencyTrace`, `Stage`, `DeviceTelemetry`, `MetricsIntake` |
| `Privacy` | Network allow-list and ledger | `EgressGuard`, `ConnectionLedger` |
| `Pipeline` | Orchestration; the object the app talks to | `EarPipeline`, `AmbientPipeline`, `PipelineConfig`, `PipelineDeps` |

`EarTTSKokoro` is a separate target with `KokoroSpeaker`, so `EarCore` and `EarCLI` build without MLX. `FallbackSpeaker` speaks each sentence with Kokoro and switches to the best installed Apple voice for any sentence Kokoro does not finish within 6 s. Three such sentences in a row, a render with no audio, or a memory warning turn Kokoro off for the rest of the pipeline's life.

`LatencyTrace` records these stages, in seconds since `pttDown`: `speechEnd`, `earcon`, `asrFinal`, `contextReady`, `llmFirstToken`, `llmFirstSentence`, `ttsFirstAudio`, `audioOutStart`, `audioOutEnd`, `done`.

## The app

`apps/ios/ClipIREar` holds SwiftUI views and no pipeline logic: onboarding (consent and retention choice), Home (listening, ask, forget), Transcript, Review (export and recordings), Mac (pairing, tier policy, voice) and Debug. The `Widget` target provides the Live Activity. All logic is in `EarCore`, so it builds and tests on macOS.

## earbridge

`earbridge` has two runtime dependencies, `websockets` and `qrcode`. The rest is the Python standard library.

| Module | Does |
|---|---|
| `server.py` | One `Connection` per phone: hello check and rate limit, ambient and question ASR workers, answering, TTS streaming, `/health` and `/ear/v1/export` |
| `asr.py` | `EarCLI asr-stream` subprocess: PCM16 on stdin, JSON lines out |
| `tts.py` | `EarCLI tts-stream` subprocess: one sentence per line in, length-prefixed 24 kHz PCM16 out |
| `llm.py` | Streams from Ollama's native `/api/chat` with `think: false` |
| `brain.py` | Intents, context window, prompts and sentence splitting, ported from `EarCore` |
| `store.py` | `ear.db` mirror on `sqlite3` |
| `pairing.py`, `tls.py` | Pairing token and QR, self-signed certificate and its fingerprint |
| `protocol.py` | Message definitions, validation, schema generation |
| `export.py` | Derived measures as JSON |

Commands: `earbridge pair`, `serve`, `status`, `doctor [--fix]` and `export --session <id>`. `serve` warms the model at start, and each connection keeps a warm TTS worker and a spare ASR worker so the first answer does not pay a cold start.
