# XSIGHT Mobile Pipeline Plan

## Goal

Build a mobile companion app for the **XSIGHT IoT AI Chatbot Robot** that:

- Connects to the robot/IoT backend in real time
- Displays live vitals from sensors
- Hosts the chatbot interface
- Plays/records lung sounds
- Shows AI-assisted risk summary
- Works as the demo-facing patient/admin interface

## Stack Decision: Flutter vs Kotlin vs React Native vs PWA

### Quick Comparison

| Option         | Pros                                                                                  | Cons                                                                       | Best For                                |
| -------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | --------------------------------------- |
| **Flutter**    | One codebase iOS+Android, fast UI, smooth animations, strong charts/audio plugins     | Dart language, larger app size                                             | Capstone demo, polished UI, multi-device |
| **Kotlin**     | Native Android, best hardware/Bluetooth/USB access, fastest performance               | Android only, slower dev, more boilerplate                                 | Deep hardware/BLE integration           |
| **React Native** | JS/TS, easy if web team exists, shares logic with web                               | Bridge perf issues, audio/BLE plugins less consistent                      | Teams already using React               |
| **PWA**        | No install, works on any phone browser, fastest to ship                               | Limited BLE, limited background, weaker native sensors                     | Quickest demo                           |

### Recommendation

**Use Flutter.**

Reasons:
- One codebase for Android + iOS demo
- Strong support for charts (`fl_chart`), audio (`record`, `just_audio`), WebSocket, MQTT, BLE
- Smooth UI for panel demo
- Good performance for live sensor dashboard
- Easier than Kotlin for full app scope

Use **Kotlin only** if:
- Demo is Android-only
- You need deep BLE/USB-OTG access to the robot
- Performance/native sensor APIs are critical

Use **PWA** if:
- You want fastest possible build
- Hardware features are limited to camera/mic/upload
- Already building a Next.js/React dashboard

## Recommended Architecture

```txt
[Robot / IoT Sensors]
        |
   ESP32 / Raspberry Pi
        |
   WiFi (MQTT or WebSocket)
        |
   FastAPI Backend  <----> AI / Chatbot APIs
        |
   REST + WebSocket
        |
   Flutter Mobile App
        |
   Patient / Admin
```

## Mobile App Modules

1. **Auth / Session**
   - Patient session start
   - Optional admin login
2. **Live Vitals Dashboard**
   - Heart rate
   - SpO2
   - Temperature
   - Respiratory rate (if available)
   - Real-time charts
3. **Chatbot Screen**
   - Voice + text input
   - LLM response display
   - TTS playback
4. **Lung Sound Module**
   - Record or upload `.wav`
   - Send to backend
   - Show classification result
5. **Risk Summary Screen**
   - Combined AI assessment
   - Risk level: Low / Moderate / High
   - Recommendation text
6. **Robot Control (Optional)**
   - Start/stop session
   - Trigger TTS message
   - Reconnect device
7. **History (Optional)**
   - Past sessions
   - Stored vitals/results

## Flutter Stack

### Core

- Flutter 3.x stable
- Dart
- Material 3 design

### Suggested Packages

- `provider` or `riverpod` for state management
- `dio` or `http` for REST
- `web_socket_channel` for live data
- `mqtt_client` for MQTT (if used)
- `fl_chart` for vitals charts
- `record` for audio recording
- `just_audio` for audio playback
- `flutter_tts` for text-to-speech
- `speech_to_text` for voice chatbot input
- `permission_handler` for mic/storage
- `image_picker` for optional X-ray upload
- `flutter_secure_storage` for tokens
- `flutter_blue_plus` if connecting robot via BLE
- `cached_network_image` for media
- `intl` for date/time formatting

## Backend Contract

### REST Endpoints (suggested)

- `POST /session/start`
- `POST /session/end`
- `POST /chat` body `{ message }` returns `{ reply }`
- `POST /lung-sound` multipart `.wav` returns `{ label, confidence }`
- `POST /xray` multipart image returns `{ findings }` (optional)
- `GET /summary/{session_id}` returns risk summary
- `POST /vitals` body `{ hr, spo2, temp, rr }` (admin/test)

