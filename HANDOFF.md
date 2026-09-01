# XSIGHT Handoff

Snapshot of the project state as of 2026-05-27.

## What XSIGHT Is

An IoT-style AI chatbot robot for thoracic assessment. Three pieces:

1. **Flutter mobile app** (`lib/`) — neumorphic monochrome UI, Robot Mode (camera + voice), Voice Mode (WebSocket realtime voice), Settings (server IP), Dashboard with mock vitals.
2. **Python FastAPI backend** (`server/`) — chat proxy, vision proxy, optional realtime voice pipeline, mock vitals/lung-sound.
3. **Local AI gateway** at `http://localhost:20128/v1` — OpenAI-compatible router routing to GitHub Copilot models, Gemini, Claude, etc. Authenticated with `LOCAL_API_KEY` in `server/.env`.

## Current Working Setup

### Backend
- Run: `cd server && python main.py`
- Loads `server/.env` automatically via `python-dotenv`.
- Active config:
  - `CHAT_PROVIDER=local` → `gh/gpt-4o-mini` for chat
  - `VISION_PROVIDER=local` → `gh/gpt-4o` for vision
  - `LOCAL_BASE_URL=http://localhost:20128/v1`
  - `LOCAL_API_KEY=<your-key>` (set in `.env`)
- Auto-fallback chain on errors: `local → zen → gemini → ollama → mock`
- Banner prints active provider + model on startup.

### Flutter App
- Run: `flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8000` (emulator) or set IP via in-app Settings.
- Settings persists server IP via `shared_preferences`.
- `flutter analyze` clean. `flutter build apk --debug` succeeds.

## Repo Layout

```
xsight/
├── HANDOFF.md            ← this file
├── DESIGN_SYSTEM.md      ← neumorphism + monochrome design tokens
├── MOBILE_PIPELINE.md    ← original Flutter pipeline plan
├── AI_INTEGRATION.md     ← AI provider docs (chat + vision)
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   ├── core/
│   │   ├── theme/        ← XSColors, XSSpacing, XSRadius, XSShadows, XSTypography, XSTheme
│   │   ├── api/zen_chat_client.dart   ← REST + SSE streaming chat client
│   │   ├── voice/
│   │   │   ├── voice_client.dart      ← WebSocket /ws/voice client
│   │   │   └── pcm_player.dart        ← flutter_soloud streaming PCM player
│   │   └── config/xs_config.dart      ← compile-time defaults
│   ├── state/
│   │   ├── chat_controller.dart       ← bubble chat state
│   │   ├── robot_controller.dart      ← Robot Mode (Google STT + flutter_tts + AI + camera vision)
│   │   └── xs_settings.dart           ← runtime server-IP override
│   └── ui/
│       ├── components/                ← XSCard, XSButton, XSStat, XSChartCard, ...
│       └── screens/
│           ├── splash_screen.dart
│           ├── onboarding_screen.dart
│           ├── disclaimer_screen.dart
│           ├── root_shell.dart
│           ├── dashboard_screen.dart
│           ├── chat_screen.dart
│           ├── lung_sound_screen.dart
│           ├── summary_screen.dart
│           ├── robot_mode_screen.dart   ← on-device voice (Google STT + flutter_tts)
│           ├── voice_mode_screen.dart   ← server-side voice (faster-whisper + Kokoro)
│           └── settings_screen.dart
├── android/   ios/   test/
└── server/
    ├── main.py                  ← runner: python main.py
    ├── .env                     ← real config (gitignored)
    ├── .env.example
    ├── requirements.txt
    ├── requirements-voice.txt   ← optional STT/TTS deps
    └── app/
        ├── main.py              ← FastAPI app, all REST/WS routes
        ├── vision.py            ← vision provider router (local/zen/gemini/ollama)
        ├── voice.py             ← faster-whisper + Kokoro + webrtcvad wrappers
        └── static/index.html    ← browser test page at /voice
```

