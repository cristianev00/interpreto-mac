#!/usr/bin/env python3
"""Report on a recording made with Help → Start Recording for Analysis.

    scripts/analyze-recording.py "~/Desktop/Interpreto Diagnostics/<stamp>" [reference.txt] [--no-rerun]

Reads events.log and session.json, then streams heard.caf again through every speech engine of
that direction (`--selftest`, real time) to compare them. With reference.txt (what was really
said, one sentence per line) it scores each engine: word errors for English, character errors
for Chinese.
"""
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Interpreto.app/Contents/MacOS/Interpreto")
ENGINES = {"en": ["apple", "parakeet"], "zh": ["apple", "sensevoice"]}
MODEL_DIR = os.path.expanduser("~/Library/Application Support/Interpreto/Models")
INSTALLED = {"apple": True,
             "parakeet": os.path.isdir(os.path.join(MODEL_DIR, "parakeet-tdt-0.6b-v3")),
             "sensevoice": os.path.isfile(os.path.join(MODEL_DIR, "sensevoice/model.int8.onnx"))}


def events(folder):
    rows = []
    for line in open(os.path.join(folder, "events.log"), encoding="utf-8"):
        m = re.match(r"\s*([\d.]+)\s{2}(.*)", line.rstrip("\n"))
        if m:
            rows.append((float(m.group(1)), m.group(2)))
    return rows


def stats(values, unit="s"):
    if not values:
        return "none"
    v = sorted(values)
    return f"median {statistics.median(v):.2f}{unit}, worst {v[-1]:.2f}{unit} ({len(v)})"


def tokens(text, zh):
    text = text.lower()
    if zh:
        return [c for c in text if "㐀" <= c <= "鿿" or c.isalnum()]
    text = re.sub(r"[^a-z0-9' ]+", " ", text.replace("%", " percent"))
    return [w for w in text.split() if w not in {"uh", "um", "erm", "er", "mm", "hmm", "ah"}]


def edits(a, b):
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
    return d[len(b)]


def rerun(caf, direction, engine):
    """Streams the recording through one engine; returns (sentences, delays)."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "heard.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", caf, wav], check=True)
        out = subprocess.run([APP, "--selftest", direction, "--engine", engine, wav],
                             capture_output=True, text=True, timeout=3600).stdout.splitlines()
    sentences, delays = [], []
    for i, line in enumerate(out):
        m = re.match(r"\[sentence ([\d.]+)s, translated ([\d.]+)s after the last word\]", line)
        if m and i + 2 < len(out):
            delays.append(float(m.group(2)))
            sentences.append((out[i + 1].strip(), out[i + 2].strip().lstrip("→ ").strip()))
    return sentences, delays


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    folder = os.path.expanduser(args[0])
    reference = open(args[1], encoding="utf-8").read() if len(args) > 1 else None
    log = events(folder)
    session = json.load(open(os.path.join(folder, "session.json"), encoding="utf-8")) \
        if os.path.exists(os.path.join(folder, "session.json")) else {"items": []}

    print(f"# Interpreto recording: {os.path.basename(folder.rstrip('/'))}\n")
    for _, e in log:
        if e.startswith(("settings:", "translator:", "devices:", "speech engine:")):
            print("-", e)
    length = log[-1][0] if log else 0
    print(f"- recording length {length:.0f} s\n")

    translated = [float(m.group(1)) for _, e in log if (m := re.match(r"TRANSLATED in ([\d.]+)s", e))]
    voice = [float(m.group(1)) for _, e in log if (m := re.match(r"voice starts playing ([\d.]+)s", e))]
    memory = [float(m.group(1)) for _, e in log if (m := re.match(r"memory (\d+) MB", e))]
    print("## Live performance (as it happened)\n")
    print("- sentences:", sum(1 for _, e in log if e.startswith("SENTENCE (")) or
          sum(1 for _, e in log if e.startswith("SENTENCE ")))
    print("- translation time:", stats(translated))
    print("- voice starts after translation:", stats(voice))
    print("- memory:", stats(memory, " MB"))
    for label, key in [("background speech ignored", "ignored background speech"),
                       ("sentences skipped by the voice to catch up", "skipped"),
                       ("audio device changes", "audio configuration changed"),
                       ("errors", "failed")]:
        n = sum(1 for _, e in log if key in e)
        if n:
            print(f"- {label}: {n}")
    print("\n## What the app heard and translated\n")
    for it in session["items"]:
        mark = " (not spoken)" if it.get("notSpoken") else ""
        print(f"- [{it['start']:.1f}s] {it['source']}\n  → {it['translation'] or '(no translation)'}{mark}")

    caf = os.path.join(folder, "heard.caf")
    if "--no-rerun" in sys.argv or not os.path.exists(caf):
        return
    if not os.access(APP, os.X_OK):
        sys.exit(f"\nBuild the app first (./scripts/build-app.sh): {APP}")
    direction = session.get("direction") or ("zh" if any("中文 → English" in e for _, e in log) else "en")
    zh = direction == "zh"
    print(f"\n## Same audio through each {'Chinese' if zh else 'English'} engine (real time)\n")
    for engine in ENGINES[direction]:
        if not INSTALLED[engine]:
            print(f"### {engine}: not downloaded, skipped\n")
            continue
        sentences, delays = rerun(caf, direction, engine)
        heard = " ".join(s for s, _ in sentences)
        score = ""
        if reference:
            ref = tokens(reference, zh)
            score = f", {'character' if zh else 'word'} errors {100 * edits(ref, tokens(heard, zh)) / max(len(ref), 1):.1f}%"
        print(f"### {engine}: {len(sentences)} sentences, translated {stats(delays)} after the last word{score}\n")
        for s, t in sentences:
            print(f"- {s}\n  → {t}")
        print()


if __name__ == "__main__":
    main()
