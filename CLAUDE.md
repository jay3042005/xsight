# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

XSIGHT — an AI-assisted thoracic-assessment kiosk. Three stacks that ship together but
build and run independently:

| Stack | Path | Entrypoint |
| --- | --- | --- |
| Flutter kiosk app | `lib/` | `lib/main.dart` |
| FastAPI backend | `server/` | `server/main.py` → `server/app/main.py` |
| ESP32 sensor-hub firmware | `firmware/XSIGHT/` | `XSIGHT.ino` (Arduino sketch) |

The app is a tablet kiosk, not a phone app: navigation is driven by physical buttons on the
ESP32 hub over USB serial, and the whole UI is tuned for arm's-length legibility.

**Doc reliability.** `README.md` is the unmodified Flutter stub — ignore it. `HANDOFF.md` and
`MOBILE_PIPELINE.md` predate the kiosk rewrite: still accurate on AI providers and gotchas,
stale on screens and navigation. Current and authoritative: `AGENTS.md` (commands, secrets),
`DESIGN_SYSTEM.md` (tokens), `KIOSK_FEATURES.md` (feature intent), `voice-guide.md` (cue
script), `XRAY_TRAINING.md` / `LUNG_TRAINING.md` (model training + drop-in), `AI_INTEGRATION.md`
(provider setup).

## Commands

### Flutter

```bash
flutter pub get
flutter analyze                                  # keep clean
flutter test                                     # 193 tests, ~6s after build
flutter test test/kiosk_layout_test.dart         # one file
flutter test --plain-name 'radial'               # one test by name substring
flutter build apk --debug
flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8000   # Android emulator
```

Backend URL: `10.0.2.2` for the Android emulator, `localhost` for the iOS simulator, the
laptop's LAN IP for a physical device. It can also be set at runtime in app Settings, which
persists it via `XSSettings` (`shared_preferences`) and overrides the `--dart-define`.

### Backend

```bash
cd server && python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && cp .env.example .env
python main.py            # must run from server/ — it loads server/.env before importing app.main
```

From the repo root, with the existing venv:

```bash
PYTHONPATH=server LOG_LEVEL=ERROR server/.venv/bin/python -m pytest server/tests           # 37 tests
PYTHONPATH=server server/.venv/bin/python -m pytest server/tests/test_api.py::test_health_ok
python3 -m py_compile server/main.py server/app/main.py server/app/vision.py server/app/voice.py
curl http://localhost:8000/health          # active providers + voice loadability
```

`requirements-voice.txt` (faster-whisper + Kokoro) and `requirements-xray.txt` (torch + timm)
are optional; the server starts and degrades without them.

## Architecture

### Everything degrades instead of failing

This is the dominant pattern across both stacks — a demo must never hard-stop:

| Capability | Chain |
| --- | --- |
| Chat | `local` gateway → `zen` → mock reply |
| Vision | `local` → `zen` → `gemini` → `ollama` → mock |
| X-ray | local CNN (`server/ml/xray/xray.onnx` \| `.pt`) → multimodal-LLM prompt in `/xray` |
| Lung sound | `server/app/lung_model.pt` → spectral heuristic in `lung_classifier.py` |
| Vitals | ESP32 serial → simulated demo data (UI shows `LIVE` vs `SIMULATED`) |
| Phone check-in | relay `intake` session → kiosk-typed name → start with no details |
| Voice guide | missing MP3 → that cue stays silent |
| Voice Mode | missing Kokoro/whisper deps → `voice_status()` reports unavailable |

Preserve this when touching any provider path. Fallback selection is env-driven
(`CHAT_PROVIDER`, `VISION_PROVIDER`) and the active choice is printed in the startup banner.

### Flutter app

- `lib/core/theme/` — the design system: `XSColors`, `XSSpacing`, `XSRadius`, `XSShadows`,
  `XSTypography`, `XSTheme`. Monochrome neumorphism (see `DESIGN_SYSTEM.md`); build new UI from
  these tokens and the `lib/ui/components/xs_*.dart` primitives rather than raw Material.