## Backend Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Status + active providers + voice loadability |
| POST | `/chat` | Non-streaming chat (uses CHAT_PROVIDER) |
| POST | `/chat/stream` | SSE streaming chat — used by RobotController |
| POST | `/vision` | Single image → short description |
| POST | `/lung-sound` | Mock classifier (replace with real CNN) |
| POST | `/vitals` | Rule-based risk level from vitals |
| WS | `/ws/vitals` | Streams mock vitals every 1s |
| WS | `/ws/voice` | Realtime voice loop (PCM in, PCM out) |
| GET | `/voice` | Browser test client (neumorphic) |
| GET | `/debug/chat?q=...` | Quick chat smoke test |
| GET | `/debug/vision` | Vision smoke test using built-in JPEG |
| GET | `/debug/bench` | Times chat+vision end-to-end |
| POST | `/debug/warmup` | Re-warm Ollama model |

## Provider Matrix

### Chat
- **`local`** (default) — `gh/gpt-4o-mini` via gateway. Verified, fast (~1.5s).
- **`zen`** — OpenCode Zen with `gemini-3-flash` / `claude-haiku-4-5` etc. (paid).
- Mock fallback when nothing configured.

### Vision
- **`local`** (default) — `gh/gpt-4o`. Verified accurate person/object detection (~3s).
- **`zen`** — OpenCode Zen `gemini-3-flash`. (currently out of credits)
- **`gemini`** — Google Gemini Free Tier (15 RPM, 1M tok/day).
- **`ollama`** — local laptop model (`qwen2.5vl:3b` / `moondream`).
- **`mock`** — stub.
- Auto-falls back through chain on auth/connection errors.

### Voice (optional)
- STT: `faster-whisper` (`small` int8 default).
- TTS: `kokoro-onnx` (Kokoro-82M, ~500 MB VRAM).
- VAD: `webrtcvad` (aggressiveness 2, 650 ms end-silence).
- All lazy-loaded via `voice.py` — backend runs fine without voice deps installed.

## Setup

### Backend
```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# edit .env if needed — defaults are wired to the local gateway
python main.py
```

Optional voice pipeline:
```bash
pip install -r requirements-voice.txt
# Download from https://huggingface.co/hexgrad/Kokoro-82M:
#   kokoro-v0_19.onnx     → server/
#   voices.bin            → server/
```

### Flutter
```bash
flutter pub get
flutter run
# In-app: open Settings → enter server IP (e.g. 192.168.1.59:8000) → Test → Save
```

## Key Features

### Robot Mode (`robot_mode_screen.dart`)
- Camera preview inside neumorphic orb.
- On-device Google STT + `flutter_tts`.
- Continuous listen-think-speak loop with mic auto-rearm via TTS handlers.
- Tap orb or mic-off button to interrupt mid-sentence.
- Vision-intent detection: `_wantsVision()` triggers camera capture; `_isPureVisualQuery()` skips chat round-trip and speaks vision result directly.
- Streams chat via `/chat/stream` and pipes sentences into TTS as they arrive.
- Server-side `_strip_thinking()` removes chain-of-thought leakage from open models.

### Voice Mode (`voice_mode_screen.dart`)
- Streams mic PCM16 16 kHz over WebSocket `/ws/voice`.
- Server runs VAD → STT → chat → TTS, streams PCM16 24 kHz back.
- Native PCM playback via `flutter_soloud` (`PcmPlayer`).
- Tap orb to interrupt, refresh icon to reset history.
- Requires `requirements-voice.txt` + Kokoro model files on the server.

### Settings (`settings_screen.dart`)
- Server IP input with normalization (accepts `192.168.1.20`, `192.168.1.20:8000`, `http://...`).
- Test button pings `/health` and shows active providers.
- Reset returns to compile-time default.
- Persisted via `XSSettings` (`SharedPreferences`).

### Dashboard (`dashboard_screen.dart`)
- Live mock vitals (HR, SpO2, Temp, RR) — fixed 1.1 aspect ratio + `FittedBox` so tiles never overflow.
- Heart-rate trend chart (custom-painted monochrome line).
- Robot Mode + Voice Mode launch buttons side by side.
- Settings + Notifications icons in app bar.

## Verified Builds