### WebSocket

- `ws://server/ws/vitals/{session_id}` streams vitals JSON

### MQTT (optional)

- Topic: `xsight/{session_id}/vitals`
- Payload: `{ hr, spo2, temp, rr, ts }`

## Data Model (mobile)

```dart
class Vitals {
  double heartRate;
  double spo2;
  double temperature;
  double? respiratoryRate;
  DateTime timestamp;
}

class ChatMessage {
  String role; // 'user' | 'assistant'
  String content;
  DateTime timestamp;
}

class LungSoundResult {
  String label; // 'normal' | 'wheeze' | 'crackle'
  double confidence;
}

class RiskSummary {
  String level; // 'low' | 'moderate' | 'high'
  String recommendation;
  Vitals vitals;
  LungSoundResult? lungResult;
  String? xrayFindings;
}
```

## Build Pipeline

### Phase 1: Setup
- Install Flutter SDK
- Create project: `flutter create xsight_app`
- Set up folder structure
- Add packages
- Configure Android/iOS permissions

### Phase 2: UI Skeleton
- Splash + onboarding
- Bottom nav: Dashboard / Chat / Sound / Summary
- Theme + Material 3

### Phase 3: API Integration
- REST client
- WebSocket client
- Mock data for offline dev

### Phase 4: Real-Time Vitals
- Connect to backend WebSocket
- Stream into chart widgets
- Add alert thresholds

### Phase 5: Chatbot
- Text input
- Speech-to-text
- API call to backend `/chat`
- TTS playback

### Phase 6: Lung Sound
- Record audio
- Upload to backend
- Show classification result

### Phase 7: Risk Summary
- Pull combined result
- Display risk level + recommendation
- Add medical disclaimer

### Phase 8: Polish
- Loading states
- Error handling
- Offline cache
- Demo mode with sample data

## Recommended Folder Structure

```txt
xsight_app/
  lib/
    main.dart
    app.dart
    core/
      api/
        rest_client.dart
        ws_client.dart
      config/
      theme/
      utils/
    features/
      dashboard/
      chatbot/
      lung_sound/
      summary/
      session/
      history/
    models/
    state/
  assets/
    audio/
    images/
  android/
  ios/
  pubspec.yaml
```

## Permissions

### Android `AndroidManifest.xml`
- `INTERNET`
- `RECORD_AUDIO`
- `ACCESS_NETWORK_STATE`
- `BLUETOOTH_CONNECT` (if BLE)
- `BLUETOOTH_SCAN` (if BLE)
- `READ_MEDIA_IMAGES` (if X-ray upload)

### iOS `Info.plist`
- `NSMicrophoneUsageDescription`
- `NSBluetoothAlwaysUsageDescription` (if BLE)
- `NSPhotoLibraryUsageDescription` (if X-ray upload)
- `NSSpeechRecognitionUsageDescription`

## Demo Flow on Mobile

1. Open app
2. Connect to robot/backend
3. Patient taps **Start Session**
4. Robot greets via TTS
5. Patient interacts with chatbot
6. Live vitals stream into dashboard
7. Patient taps **Record Lung Sound**
8. App uploads `.wav`, gets result
9. Risk summary appears
10. Robot speaks final advice via TTS

## Risk and Disclaimer

Add clear medical disclaimer screen on first launch and on every risk summary:

> XSIGHT is an AI-assisted screening and educational tool. It does not provide a medical diagnosis and should not replace consultation with licensed healthcare professionals.

## Final Recommendation

- **Primary mobile stack: Flutter**
- **Backend: FastAPI** (already aligned with HANDOFF)
- **Realtime: WebSocket**, optional MQTT for IoT
- **Chatbot: OpenAI/Gemini API** through backend (do not call API keys from phone directly)
- **Demo target: Android first**, iOS optional
- Keep app design simple, clinical, and panel-friendly

## Open Decisions

- Android-only or both platforms for capstone demo?
- Will robot expose BLE directly to phone or only through backend?
- Will chatbot stream tokens or return full response?
- Will lung sound be live-recorded on phone or only on robot?
- Will X-ray module be included in mobile MVP?