- `XSScale.factor` (`lib/core/theme/xs_scale.dart`) is a **bucketed** multiplier keyed on the
  window's shortest side (1.0 / 1.15 / 1.25 / 1.35). It is applied globally as a `textScaler` in
  `main.dart` *and* used to scale component dimensions. Buckets, not a ramp, so a resize can't
  produce half-pixel type.
- `lib/core/api/` — one thin client per backend concern (`emr_client`, `cdss_client`,
  `vitals_client`, `upload_client`, `risk_client`, `xray_handoff_client`,
  `intake_handoff_client`, `zen_chat_client`).
- `lib/state/` — plain `ChangeNotifier` singletons (`XSSettings.I`, `KioskPatientSession.I`,
  `Esp32SerialClient.shared`). No DI container, no Riverpod/Bloc.
- Startup is a linear stage machine in `main.dart` (`splash → onboarding → disclaimer → app`),
  not `go_router` — `go_router` is a dependency but the kiosk shell does its own navigation.
  Accepting the disclaimer calls `setGuestMode()` and opens the shell directly; there is no
  "who is using this?" fork. `mode_selection_screen.dart` still exists and is still layout-tested,
  but nothing routes to it — `isGuest` is *derived* from whether a record is linked, so the chooser
  only ever made an outcome look like a decision. Staff is an unlock from the guest dashboard's
  `STAFF LOGIN` footer button, through `XSStaffLoginDialog` (PIN pad, no keyboard).

### Hardware-driven kiosk navigation

`KioskShell` (`lib/ui/screens/kiosk_shell.dart`) is a three-phase shell —
`dashboard → menu → screen` — with **no bottom nav bar**. Transitions come from newline-delimited
serial frames parsed in `Esp32SerialClient`: `NAV:<token>`, `MENU_SEL:<token>`, `STATE:<n>`,
`VITALS:`, `TEMP:`, `STETH:`, `PULSE_*`, `XRAY_STATUS:`, `VOICE_OK/UP/DOWN`, `ERR:`. Space/Enter,
arrows, and Escape/Backspace are a keyboard fallback for desktop development.

START on the idle dashboard opens `KioskCheckInScreen` (`kiosk_checkin_screen.dart`) — a
handwritten greeting that parks aside to reveal a QR for phone check-in, plus a kiosk-typed
fallback. It is a pushed **route**, not a fourth phase, because the ESP32 state ordinals are fixed
(0 dashboard, 1 menu, 2+ modules) and pinned by `test/firmware_protocol_test.dart`; as a route the
hub's OK press still arrives as `MENU_READY` and needs no firmware change. Same reason the old
sensor-coaching modal became an in-screen phase (`XSSensorScanPanel`).

Modules are identified by the `XSModule` enum in `lib/ui/screens/kiosk_modules.dart`, never by
menu position: guest mode shows 6 modules and staff 7, so slot *N* is a different module in each.
`MENU_INDEX:<n>` is a legacy path kept only for old firmware and is ignored once a token arrives.
On Android, USB serial goes through the `xsight_usb_serial` platform channel in
`android/app/src/main/kotlin/com/xsight/xsight_app/MainActivity.kt`; desktop uses
`flutter_libserialport`.

### Guest vs staff mode

`KioskPatientSession.I` is the **single source of truth** for patient linkage —
`selectedPatientId` decides whether an upload or CDSS write is attached to an EMR record. Screens
must not keep their own copy (they used to, and uploads silently went out unlinked). Guest mode
serves canned `sample*` datasets from the same class and never writes to the EMR.

### Backend

`server/app/main.py` (~2.4k lines) holds chat/vision/xray/lung/vitals/CDSS plus both WebSockets;
routers are split out and included in it:

| Module | Mount |
| --- | --- |
| `emr_routes.py` | `/emr/*` — patients, vitals, xrays, lung sounds, consultations, notifications, analytics |
| `report_routes.py` | `/reports/{id}/pdf` |
| `handoff.py` | `/handoff/*`, `/ws/handoff/{sid}` |
| `web_dashboard.py` | `/monitor` |

