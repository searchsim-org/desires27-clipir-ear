# Privacy

ClipIR Ear records speech from people who did not install it. This page lists what the code keeps, where it keeps it and for how long, including the known gaps.

## Audio

- `MicCaptureSource` never writes audio to disk. Audio frames go to the VAD and the recognizer in memory.
- `Recorder` is the only code that writes captured audio, and only while the user has Record on. It writes 16 kHz mono WAV files to `Documents/Recordings/`, and the Review screen lists them. Segments captured during a recording have `audio_retained = 1`.
- On the Mac, `earbridge` passes PCM to the `EarCLI` worker over a pipe and stores no audio.

## Retention

- The transcript keeps unpinned segments for the retention window: 30 minutes by default, with choices of 1 minute, 10 minutes, 30 minutes, 2 hours and 24 hours. `RetentionPolicy` clamps any value to 60 to 86,400 s and runs every 30 s and when the app comes to the foreground.
- Pinned segments survive retention until the user forgets them.
- Demo mode pauses retention while it runs.

## Forgetting

- Three ways delete recent segments, pinned or not: shaking the phone, the "Forget the last 10 minutes" button, and saying "forget the last N minutes". The spoken form needs no approval.
- Each purge logs a `purges` row with counts only.
- Known gap: a purge on the phone does not reach the Mac's `ear.db` mirror, and the mirror has no retention policy. To clear it, delete `~/Library/Application Support/ClipIREar/ear.db`.

## Network

- `EgressGuard` is the only way the app opens a network session. It allows localhost, the paired Mac, and model hosts only inside an explicit download window. It checks every redirect hop and records each destination, allowed or not, in `ConnectionLedger`, which the Debug screen shows.
- Web search is off by default. When you save your own Brave Search API key in Settings, the app keeps it in the Keychain on this device only and allows one more host, `api.search.brave.com`. A search sends the words you said after "search the web for" and nothing else: no transcript, no context, no identifiers. The results are used for one answer and not stored. The answer is stored like any other answer and leaves the phone only to a paired Mac.
- Allowed model hosts are listed in `tools/models/sources.json`. Downloads run only on `make models`, and each file's SHA-256 is checked against `tools/models/models.lock.json`. Where upstream publishes no hash, the first download records it and later downloads must match.
- The link to the Mac uses TLS with a pinned self-signed certificate when paired by QR code. Pairing by typed code uses plain `ws://` and is meant for `--no-tls` on an already encrypted link such as Tailscale.
- `earbridge` talks only to Ollama on `127.0.0.1:11434` and never pulls from a model registry; `earbridge doctor --fix` imports the pinned GGUF file.
- `tools/ci/egress_check.py` fails CI when the code contains a URL host outside the allow-list or a pattern from `tools/ci/forbidden.txt`: cloud AI and speech APIs, analytics, telemetry and crash-reporting SDKs, and emotion-recognition models.
- Known gap: the Mac's `/health` and `/ear/v1/export` HTTP endpoints do not check the pairing token. The export endpoint returns aggregate counts and latencies only.

## People

- No speaker identification. Every segment has `speaker = 'unknown'`; speaker enrolment is not implemented.
- No emotion inference. CI rejects SenseVoice and emotion2vec by name.
- The pairing token and Mac address live in the keychain, not in settings or exports.

## Transparency

- The app shows a persistent listening state and a Live Activity while it listens.
- iOS shows its orange microphone indicator while the app captures audio. That indicator is expected.
- Onboarding states what is captured, the retention choice and how to forget.

## Export

`Exporter` is the only code that produces data meant to leave the app. By default an export holds derived measures: counts, intents, tiers, latencies, action responses, purge counts and MetricKit sums. Question and answer text and the transcript are included only when the user ticks them for that export. See [SCHEMA.md](SCHEMA.md#export-format) for the fields.

## Device metrics

`MetricsIntake` stores MetricKit payloads in the local `device_metrics` table. Exports include sums over the last 7 days, never the raw payloads.
