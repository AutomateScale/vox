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


def speak(text, voice, speed, my_gen):
    """Streaming: synthesize sentence N+1 WHILE sentence N plays — first
    words are audible after one short synth instead of the whole answer's."""
    global player
    with synth_lock:
        for i, sent in enumerate(sentences(text)):
            if my_gen != gen:
                return
            wav = synth_one(sent, voice, speed, i)   # overlaps prior playback
            if my_gen != gen:
                return
            with state_lock:
                prev = player
            if prev:
                while prev.poll() is None:           # let the last one finish
                    if my_gen != gen:
                        return
                    time.sleep(0.05)
            if my_gen != gen:
                return
            with state_lock:
                player = subprocess.Popen(["afplay", wav])


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
        global gen
        if self.path == "/stop":
            gen += 1
            stop_playback()
            self._ok()
            return
        if self.path == "/speak":
            n = int(self.headers.get("Content-Length", 0))
            try:
                d = json.loads(self.rfile.read(n))
            except Exception:
                self.send_response(400)
                self.end_headers()
                return
            gen += 1
            stop_playback()
            threading.Thread(
                target=speak,
                args=(d.get("text", ""), d.get("voice", "vox"),
                      float(d.get("speed", 1.0)), gen),
                daemon=True).start()
            self._ok()
            return
        self.send_response(404)
        self.end_headers()


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
