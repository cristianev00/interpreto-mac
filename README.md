# Interpreto for Mac

Live English ⇄ Chinese speech translation, entirely on your Mac, using Apple's on-device engines:
SpeechAnalyzer (speech recognition), Translation (translation) and AVSpeechSynthesizer (voices).
No Python, no bundled models; macOS downloads its English and Chinese models once.

Requires macOS 26.4 or later on Apple silicon.

    ./scripts/build-app.sh          # → build/Interpreto.app
    open build/Interpreto.app

Self-test (streams recordings through the real pipeline at real-time speed):

    build/Interpreto.app/Contents/MacOS/Interpreto --selftest en a.wav b.wav …
    INTERPRETO_DEBUG=1 … --selftest zh …    # also prints raw recognizer results and pauses

Unit tests (Swift Testing, run with Xcode's toolchain or ⌘U after `xed .`):

    swift test