- `python3 -m py_compile server/main.py server/app/main.py server/app/vision.py server/app/voice.py` → OK
- `flutter analyze` → clean
- `flutter build apk --debug` → succeeds

## Known Issues / Gotchas

1. **`record` 5.x** had a Linux build conflict — pinned to `^6.1.1`.
2. **`flutter_soloud`** API: use `format: BufferType.s16le`, not `pcmFormat: BufferPcmType.s16le` (3.5.x rename).
3. **`kokoro-onnx==0.3.6`** requires `onnxruntime>=1.20.1` — `requirements-voice.txt` updated to use `>=` pins.
4. **`speech_to_text`** API deprecation: `listenFor`, `pauseFor`, `partialResults`, `cancelOnError`, `listenMode` should move to `SpeechListenOptions`. Currently warnings only, not fatal.
5. **OpenCode Zen** account is out of credits — `local` provider is the working default.
6. **`gh/gpt-4o-mini` vision** rejects images on the gateway (`media type not supported`). Use `gh/gpt-4o` for vision.
7. **`gh/gemini-3-flash-preview`** hits quota frequently. Hot-swap via `.env` if needed.
8. **Moondream** on small laptops returns garbage tokens for real photos. Server now drops low-quality output via `_looks_like_real_description()` and recommends `qwen2.5vl:3b`.

## Active `.env`

See `server/.env.example` for all available keys.
Copy it to `server/.env` and fill in your own credentials.

> **Never commit real API keys to this file.**

## Connect From Phone

- Android emulator → `http://10.0.2.2:8000`
- iOS simulator → `http://localhost:8000`
- Physical device on same Wi-Fi → laptop LAN IP (`http://192.168.1.59:8000`)

## What Works End-to-End

- ✅ Dashboard renders, vitals tick, no overflow.
- ✅ Settings: enter IP → Test → see `/health` summary.
- ✅ Robot Mode: speak → STT → chat (streaming) → TTS → re-listen.
- ✅ Robot Mode vision-only path: "what do you see" → camera shot → `/vision` → speak.
- ✅ Robot Mode interrupt: tap orb → mic re-arms.
- ✅ Browser voice test page (`/voice`) — works once Kokoro is installed.
- ✅ Backend SSE streaming through gateway.
- ✅ Reasoning-leakage stripping (`<think>` tags + draft markers + last-paragraph fallback).

## What's Stubbed

- Lung sound classifier — returns mock label based on byte count. Replace with MFCC + CNN trained on ICBHI.
- Vitals dashboard data — random walks. Wire to `/ws/vitals` or real ESP32 stream.
- Lung Sound screen — mock recording UI; doesn't upload yet.
- Summary screen — uses fixed mock data.
- Voice Mode requires Kokoro install on the server before it actually plays audio (currently throws clear errors via `voice_status()`).

## Next Likely Tasks

1. Hot-swap `LOCAL_VISION_MODEL` back to `gh/gpt-4o` if quotas open up.
2. Install `requirements-voice.txt` and Kokoro to enable Voice Mode end-to-end.
3. Wire `lung_sound_screen.dart` upload → POST `/lung-sound`.
4. Subscribe Dashboard vitals to `/ws/vitals` instead of using random walks.
5. Move `speech_to_text` calls to `SpeechListenOptions` to silence deprecation warnings.
6. Add streaming vision (per-frame) to Voice Mode for live observation.
7. Replace mock lung-sound with a real CNN.

## Useful Commands

```bash
# Backend smoke tests
curl http://localhost:8000/health
curl 'http://localhost:8000/debug/chat?q=hello'
curl http://localhost:8000/debug/vision
curl 'http://localhost:8000/debug/bench?q=hi'

# Flutter
flutter pub get
flutter analyze
flutter build apk --debug
flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8000

# Python
python3 -m py_compile server/main.py server/app/main.py server/app/vision.py server/app/voice.py
```

## Disclaimer Reminder

Always show medical disclaimer in app: "AI-assisted screening tool, not a medical diagnosis." Never send real PHI through free Zen models or training-tier endpoints.