Cross-cutting concerns live in `main.py` as middleware/deps: per-IP rate limiting
(`RATE_LIMIT_RPM` + `RATE_LIMIT_BURST`), CORS (`CORS_ORIGINS`), and size caps
(`MAX_UPLOAD_BYTES`, `MAX_MESSAGE_LENGTH`, `MAX_IMAGE_B64_LENGTH`, …). All env-driven — keep new
endpoints inside these.

`/debug/*` is 403 unless `DEBUG_API_KEY` is set; call with header `X-XSIGHT-Debug-Key`.

EMR is SQLite via `emr_db.py` at `XSIGHT_DB_PATH` (default `xsight_emr.db`, resolved relative to
the process CWD — hence copies in both the repo root and `server/`).

### Phone → kiosk X-ray handoff

`handoff.py` brokers a store-and-pickup relay, not a direct connection: an HTTPS capture page
cannot POST to the kiosk's plain-HTTP LAN address (mixed content), and Vercel functions can't
hold a WebSocket. So the kiosk registers a session, renders a QR, the phone uploads the film to
the relay, and the kiosk polls and collects it over outbound HTTPS, then pushes it down the local
WebSocket the app already holds. Needs `XSIGHT_RELAY_URL` / `XSIGHT_RELAY_KEY`; unset means the
kiosk reports handoff unavailable and falls back to a local file picker.

## Contracts that span files

These have no compiler linking them. Change one side and you must change the others.

1. **Firmware menu tables ↔ `XSModules`.** `test/firmware_protocol_test.dart` parses
   `firmware/XSIGHT/XSIGHT.ino` as text and asserts its `const MenuEntry guest[]` / `staff[]`
   tables and `enum AppState` ordinals agree with `XSModules.navNames` / `espStates`. Editing the
   sketch without running `flutter test` is the likeliest way to break the kiosk — the only
   symptom is the OLED highlighting one station while the screen opens another.
2. **Voice cues ↔ audio assets.** `XSVoiceCue` ids in `lib/core/voice/voice_guide.dart` are the
   MP3 basenames under `assets/voice/en/`, and the ids in `voice-guide.md`.
   `test/voice_guide_test.dart` pins all three. A typo is silent at runtime. Adding a cue = drop
   in an MP3 named after it. `voice-guide.md` scripts a Tagalog set (`assets/voice/tl/`) that is
   not yet recorded or declared in `pubspec.yaml`.
3. **AI card wire names.** Card names appear in the system prompt, in `_KNOWN_CARDS` in
   `server/app/main.py`, and in `XSAiCardType.wire` in `lib/core/ai/xs_ai_card.dart` —
   `xray_compare`, `vitals_table`, `risk_gauge`, `differential`. Cards are *render requests, not
   data*: the model emits `{"card": "vitals_table"}` and the widget fills every measured value
   from `KioskPatientSession`, so a card structurally cannot show a reading no sensor produced.
   `differential` is the one card whose content is model-authored, and it is labelled as such.
4. **Lung label set.** Swapping in a trained `lung_model.pt` requires a coordinated edit across
   `lung_classifier.py` `_LABELS`, `cdss.py` `LUNG_SOUND_FINDINGS`, and the findings tiles in
   `kiosk_lung_sound_screen.dart` — the model loads either way and mislabels silently otherwise.
   See `LUNG_TRAINING.md` §1 and §6.
5. **Chat post-processing order.** In `/chat` and `/chat/stream`, `_extract_cards` must run
   **before** `_strip_thinking` — the latter keeps only the last non-empty paragraph and would
   otherwise discard the prose or the card depending on emission order. `_strip_thinking` exists
   because open models leak chain-of-thought; keep it on any new chat path.

6. **Timed reading windows ↔ the guided scan screens.** The pulse and temperature stations
   finish their own readings: the sketch starts a clock on the first *complete* reading
   (`PULSE_SCAN_MS` 20s, `TEMP_SCAN_MS` 5s) and emits the final `VITALS:`/`TEMP:` then
   `PULSE_DONE:1`/`TEMP_DONE:1` itself — SELECT is inert mid-measurement. `KioskVitalsScreen` and
   `KioskTempScreen` *wait* for that DONE rather than deciding for themselves, so if the windows are
   removed or the old "SELECT finalises it" branch comes back, the kiosk sits on a countdown that
   never resolves. Pinned by the `timed reading windows` group in
   `test/firmware_protocol_test.dart`. Also load-bearing: `VITALS:` is published only when **both**
   HR and SpO₂ resolve in one window — a partial frame would start the countdown against half a
   measurement, and `bpmValue` persists between windows so the other half could be seconds stale.
