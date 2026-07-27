#!/usr/bin/env python3
import os
import sys
import subprocess

script_dir = os.path.dirname(os.path.realpath(__file__))
model_path = os.path.join(script_dir, "models/kokoro/kokoro-v1.0.onnx")
voices_path = os.path.join(script_dir, "models/kokoro/voices-v1.0.bin")

if not os.path.exists(model_path) or not os.path.exists(voices_path):
    sys.exit(1)

text = sys.argv[1] if len(sys.argv) > 1 else ""
voice = sys.argv[2] if len(sys.argv) > 2 else "af_heart"
speed = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0

# "vox" = our OWN alien voice: neural base + sox FX (pitch up ~2 semitones,
# chorus doubling, subtle shimmer, a touch of space). Cute, otherworldly,
# still perfectly intelligible.
vox_mode = voice == "vox"
if vox_mode:
    voice = "am_adam"

if not text.strip():
    sys.exit(0)

try:
    from kokoro_onnx import Kokoro
    import soundfile as sf
    kokoro = Kokoro(model_path, voices_path)
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
    out_wav = os.path.join(script_dir, "models/kokoro/out.wav")
    sf.write(out_wav, samples, sample_rate)
    if vox_mode:
        sox = "/opt/homebrew/bin/sox"
        if not os.path.exists(sox):
            sox = "/usr/local/bin/sox"
        if os.path.exists(sox):
            fx_wav = os.path.join(script_dir, "models/kokoro/out-fx.wav")
            r = subprocess.run(
                [sox, out_wav, fx_wav,
                 "pitch", "200",
                 "chorus", "0.6", "0.9", "50", "0.4", "0.25", "2", "-t",
                 "tremolo", "20", "15",
                 "reverb", "10",
                 "gain", "-n", "-1"],
                capture_output=True)
            if r.returncode == 0:
                out_wav = fx_wav
    subprocess.run(["afplay", out_wav])
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
