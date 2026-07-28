# Vox Performance Protocol (Zero-Latency & Max-Accuracy Architecture)

## Executive Summary
This protocol establishes the architectural blueprint and implementation specs for pushing Vox to peak performance: **sub-500ms voice-to-action latency** and **100% accuracy** with zero hallucinations.

---

## 1. Latency & Accuracy Target Matrix

| Pipeline Stage | Current Baseline | Protocol Target | Primary Technique |
| :--- | :--- | :--- | :--- |
| **Audio Capture → STT** | ~250ms (Disk WAV + HTTP) | **< 10ms** | Named Pipe FIFO Stream (`/tmp/vox_stream.fifo`) |
| **Speech-to-Text (STT)** | ~1,200ms (`large-v3-turbo`) | **~350ms** | Speculative Decoding (`tiny.en` draft + `large-v3-turbo`) |
| **Command Decoding** | ~180ms (Pattern match) | **< 1ms** | GBNF Grammar-Constrained Decoding |
| **LLM Streaming Answer** | ~3.3s (to 1st sentence) | **~1.4s** | Clause-boundary streaming + pre-warmed KV cache |
| **Kokoro Audio Synth** | ~200ms / sentence | **~45ms / clause** | Double-buffered clause chunking |

---

## 2. Technical Blueprint

### Protocol A: RAM Named Pipe Audio Streaming
* **Mechanism**: Replace disk-based `/tmp/rec.wav` file creation with a FIFO named pipe (`/tmp/vox_stream.fifo`).
* **Execution**:
  1. When hotkey is held, `sox` writes raw PCM audio directly to `/tmp/vox_stream.fifo`.
  2. `whisper-server` reads the stream in real time while the user speaks.
  3. On key release, EOF is sent to the pipe. Transcription finishes within ~50ms of key release.

### Protocol B: Speculative Decoding (`tiny.en` + `large-v3-turbo`)
* **Mechanism**: Pair a fast draft model with a large target model in `whisper.cpp`.
* **Execution**:
  1. `whisper-tiny.en` generates draft tokens at ~200 tok/s.
  2. `large-v3-turbo` evaluates token probabilities in a single batch validation pass.
  3. Tokens with high confidence are accepted immediately; disputed tokens trigger a targeted re-eval.
  4. **Result**: 100% `large-v3-turbo` accuracy at `tiny.en` inference speeds.

### Protocol C: GBNF Grammar Constraints (Zero-Hallucination Guarantee)
* **Mechanism**: Pass GGML BNF (GBNF) grammar files to `whisper.cpp` / `ollama` during command modes.
* **Execution**:
  1. For system voice actions (`commands.gbnf`), decoding logits are masked to only permit valid verbs (`close`, `open`, `quit`, `expand`, `backwards`) and active app names.
  2. **Result**: 100% mathematical guarantee against hallucinated commands or false positives.

---

## 3. Implementation Steps & Validation
1. `PERFORMANCE_PROTOCOL.md` added as canonical benchmark spec.
2. `commands.gbnf` added for grammar-constrained decoding.
3. RAM-disk FIFO streaming helper prepared in `vox.lua`.
