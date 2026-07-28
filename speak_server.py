#!/usr/bin/env python3
"""Vox speech server — keeps Kokoro-82M warm so the alien answers instantly.

The one-shot speak_kokoro.py reloads the 325MB model on every phrase (2-4s
of dead air). This server loads it ONCE and then synthesizes in ~real time,
same pattern as whisper-server for transcription.

  POST /speak   {"text": "...", "voice": "vox", "speed": 1.0}
  POST /stop    kill current playback (Vox hushes when you start dictating)
  GET  /health  "warm" once the model is loaded

voice "vox" = our own alien: am_adam neural base -> sox FX (pitch up,
chorus doubling, shimmer, light reverb). Any other value = raw Kokoro voice.
Localhost only. Started and kept alive by vox.lua.
"""
import json
import os
import random
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SD = os.path.dirname(os.path.realpath(__file__))
MODEL = os.path.join(SD, "models/kokoro/kokoro-v1.0.onnx")
VOICES = os.path.join(SD, "models/kokoro/voices-v1.0.bin")
OUT = os.path.join(SD, "models/kokoro/srv.wav")
FX = os.path.join(SD, "models/kokoro/srv-fx.wav")
PORT = 8093

from kokoro_onnx import Kokoro
import soundfile as sf

kokoro = Kokoro(MODEL, VOICES)

state_lock = threading.Lock()
synth_lock = threading.Lock()
player = None
gen = 0


def sox_path():
    for p in ("/opt/homebrew/bin/sox", "/usr/local/bin/sox"):
        if os.path.exists(p):
            return p
    return None


def stop_playback():
    global player
    with state_lock:
        if player and player.poll() is None:
            player.terminate()
        player = None


def sentences(text):
    parts = re.split(r"(?<=[.!?…])\s+", text.strip())
    return [p for p in parts if p]


def synth_one(text, voice, speed, idx):
    """Synthesize one chunk into an alternating buffer; returns wav path."""
    base = "am_adam" if voice == "vox" else voice
    samples, sr = kokoro.create(text, voice=base, speed=speed, lang="en-us")
    out = os.path.join(SD, "models/kokoro/srv-%d.wav" % (idx % 2))
    sf.write(out, samples, sr)
    if voice == "vox":
        sox = sox_path()
        fx = os.path.join(SD, "models/kokoro/srv-fx-%d.wav" % (idx % 2))
        if sox and subprocess.run(
            [sox, out, fx,
             "pitch", "200",
             "chorus", "0.6", "0.9", "50", "0.4", "0.25", "2", "-t",
             "tremolo", "20", "15",
             "reverb", "10",
             "gain", "-n", "-1"],
            capture_output=True).returncode == 0:
            return fx
    return out


# Playback queue: sentences are synthesized one ahead while the previous
# one plays. /speak replaces the queue; /queue APPENDS (token-streaming from
# the LLM feeds sentences here as they're born); /stop clears everything.
queue = []
cond = threading.Condition()
buf_idx = 0


def worker():
    global player, buf_idx
    while True:
        with cond:
            while not queue:
                cond.wait()
            my_gen, text, voice, speed = queue.pop(0)
        if my_gen != gen:
            continue
        with synth_lock:
            buf_idx += 1
            wav = synth_one(text, voice, speed, buf_idx)  # overlaps playback
        if my_gen != gen:
            continue
        with state_lock:
            prev = player
        if prev:
            while prev.poll() is None:               # let the last one finish
                if my_gen != gen:
                    break
                time.sleep(0.05)
        if my_gen != gen:
            continue
        with state_lock:
            player = subprocess.Popen(["afplay", wav])


threading.Thread(target=worker, daemon=True).start()

# Instant acknowledgments: tiny pre-rendered phrases played the moment a
# question comes in (POST /ack) — zero synth wait, so Vox feels alive while
# the real first sentence is still being generated. Rendered once at boot,
# reused from disk on every later boot.
ACK_DIR = os.path.join(SD, "models/kokoro/acks")
ACKS = ["Hmm.", "Let me see.", "On it.", "One sec."]
ack_files = []


def prepare_acks():
    os.makedirs(ACK_DIR, exist_ok=True)
    sox = sox_path()
    for i, phrase in enumerate(ACKS):
        p = os.path.join(ACK_DIR, "ack-%d.wav" % i)
        if not os.path.exists(p):
            samples, sr = kokoro.create(phrase, voice="am_adam", speed=1.0,
                                        lang="en-us")
            raw = os.path.join(ACK_DIR, "ack-raw.wav")
            sf.write(raw, samples, sr)
            if sox and subprocess.run(
                [sox, raw, p,
                 "pitch", "200",
                 "chorus", "0.6", "0.9", "50", "0.4", "0.25", "2", "-t",
                 "tremolo", "20", "15",
                 "reverb", "10",
                 "gain", "-n", "-1"],
                capture_output=True).returncode == 0:
                pass
            else:
                os.replace(raw, p)
        ack_files.append(p)
    try:
        os.remove(os.path.join(ACK_DIR, "ack-raw.wav"))
    except OSError:
        pass


prepare_acks()


def enqueue(text, voice, speed, my_gen):
    with cond:
        for s in sentences(text):
            queue.append((my_gen, s, voice, speed))
        cond.notify()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _ok(self, body=b"ok"):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._ok(b"warm")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global gen, player
        if self.path == "/ack":
            with state_lock:
                busy = player and player.poll() is None
                if not busy and ack_files:
                    player = subprocess.Popen(
                        ["afplay", random.choice(ack_files)])
            self._ok()
            return
        if self.path == "/stop":
            gen += 1
            with cond:
                queue.clear()
            stop_playback()
            self._ok()
            return
        if self.path in ("/speak", "/queue"):
            n = int(self.headers.get("Content-Length", 0))
            try:
                d = json.loads(self.rfile.read(n))
            except Exception:
                self.send_response(400)
                self.end_headers()
                return
            if self.path == "/speak":          # replace whatever was playing
                gen += 1
                with cond:
                    queue.clear()
                stop_playback()
            enqueue(d.get("text", ""), d.get("voice", "vox"),
                    float(d.get("speed", 1.0)), gen)
            self._ok()
            return
        self.send_response(404)
        self.end_headers()


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
