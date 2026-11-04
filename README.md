# Interpreto for Mac

Live English ⇄ Chinese speech translation, entirely on your Mac. No Python, no cloud.

- **Speech recognition:** Apple SpeechAnalyzer (built in), or optional light models chosen by
  measurement: Parakeet for English (~480 MB, ~30% fewer errors on accented English) and
  SenseVoice for Chinese (~230 MB, ~25% fewer errors on Mandarin).
- **Translation:** Apple's on-device Translation framework, with a glossary (C programming term
  pack included) and a sound-alike term fixer.
- **Voices:** Apple voices, or the optional Matcha (Chinese, ~130 MB) and Paradee-8M (English, 4 voices,
  ~25 MB, ~0.07 s per sentence) voices.
- Listens to the microphone or to the Mac's own sound (all apps, or one app such as Zoom).

Optional models download once into `~/Library/Application Support/Interpreto/Models` and are
unloaded after 3 minutes idle. Requires macOS 26.4 or later on Apple silicon.

## Build and run

    ./scripts/build-app.sh          # → build/Interpreto.app
    open build/Interpreto.app

## Test

Unit tests (Swift Testing, with Xcode's toolchain; or `xed .` and ⌘U):

    swift test

Self-test: streams recordings through the real pipeline at real-time speed:

    build/Interpreto.app/Contents/MacOS/Interpreto --selftest en [--engine parakeet] a.wav b.wav …
    build/Interpreto.app/Contents/MacOS/Interpreto --selftest zh [--engine sensevoice] a.wav …
    INTERPRETO_DEBUG=1 … --selftest zh …    # also prints raw recognizer results and pauses

Audio device check: `--configtest` (each input/output pair, echo protection).

## Record and analyze a real session

Help → **Start Recording for Analysis** (⇧⌘R) listens in the current direction with your current
engine and voice, until you choose **Stop Recording** (10 minutes at most). It saves to
`~/Desktop/Interpreto Diagnostics/<time>/`: `heard.caf` (exactly what the recognizer heard),
`events.log` (settings, pauses, sentences, translation times, when the voice started, memory)
and `session.json` (what was heard and translated). Then:

    scripts/analyze-recording.py ~/Desktop/Interpreto\ Diagnostics/<time> [reference.txt]

prints the live timings and transcript, and streams the same audio through every downloaded
engine for that language. With `reference.txt` (what was really said) it scores each engine.
Tip: audio played by this Mac is removed by echo cancellation while the voice is on, so speak
yourself, or turn the voice off when playing recordings to the microphone.

## Third-party

FluidAudio (Apache-2.0) for Parakeet and Paradee-8M (Apache-2.0), sherpa-onnx (Apache-2.0) for SenseVoice and Matcha,
Silero VAD (MIT).