7. **Phone-intake field set.** The form fields in `web/public/intake.html`, the `normalise()`
   allowlist in `web/api/session/[sid]/intake.js`, and `KioskPatientSession.applyIntakeDetails`
   must agree — currently `name`, `age`, `sex`, `symptoms`. `normalise()` drops unknown keys and
   `applyIntakeDetails` ignores them, so a field added on one side alone is silently discarded with
   no error anywhere. The relay is the trust boundary: it is where lengths, ranges and control
   characters are bounded, and everything downstream assumes that has already happened.

Model drop-in is copy-a-file, no code change: `server/ml/xray/{xray.pt|xray.onnx,labels.json,metrics.json}`
and `server/app/lung_model.pt`. `metrics.json` also carries the `temperature` used for
confidence calibration. Architecture is pinned to `efficientnet_b0` (`XRAY_ARCH` overrides).

## Conventions

- Read before editing; prefer small surgical edits. Keep files under 500 lines — several kiosk
  screens already exceed it, so extract rather than extend them.
- New Flutter tests go in `test/`, backend tests in `server/tests/`. Nothing at the repo root.
- Layout regressions are caught by `test/kiosk_layout_test.dart`, which mounts each screen at
  landscape 1280x800, portrait 800x1280, and small-tablet 1024x768. Add new screens to it.
- Widget tests run without `flutter_soloud`'s native library; `VoiceGuide` already logs and
  disables itself. Keep new plugin use similarly test-tolerant.
- Never commit `server/.env`, API keys, relay tokens, or real patient data. The gitignored
  `xsight_emr.db` files are development data.
- Medical posture is a product requirement, not boilerplate: AI-assisted screening, never a
  diagnosis; recommend a licensed clinician; route severe symptoms (chest pain, severe
  breathlessness, blue lips, confusion, fainting) to emergency care. Enforced in
  `XSConfig.systemPrompt` and the disclaimer screen — preserve it in any prompt or result copy.
  Never send identifiable patient data through free/training-tier model endpoints.
- Voice cue classes gate what the kiosk says aloud: `result` and `coach` cues are guest-only, so
  the speaker never announces a named patient's findings in a shared room. Respect `XSCueClass`
  when adding cues.

## Known gotchas

- `assets/voice/en/temp_place.mp3` still says "hold the sensor near your forehead". The IR
  sensor reads a **fingertip** beside the pulse sensor — the UI copy, the OLED art and the
  `voice-guide.md` script all say so, but the recording does not. Re-record it.
- The temperature station's fever thresholds are still core/forehead-calibrated (37.5 / 38.2 in
  `kiosk_temp_screen.dart` and `kiosk_patient_state.dart`, 37.8 / 39.0 in `cdss.py`). A
  fingertip runs several degrees below core, so a real fever reads ~33–34 °C there and is
  classified NORMAL — a false negative. Either relabel the station as skin temperature and drop
  the fever classification, or calibrate against a reference thermometer. Do not guess numbers.
- `flutter_soloud` 3.5+: use `format: BufferType.s16le`, not `pcmFormat: BufferPcmType.s16le`.
- `record` is pinned to `^6.1.1` — 5.x breaks the Linux build.
- `gh/gpt-4o-mini` rejects images on the local gateway; use `gh/gpt-4o` for `LOCAL_VISION_MODEL`.
- `speech_to_text` deprecations (`listenFor`, `pauseFor`, `partialResults`, `cancelOnError`,
  `listenMode`) should move to `SpeechListenOptions`; warnings only today.
- Voice Mode needs `requirements-voice.txt` plus `kokoro-v0_19.onnx` and `voices.bin` in `server/`.
