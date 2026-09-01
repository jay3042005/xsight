# XSIGHT Agent Notes

## Shape
- Four things ship together and build independently. Treat them as separate stacks.
  - Flutter kiosk app — `lib/`, entrypoint `lib/main.dart`
  - FastAPI backend — `server/`, entrypoint `server/main.py` (routes mostly in `server/app/main.py`)
  - ESP32 sensor-hub firmware — `firmware/XSIGHT/XSIGHT.ino`
  - Phone-handoff relay — `web/`, a plain-HTML + serverless Vercel app (no React/Tailwind/TS)
- `README.md` is the default Flutter stub. `CLAUDE.md` is the most current architecture doc; also
  `AGENTS.md` (this file), `DESIGN_SYSTEM.md`, `KIOSK_FEATURES.md`, `voice-guide.md`,
  `server/README.md`, `server/.env.example`. `HANDOFF.md` and `MOBILE_PIPELINE.md` predate the
  kiosk rewrite — still right on AI providers, stale on screens and navigation.

## Backend Commands
- Setup: `cd server && python -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cp .env.example .env`.
- Run backend from `server/`: `python main.py`. This loads `server/.env` before importing `app.main`.
- Compile check from repo root: `python3 -m py_compile server/main.py server/app/main.py server/app/vision.py server/app/voice.py`.
- Tests from repo root after backend deps are installed: `PYTHONPATH=server LOG_LEVEL=ERROR server/.venv/bin/python -m pytest server/tests`.
- If `pytest` is missing in the existing venv, install/update backend deps first: `server/.venv/bin/python -m pip install -r server/requirements.txt`.

## Flutter Commands
- Install deps: `flutter pub get`.
- Analyze: `flutter analyze` — keep it clean; 7 pre-existing infos is the current baseline.
- Tests: `flutter test` (193 tests, ~6s once built). Two files catch most cross-stack mistakes:
  - `test/firmware_protocol_test.dart` — parses `XSIGHT.ino` as text and pins its menu tables,
    `AppState` ordinals, and the stations' timed reading windows against the Dart side.
  - `test/kiosk_layout_test.dart` — mounts every screen at landscape 1280x800, portrait 800x1280 and
    1024x768. Add new screens to it; overflow is silent in release builds.
- Debug APK: `flutter build apk --debug`.
- Android emulator backend URL: `flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8000`.
- Physical device backend URL must be LAN IP, or set it in app Settings; `XSSettings` persists it with `shared_preferences`.

## Firmware Commands
- Compile: `arduino-cli compile --fqbn esp32:esp32:esp32 firmware/XSIGHT` (~85% of flash; BluetoothSerial is most of it).
- Upload: `arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32 firmware/XSIGHT`.
- Libraries needed: Adafruit GFX, Adafruit SSD1306, Adafruit MLX90614, SparkFun MAX3010x.
- Editing the sketch without running `flutter test` is the likeliest way to break the kiosk. The
  menu tables, the `AppState` ordinals and the auto-finishing reading windows are all contracts with
  the Flutter side, and the only symptom of breaking one is the OLED and the screen disagreeing.
- A behaviour change in the sketch needs a reflash before it is testable — the app cannot work
  around old firmware.

## Relay Commands (`web/`)
- Deploy: `cd web && vercel deploy --prod --yes`. Production is the domain the kiosk calls, so a
  preview deployment does not fix a kiosk error.
- The relay brokers phone -> kiosk handoffs as store-and-pickup: an HTTPS page cannot POST to the
  kiosk's plain-HTTP LAN address, and serverless functions cannot hold a WebSocket. Session kinds
  are `xray` (film), `report` (PDF out) and `intake` (check-in form in).
- Adding a session kind means editing `web/api/session/index.js`, a handler under
  `web/api/session/[sid]/`, a page in `web/public/`, the `vercel.json` rewrite, **and**
  `Kind` + the poll/deliver branch in `server/app/handoff.py`. Miss the first and the backend gets
  a 400 it reports as a 502.

## Config And Secrets
- Never commit `server/.env`, API keys, gateway tokens, PHI, or real patient data.
- Backend provider config is in `server/.env.example`; active local setup commonly uses `CHAT_PROVIDER=local`, `VISION_PROVIDER=local`, `LOCAL_BASE_URL=http://localhost:20128/v1`.
- `/debug/*` endpoints are disabled unless `DEBUG_API_KEY` is set; call them with header `X-XSIGHT-Debug-Key: <key>`.
- Phone handoff needs `XSIGHT_RELAY_URL` and `XSIGHT_RELAY_KEY` (read in `server/app/handoff.py`);
  the relay side needs the same `XSIGHT_RELAY_KEY` plus `BLOB_READ_WRITE_TOKEN`. Unset means the
  kiosk reports handoff unavailable and falls back to a local file picker / kiosk-typed check-in.
  Never commit `web/.env.local`. Do not mirror EMR records to the relay: it is a seconds-long
  store-and-forward for one session, not a datastore.
- Default CORS/rate/input limits are env-driven in `server/app/main.py`; keep boundary validation when adding endpoints.

## AI/Voice/X-Ray Gotchas
- Chat streams through `/chat/stream`; Robot Mode consumes SSE and TTS sentence chunks.
- `server/app/main.py` strips chain-of-thought leakage with `_strip_thinking`; preserve this behavior when changing chat paths.
- Vision fallback order is `local -> zen -> gemini -> ollama -> mock`; `gh/gpt-4o-mini` may reject vision, use `gh/gpt-4o` for `LOCAL_VISION_MODEL`.
- Optional Voice Mode needs `server/requirements-voice.txt` plus `kokoro-v0_19.onnx` and `voices.bin` in `server/`.
- Lung sounds run a trained mel-spectrogram CNN when `server/app/lung_model.pt` is present
  (labels `normal`/`crackle`/`wheeze`/`both`, temperature-calibrated), falling back to the
  spectral heuristic in `lung_classifier.py`. Swapping the model needs a coordinated edit across
  `lung_classifier.py` `_LABELS`, `cdss.py` `LUNG_SOUND_FINDINGS`, and the findings tiles in
  `kiosk_lung_sound_screen.dart` — it loads either way and mislabels silently otherwise.
- X-ray uses the local model if present, otherwise the multimodal vision fallback.
- The IR thermometer reads a **fingertip** beside the pulse sensor, not a forehead. Presence is
  detected by the object/ambient differential, not an absolute floor — in a 30 C room a fingertip
  and an empty sensor read the same number.

## Project Conventions
- Read files before editing; prefer small surgical edits.
- Use `apply_patch` for manual edits.
- Do not create docs/tests at repo root; backend tests belong under `server/tests/`, Flutter tests under `test/`.
- Medical UX must keep the disclaimer posture: AI-assisted screening, not diagnosis; recommend licensed clinician/emergency care for severe symptoms.
