# XSIGHT AI Integration

XSIGHT uses two kinds of AI:

1. **Chat** — text replies for the conversational assistant.
2. **Vision** — short visual description of the patient (Robot Mode).

The backend (`server/`) exposes both behind `/chat` and `/vision`. Pick the
provider that matches your budget and privacy needs.

---

## Chat Provider — OpenCode Zen

OpenAI-compatible. Get a key at https://opencode.ai/auth.

Free models (good for demo, **they log prompts** — no PHI):

| Model                     | Notes                                                  |
| ------------------------- | ------------------------------------------------------ |
| `big-pickle`              | Stealth model, free for now                            |
| `deepseek-v4-flash-free`  | Free but leaks reasoning; XSIGHT strips it server-side |
| `nemotron-3-super-free`   | NVIDIA trial only, no production                       |

Production-grade (paid, zero-retention) — **recommended for clean replies**:

| Model               | Input / Output (per 1M tokens) | Notes                       |
| ------------------- | ------------------------------ | --------------------------- |
| `claude-haiku-4-5`  | $1 / $5                        | Default for XSIGHT          |
| `gpt-5-nano`        | $0.05 / $0.40                  | Fastest                     |
| `gemini-3-flash`    | $0.50 / $3.00                  | Cheap + multimodal-ready    |

Set in `.env`:

```bash
ZEN_API_KEY=sk-...
ZEN_MODEL=deepseek-v4-flash-free
```

---

## Vision Provider — pick one

Set `VISION_PROVIDER` in `.env` to one of: `zen`, `gemini`, `ollama`, `mock`.

The backend auto-falls back: `zen → gemini → ollama → mock` if keys are missing.

### 1. Ollama (laptop-local, fully free, fully offline) — recommended for capstone

Runs the vision model on your own machine. No API costs. No data leaves the laptop.

```bash
# Install (one-time)
curl -fsSL https://ollama.com/install.sh | sh

# Pull a vision-capable model — pick by size/speed tradeoff
ollama pull moondream          # ~1.7GB — tiny, FAST, great object ID (recommended)
# or
ollama pull qwen2.5vl:3b       # ~3GB — best small-model accuracy
# or
ollama pull llava:7b           # ~4.7GB — balanced general-purpose
# or
ollama pull qwen2.5vl:7b       # ~6GB — high quality, slower

# Start the server (defaults to :11434)
ollama serve
```

`.env`:

```bash
VISION_PROVIDER=ollama
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_VISION_MODEL=moondream
```

Speed/size comparison (rough, on mid-range laptop CPU):

| Model            | Size    | Latency / frame | Strength                   |
| ---------------- | ------- | --------------- | -------------------------- |
| `moondream`      | ~1.7 GB | 0.5–1.5 s       | Fast object ID, low RAM    |
| `qwen2.5vl:3b`   | ~3 GB   | 1–2 s           | Best accuracy at this size |
| `llava:7b`       | ~4.7 GB | 2–4 s           | General captioning         |
| `qwen2.5vl:7b`   | ~6 GB   | 3–6 s           | Highest detail             |

Hardware notes:

| RAM/VRAM   | Recommended model |
| ---------- | ----------------- |
| 4–8 GB RAM | `moondream`       |
| 8–16 GB    | `qwen2.5vl:3b`    |
| 16 GB+     | `llava:7b`        |
| 24 GB+ VRAM| `qwen2.5vl:7b`    |

If your laptop has an NVIDIA GPU, Ollama uses CUDA automatically. Apple
Silicon uses Metal. CPU-only works but is slower (a few seconds per frame).

### 2. Google Gemini Free Tier (cloud, free, generous limits)

Free key at https://aistudio.google.com/app/apikey.

At time of writing the free tier on `gemini-2.0-flash` allows ~15 requests
per minute and ~1M tokens per day — plenty for a capstone demo.

`.env`:

```bash
VISION_PROVIDER=gemini
GEMINI_API_KEY=AIza...
GEMINI_MODEL=gemini-2.0-flash
```

### 3. OpenCode Zen (paid)

Best quality, lowest setup. Reuses the `ZEN_API_KEY`.

`.env`:

```bash
VISION_PROVIDER=zen
ZEN_VISION_MODEL=gemini-3-flash
```

### 4. Mock

For UI testing only. Returns a stub description.

```bash
VISION_PROVIDER=mock
```

---

## Privacy Recommendations

| Use case              | Vision provider |
| --------------------- | --------------- |
| Capstone demo         | `ollama` (local) — never leaves laptop |
| Free cloud, low PHI   | `gemini`        |
| Production w/ paid    | `zen` + paid model |
| No vision needed      | `mock`          |

Always include a medical disclaimer in the app and never send identifiable
patient data to free/training-tier endpoints.

---

## How the App Calls It

```
Flutter Robot Mode
   ├─ takes camera frame
   └─ POST /vision  { image_b64, prompt }  → backend
                                              │
                                              ▼
                                       VISION_PROVIDER router
                                       ├─ zen     → opencode.ai
                                       ├─ gemini  → generativelanguage.googleapis.com
                                       └─ ollama  → localhost:11434
```

The Flutter app does not need any vision API key. The backend handles
everything. Switch providers by changing `VISION_PROVIDER` in `.env` and
restarting `python main.py`.
