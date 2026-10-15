# Phone to Mac protocol (v1)

The phone talks to `earbridge` over one WebSocket. `mac/earbridge/earbridge/protocol.py` defines every message. Running `uv run --project mac/earbridge python -m earbridge.protocol` writes the 19 JSON Schemas in `docs/protocol/<type>.schema.json`. The Python tests and the Swift `ProtocolCodecTests` validate against those files, and a test fails when the files and the definitions differ. The Swift codec is `Sources/EarCore/Sync/ProtocolCodec.swift`.

## Transport and discovery

- URL: `wss://<host>:9478/ear/v1`. `earbridge serve` uses TLS by default with a self-signed RSA-2048 certificate kept in `~/Library/Application Support/ClipIREar/`. With `--no-tls` it serves plain `ws://`.
- Bonjour: service `_clipir-ear._tcp`, registered with macOS `dns-sd`, TXT records `v=1`, `name=<mac name>`, `fp=<certificate SHA-256 or "none">`.
- Pairing: `earbridge pair` creates an 8-character token from an alphabet without 0, O, 1 and I, saves it, and prints it both as a short code and as a QR code holding `{"host","port","token","fp"}`. `fp` is the lower-case hex SHA-256 of the certificate in DER form.
- Certificate pinning: when the QR carries a fingerprint, `BridgeClient` connects with `wss://` and accepts only that certificate; CA trust is not consulted. Pairing by typed code carries no fingerprint, so it uses plain `ws://`. Use it only with `earbridge serve --no-tls`, for example over Tailscale, which encrypts the link itself.
- The phone stores the pairing in the keychain.

## Frames

Text frames are JSON control messages: `{"t": "<type>", "id": "<optional id>", ...fields}`.

Binary frames are `[1 byte kind][4 bytes little-endian uint32 seq][payload]`:

| Kind | Direction | Payload |
|---|---|---|
| `0x01` | phone to Mac | PCM16 mono 16 kHz |
| `0x02` | Mac to phone | PCM16 mono 24 kHz, TTS audio |
| `0x03` | | Opus, reserved |

## Phone to Mac messages

| `t` | Required fields | Optional fields | Notes |
|---|---|---|---|
| `hello` | `token`, `client{app,version,device,os}`, `caps{pcm_in}` | | Must be the first message; the Mac replies `welcome` |
| `session.start` | `session_id`, `locale`, `mode` | | Starts ambient recognition; PCM frames follow |
| `session.stop` | `session_id` | | The Mac replies `segments.sync` |
| `query.begin` | `query_id`, `session_id` | | Push to talk pressed; PCM frames that follow are question audio |
| `query.end` | `query_id`, `window_seconds` | `segments[]`, `notes[]`, `at` | Push to talk released; the Mac finalises the question and answers |
| `query.cancel` | `query_id` | | Stops generation and speech |
| `ping` | `ts` | | Round-trip measurement, every 5 s |

`segments[]` items are `{t0, t1, text, speaker?, id?}`. When present, the Mac uses them as the transcript window instead of its own store. `at` is the pipeline time the question refers to; the harness uses it.

## Mac to phone messages

| `t` | Required fields | Optional fields |
|---|---|---|
| `welcome` | `server{version,models{asr,llm,tts}}`, `session_token` | |
| `asr.partial`, `asr.final` | `session_id`, `text`, `t0`, `t1` | `query_id`, `confidence`, `speaker` |
| `answer.token`, `answer.sentence` | `query_id`, `text` | `knowledge_tier` |
| `answer.action` | `query_id`, `action` | |
| `answer.done` | `query_id`, `prompt_tokens`, `completion_tokens`, `model`, `latency` | `knowledge_tier`, `question`, `intent` |
| `tts.start` | `query_id`, `sample_rate` | |
| `tts.end` | `query_id` | |
| `pong` | `ts` | |
| `error` | `code`, `message` | `query_id` |
| `segments.sync` | `session_id`, `segments[]` | |

Details:

- `asr.final` with a `query_id` reports the recognised question, with `t0` and `t1` set to 0.
- `answer.action` carries `{"question", "intent"}`. The Mac only flags an action request; the phone builds the proposal, asks for approval and executes it. The Mac then sends `answer.done` with zero tokens.
- `answer.done.latency` keys are seconds after `query.end` arrived: `queryEnd`, `asrFinal`, `contextReady`, `llmFirstToken`, `llmFirstSentence`, `ttsFirstAudio`, `done`.
- TTS audio arrives as kind `0x02` frames between `tts.start` and `tts.end`, one frame per chunk the synthesizer produces.
- `error` codes sent today: `bad_message` (the message failed validation), `no_question` (no speech in the question audio), `llm_failed`.

## Close codes

| Code | Meaning |
|---|---|
| 4400 | The first message was not a valid `hello`, or none arrived within 10 s |
| 4401 | Wrong token |
| 4429 | More than 5 bad `hello`s from one address in 60 s |

## Behaviour

- The phone always runs its own recognizer. It mirrors ambient PCM to the Mac with `session.start` and `session.stop` only when the tier policy is not `phone`.
- During a question the phone streams the audio to the Mac and decodes it locally at the same time. If no `answer.token` arrives within 3 s of `query.end`, or on `error` or a disconnect, the phone sends `query.cancel`, plays the fallback earcon and answers on the device. Its latency record then has `fallback: true`.
- A `query.begin` while an answer is running cancels that answer.
- The Mac keeps its own `ear.db` mirror of the segments it recognised. After `session.stop` it sends `segments.sync` so the phone's store is complete.

## HTTP on the same port

| Request | Returns |
|---|---|
| `GET /health` | `{"ok", "version", "fp"}` |
| `GET /ear/v1/export?session=<id>` | Derived measures for one session from the Mac mirror: query count, queries by intent, tier split, median first-audio latency. 404 for an unknown session |

Neither endpoint checks the pairing token.
