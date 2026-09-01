/*
  ===========================================================================
  XSIGHT - Thoracic Pre-Diagnosis Device
  ESP32 + 2.42" 128x64 I2C OLED + MAX30102 + GY-906 (MLX90614) + MAX9814
  ===========================================================================

  HARDWARE MAP
  -------------------------------------------------------------------------
  OLED (SSD1306 128x64)   : I2C  -> SDA 21 / SCL 22 (ESP32 default)
  MAX30102 (Heart/SpO2)   : I2C  -> SDA 21 / SCL 22 (addr 0x57)
  GY-906 / MLX90614 (Temp): I2C  -> SDA 21 / SCL 22 (addr 0x5A)
  MAX9814 (Mic Amp OUT)   : GPIO 34 (analog in, input only pin)
  TEMPLED                 : GPIO 18
  PULSELED                : GPIO 5
  BTN_UP                  : GPIO 33
  BTN_DOWN                : GPIO 25
  BTN_SELECT              : GPIO 26
  BTN_BACK                : GPIO 27
  (All buttons wired to GND, using internal pull-ups -> active LOW)

  This table is the wiring contract and must stay in sync with the #defines
  below - it previously listed TEMPLED on 19 and PULSELED on 18 while the code
  drove 18 and 5, so anyone wiring from the comment got two dead LEDs.

  BUTTON ROLES (kept consistent across the whole app)
  -------------------------------------------------------------------------
  BTN_UP     -> Move selection up / scroll up
  BTN_DOWN   -> Move selection down / scroll down
  BTN_SELECT -> Confirm / Enter / Start reading / Read again (after done)
  BTN_BACK   -> Cancel / Go back to menu / Return home

  LIBRARIES REQUIRED (Library Manager)
  -------------------------------------------------------------------------
  - Adafruit GFX Library
  - Adafruit SSD1306
  - SparkFun MAX3010x Pulse and Proximity Sensor Library
    (provides MAX30105.h AND spo2_algorithm.h - spo2_algorithm.h ships in the
    library's src folder; if your IDE doesn't find it, copy spo2_algorithm.h/.cpp
    from the library folder into this sketch's folder)
  - Adafruit MLX90614 Library

  TRANSPORTS
  -------------------------------------------------------------------------
  USB CDC (Serial) 115200 baud + Bluetooth Classic SPP ("XSIGHT").
  Both carry the identical newline-delimited ASCII protocol described below.
  The Flutter app (Esp32SerialClient) tries USB first, then falls back to a
  bonded XSIGHT* Bluetooth device with auto-reconnect every 2 s.  Firmware
  mirrors every outbound line to whichever transport(s) have a client, and
  accepts inbound commands from either.  Boards without Classic BT compile as
  USB-only (XS_HAS_BT==0).

  SERIAL PROTOCOL (for companion software integration)
  -------------------------------------------------------------------------
  115200 baud, newline-delimited ASCII. Every message the sketch can emit is
  listed here; the companion app's parser keys off these exact prefixes, so
  adding a message means adding it to this block too.

  Device -> Software:
    READY:1                 once at boot
    LINK:1                  heartbeat, every 2s, so an app that connects late
                            still discovers the device
    PONG                    answer to PING
    STATUS:<state>,<steth>,<vitals>,<temp>,<xray>
    MENU:READY              user left the intro screen for the menu
    CONSENT_SEL:<ACCEPT|DECLINE>
                            highlight moved on the consent prompt, so the kiosk
                            screen can mirror it
    CONSENT:<ACCEPT|DECLINE>
                            the consent prompt was answered with SELECT (or
                            declined with BACK)
    NAV:<dest>              HOME | MENU | XRAY | SOUNDS | VITALS | TEMP |
                            SUMMARY | ASSIST | SETTINGS
    XRAY_STATUS:0/1
    STETH_BIN:<int16>       binary frame: 0xA5, 0x5A, sample LE; 2 kHz PCM
    STETH_START:1
    STETH_DONE:1
    VITALS:<bpm>,<spo2>     only once BOTH values resolve in one window
    PULSE_WAITING:1         no finger detected yet, or contact lost
    PULSE_ACTIVE:1
    PULSE_DONE:1            sent by the module itself after PULSE_SCAN_MS of
                            complete readings - no SELECT press required
    PULSE_CANCELLED:1
    TEMP:<celsius>
    TEMP_ACTIVE:1
    TEMP_DONE:1             sent by the module itself after TEMP_SCAN_MS of
                            in-range readings - no SELECT press required
    VOICE_DOWN / VOICE_UP   push-to-talk edges from BTN_SELECT in ASSIST
    MODE_ACK:GUEST/STAFF
    STAFF_ACK:<name>
    PATIENT_ACK:<name>
    MENU_SEL:<token>        highlight moved to a station, named by identity
    MENU_INDEX:<n>          legacy positional form of the same event
    MENU_SELECT:<token>     station launched from the module's OK button
    SESSION_ACK:1           readings cleared
    ERR:<SENSOR|TEMP>       sensor missing or reading out of range

  Software -> Device:
    PING
    STATUS
    READ_VITALS
    START_STETH
    STOP_STETH
    START_TEMP
    STOP_TEMP
    STOP_VITALS
    MODE:GUEST
    MODE:STAFF
    STAFF:<name>
    PATIENT:<name>
    XRAY_UPLOADED:1         software confirms an x-ray file was uploaded
    XRAY_UPLOADED:0         reset
    NEW_SESSION             clear all readings for the next patient
    STATE:9                 put up the consent prompt for a portal-pushed record;
                            pair it with PATIENT:<name> so the prompt names the
                            subject. STATE:0 takes it back down.
    STATE:<n>               drive the OLED to a screen (see AppState); lets the
                            OLED follow touch navigation instead of drifting
    NAV:<dest>              same destinations as the outbound NAV:
    MENU_SEL:<token>        move the OLED highlight to a station by identity
    MENU_INDEX:<n>          legacy: highlight by position in the active menu

  STATE numbering is shared by both sides: 0 intro, 1 menu, 2 xray, 3 steth,
  4 pulse, 5 temp, 6 summary, 7 assist, 8 settings.

  MENU IDENTITY, NOT POSITION
  ---------------------------
  Guest and staff have different menus — different order, and staff have one
  extra entry (SETTINGS) — so a bare index does not name the same station on
  both ends. Worse, an index still in flight while a sign-out is processed gets
  read against the wrong table and highlights an unrelated module.

  Highlights and selections therefore travel as tokens (MENU_SEL:VITALS,
  MENU_SELECT:VITALS) drawn from the same vocabulary as NAV:. A token means one
  station forever, so either side can reorder or filter its menu freely.
  MENU_INDEX: is still emitted and accepted, but only so an app build predating
  MENU_SEL: keeps working across one firmware flash. Do not add new positional
  messages.

  WHAT THIS DISPLAY SHOWS
  -----------------------
  Idle is the XSIGHT mark plus a one-line session footer; the menu appears only
  on OK. Of the stations, only the three sensor ones render their own content —
  that is where the user is looking down at the module with a finger on it. An
  x-ray image, a conversation and a settings form cannot be represented in
  128x64, so those defer to the kiosk screen and name whatever hardware control
  still applies (see drawDeferredToScreen). The readings summary stays because
  station-completion is data this module owns; the risk assessment built from it
  is not, and the footer says so.

  Inbound STATE:/NAV:/MENU_SEL:/MENU_INDEX: are echo-suppressed: acting on them
  does not emit the matching outbound message, otherwise the two sides would
  ping-pong navigation forever.
  ===========================================================================
*/

#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <MAX30105.h>
#include "spo2_algorithm.h"   // from SparkFun MAX3010x library (batch HR+SpO2 algorithm)
#include <Adafruit_MLX90614.h>
#include <Update.h>

// ---------------------------------------------------------------------------
// FIRMWARE VERSION + OVER-SERIAL OTA
// ---------------------------------------------------------------------------
// Bump FW_VERSION whenever the sketch changes in a way the kiosk should
// push to already-deployed hubs. The kiosk asks "FW?" once at startup,
// compares against the server's expectation, and offers to flash a newer
// .bin over this same serial link (see the OTA_* commands below) — so a
// firmware update needs no USB cable swap, no bootloader button, no IDE.
#define FW_VERSION "2026.09.1"

// One OTA chunk is 256 bytes as hex (512 chars + framing) — small enough for
// the line reader's String growth and the BT SPP path, big enough that a
// 1.2 MB sketch finishes in a couple of minutes at 115200 baud.
#define OTA_CHUNK_BYTES 256

bool     otaActive = false;
uint32_t otaNextSeq = 0;
uint8_t  otaChunk[OTA_CHUNK_BYTES];

// fwCrc32 / fwHexVal / fwDecodeHex live further down, next to handleCommand:
// defining them here would hoist the Arduino auto-prototypes above the enum
// and struct definitions this file opens with, which breaks the build.


// ---------------------------------------------------------------------------
// BLUETOOTH DUAL TRANSPORT  (USB Serial + Classic SPP)
// ---------------------------------------------------------------------------
// When the ESP32 was built with Bluedroid enabled this sketch advertises as
// "XSIGHT" over Bluetooth Classic SPP *in addition* to USB CDC.  Every outbound
// line / binary frame is mirrored to both transports so a tablet with no OTG
// cable can test the whole protocol over Bluetooth, and a kiosk with USB still
// works when BT is off.  Inbound commands are accepted from either transport.
// Auto-connection is entirely on the Flutter side: it tries USB first, then
// falls back to a bonded/pairable "XSIGHT*" device and retries every 2 s
// (see lib/core/sensor/esp32_serial_client.dart).  The firmware itself just
// needs to advertise and accept — no pairing logic here.
//
// Boards without Classic BT (S2/C3/S3 without CONFIG_BT) compile cleanly:
// the helpers degrade to USB-only via the XS_HAS_BT gate.
// ---------------------------------------------------------------------------
#if defined(CONFIG_BT_ENABLED) && defined(CONFIG_BLUEDROID_ENABLED)
  #include <BluetoothSerial.h>
  BluetoothSerial SerialBT;
  #define XS_HAS_BT 1
#else
  #define XS_HAS_BT 0
#endif
#define BT_NAME "XSIGHT"
#define BT_NAME_ALT "XSIGHT-THORACIC"

// PIN DEFINITIONS
// ---------------------------------------------------------------------------
#define BTN_UP        33
#define BTN_DOWN      25
#define BTN_SELECT    26
#define BTN_BACK      27

#define PIN_MIC       34   // MAX9814 OUT (analog input only pin on ESP32)
#define PIN_TEMPLED   18
#define PIN_PULSELED  5   // GPIO5 (hardware map above must match wiring)

#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64
#define OLED_RESET    -1
#define OLED_ADDR     0x3C

// ---------------------------------------------------------------------------
// GLOBAL OBJECTS
// ---------------------------------------------------------------------------
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
MAX30105 maxSensor;
Adafruit_MLX90614 mlx = Adafruit_MLX90614();

// ---------------------------------------------------------------------------
// APP STATE MACHINE
// ---------------------------------------------------------------------------
enum AppState {
  STATE_INTRO,
  STATE_MENU,
  STATE_XRAY,
  STATE_STETH,
  STATE_PULSE,
  STATE_TEMP,
  STATE_SUMMARY,
  STATE_ASSIST,
  STATE_SETTINGS,
  // Appended, never inserted: 0-8 are pinned by test/firmware_protocol_test.dart
  // against XSModules.espStates, so putting a new screen in the middle would
  // renumber every station and the OLED would follow the app to the wrong one.
  STATE_CONSENT
};
AppState currentState = STATE_INTRO;

// Sub-states for each function
enum SubState { SUB_IDLE, SUB_WAITING, SUB_ACTIVE, SUB_DONE };
SubState xraySub  = SUB_WAITING;
SubState stethSub = SUB_IDLE;
SubState pulseSub = SUB_IDLE;
SubState tempSub  = SUB_IDLE;

// Highlighted option on the consent screen: 0 = accept, 1 = decline.
//
// Starts on accept because that is the common answer, but the buttons must be
// able to reach decline: a modal the hub cannot answer strands anyone who will
// not touch the kiosk screen, which is most of the people this station serves.
int consentIndex = 0;

// Mode (synced from Flutter app)
enum AppMode { MODE_GUEST, MODE_STAFF };
AppMode currentMode = MODE_GUEST;

// ---------------------------------------------------------------------------
// MENU
// ---------------------------------------------------------------------------
// One entry per reachable station. `navToken` is the identity that goes on the
// wire and must match XSModules.navNames in lib/ui/screens/kiosk_modules.dart.
//
// Everything positional about the old protocol was removed on purpose. The menu
// is now a different length in each mode (staff gains SETTINGS), so a bare
// index no longer means the same station on both ends — and a `MENU_INDEX:6`
// still in flight while the app processes a sign-out would be read against the
// wrong table and highlight the wrong module. Highlights therefore travel as
// `MENU_SEL:<token>` in both directions; `MENU_INDEX:` is still emitted, but
// only as a courtesy to an older app build.
//
// `showsOnOled` marks the stations this 128x64 display can genuinely render:
// the three sensor stations, where the user is looking down at the module with
// a finger on it. The rest are kiosk-screen work (an image, a report, a
// conversation, a settings form) and get the deferral screen instead of a
// pretend one.
struct MenuEntry {
  const char* label;
  const char* navToken;
  AppState    state;
  bool        showsOnOled;
};

// Forward declarations for types and functions used by the menu helpers below.
//
// The Arduino preprocessor inserts its auto-generated prototypes immediately
// before the *first function definition* in the sketch. The menu helpers are now
// that first definition, so those prototypes land above `struct Button` and
// `goToState` — and `void pollButton(Button&)` would not compile. Declaring both
// here keeps the tables at the top of the file where they are readable, without
// caring where the preprocessor chooses to splice.
struct Button;
void goToState(AppState s);

// Guest order follows the guest dashboard's journey rail (pulse -> temp ->
// lungs -> x-ray) so a station sits in the same position on both displays.
// Labels are plain language: a walk-up user is not reading "DIGITAL
// STETHOSCOPE".
const MenuEntry MENU_GUEST[] = {
  { "HEART RATE & SPO2",  "VITALS",  STATE_PULSE,   true  },
  { "TEMPERATURE",        "TEMP",    STATE_TEMP,    true  },
  { "LUNG SOUNDS",        "SOUNDS",  STATE_STETH,   true  },
  { "CHEST X-RAY",        "XRAY",    STATE_XRAY,    false },
  { "YOUR RESULTS",       "SUMMARY", STATE_SUMMARY, true  },
  { "ASK THE ASSISTANT",  "ASSIST",  STATE_ASSIST,  false },
};

// Staff order follows the clinical workflow, matching XSModules.staff, and adds
// SETTINGS — which the OLED previously had no way to reach even though the
// protocol already carried NAV:SETTINGS and STATE:8.
const MenuEntry MENU_STAFF[] = {
  { "UPLOAD XRAY",         "XRAY",     STATE_XRAY,     false },
  { "DIGITAL STETHOSCOPE", "SOUNDS",   STATE_STETH,    true  },
  { "HEART RATE AND SPO2", "VITALS",   STATE_PULSE,    true  },
  { "TEMPERATURE",         "TEMP",     STATE_TEMP,     true  },
  { "READINGS SUMMARY",    "SUMMARY",  STATE_SUMMARY,  true  },
  { "AI ASSISTANT",        "ASSIST",   STATE_ASSIST,   false },
  { "SETTINGS",            "SETTINGS", STATE_SETTINGS, false },
};

const int MENU_GUEST_COUNT = sizeof(MENU_GUEST) / sizeof(MENU_GUEST[0]);
const int MENU_STAFF_COUNT = sizeof(MENU_STAFF) / sizeof(MENU_STAFF[0]);

int menuIndex = 0;

const MenuEntry* activeMenu() {
  return currentMode == MODE_STAFF ? MENU_STAFF : MENU_GUEST;
}

int activeMenuCount() {
  return currentMode == MODE_STAFF ? MENU_STAFF_COUNT : MENU_GUEST_COUNT;
}

// Position of a station in the *current* mode's menu, or -1 when this mode
// cannot reach it. Every translation goes through here so no caller has to know
// a literal position.
int menuIndexOfToken(const String &token) {
  const MenuEntry* menu = activeMenu();
  for (int i = 0; i < activeMenuCount(); i++) {
    if (token == menu[i].navToken) return i;
  }
  return -1;
}

int menuIndexOfState(AppState s) {
  const MenuEntry* menu = activeMenu();
  for (int i = 0; i < activeMenuCount(); i++) {
    if (menu[i].state == s) return i;
  }
  return -1;
}

// True when this display can render the station's own content rather than
// deferring to the kiosk screen.
bool stateShowsOnOled(AppState s) {
  int i = menuIndexOfState(s);
  return i >= 0 ? activeMenu()[i].showsOnOled : false;
}

const char* labelForState(AppState s) {
  int i = menuIndexOfState(s);
  return i >= 0 ? activeMenu()[i].label : "XSIGHT";
}

// Announce the highlighted station. Sends the identity first — that is what the
// app acts on — and the index after, purely so an app build predating
// MENU_SEL: keeps working through one firmware flash.
void reportMenuHighlight() {
  if (menuIndex < 0 || menuIndex >= activeMenuCount()) return;
  xsPrint("MENU_SEL:");
  xsPrintln(activeMenu()[menuIndex].navToken);
  xsPrint("MENU_INDEX:");
  xsPrintln(menuIndex);
}

// ---------------------------------------------------------------------------
// SESSION IDENTITY (synced from the app)
// ---------------------------------------------------------------------------
// Held rather than only acked. The app sends STAFF: and PATIENT: on every mode
// change; the previous version echoed them straight back and kept nothing, so
// the module could not say whose session it was in — which is the main thing a
// kiosk display is for once it is more than a menu.
String staffName   = "";
String patientName = "";

// Switch mode, keeping the highlight on the same station where possible.
//
// The menus differ in both order and length, so a raw index carried across the
// switch points at an unrelated station — or past the end of the guest menu,
// which is one item shorter. Resolving through the station's identity keeps the
// highlight meaningful, and falls back to the top when this mode cannot reach
// the previously-focused station (signing out of Settings, for instance).
void setMode(AppMode m) {
  if (m == currentMode) return;
  AppState focused = STATE_INTRO;
  int before = menuIndex;
  if (before >= 0 && before < activeMenuCount()) {
    focused = activeMenu()[before].state;
  }

  currentMode = m;

  int next = menuIndexOfState(focused);
  menuIndex = next >= 0 ? next : 0;

  // A station the new mode cannot reach must not stay on display: signing out
  // while Settings is open would otherwise leave the backend configuration
  // screen up for whoever walks in next. The app enforces this too — this is
  // the module refusing on its own account, not instead of the app.
  if (currentState != STATE_INTRO && currentState != STATE_MENU &&
      menuIndexOfState(currentState) < 0) {
    goToState(STATE_INTRO);
  }
}

// ---------------------------------------------------------------------------
// READING DATA (shared with companion software)
// ---------------------------------------------------------------------------
bool  xrayUploaded   = false;   // fetched by / set from software
int   stethValue     = 0;       // raw mic amplitude sent to software
bool  stethDone      = false;

long  bpmValue        = 0;
long  spo2Value        = 0;
bool  vitalsDone      = false;

float tempValue       = 0.0;
bool  tempDone        = false;

// ---------------------------------------------------------------------------
// SENSOR PRESENCE
// ---------------------------------------------------------------------------
// Probed once in setup(). Without this, a missing MAX30102 makes getIR()
// return 0 forever, which is indistinguishable from "no finger yet" - the
// pulse screen would sit in SUB_WAITING for eternity with no explanation.
bool  pulseSensorOk   = false;
bool  tempSensorOk    = false;

// The IR thermometer reads a FINGERTIP, mounted beside the pulse sensor - not a
// forehead. That changes how presence is detected, not just the wording.
//
// An absolute floor cannot do it. Fingertip skin sits around 30-34 C indoors, and
// in a room at 30 C an empty sensor reads the same number, so the old 30.0 C floor
// would have passed a sensor aimed at the wall and rejected a cool finger. What
// separates them is that skin is *warmer than the air around it*, and the
// MLX90614 reports its own ambient channel alongside the object reading.
//
// The absolute window stays as a gross sanity check only: it rejects a reading off
// a cold surface or a hot lamp, and is deliberately wide enough not to throw away
// a chilled fingertip in air conditioning.
const float TEMP_MIN_VALID_C = 20.0;
const float TEMP_MAX_VALID_C = 45.0;

// How far above ambient a reading must sit to count as skin on the sensor.
//
// Kept low on purpose. The MLX90614's "ambient" is its own die, which warms in use
// and closes the gap the longer the station runs, so a tight threshold would start
// rejecting real fingertips after a few minutes. Raise it if an empty sensor is
// getting through; lower it if real readings are being refused.
const float TEMP_MIN_OVER_AMBIENT_C = 1.0;
bool  tempValid       = false;

// ---------------------------------------------------------------------------
// BUTTON DEBOUNCE
// ---------------------------------------------------------------------------
// Each button is sampled exactly once per loop() pass by pollButton(), which
// records both edges into the struct. Reading an edge is then a pure lookup.
//
// This split matters: the previous version computed the edge inside both
// wasPressed() and wasReleased(), and both mutated the same debounce fields.
// Calling them back-to-back on one button - which loop() does for SELECT, to
// drive push-to-talk - meant the first call consumed the release edge and the
// second could never observe it, so VOICE_UP was never sent and push-to-talk
// latched on. Sampling once and publishing both edges removes the coupling.
struct Button {
  uint8_t pin;
  bool lastReading;
  bool stableState;
  unsigned long lastChange;
  bool pressedEdge;
  bool releasedEdge;
};
Button btnUp     = {BTN_UP,     HIGH, HIGH, 0, false, false};
Button btnDown   = {BTN_DOWN,   HIGH, HIGH, 0, false, false};
Button btnSelect = {BTN_SELECT, HIGH, HIGH, 0, false, false};
Button btnBack   = {BTN_BACK,   HIGH, HIGH, 0, false, false};
const unsigned long DEBOUNCE_MS = 40;

// Samples one button and latches this pass's edges. Call once per loop() pass.
void pollButton(Button &b) {
  b.pressedEdge = false;
  b.releasedEdge = false;

  bool reading = digitalRead(b.pin);
  if (reading != b.lastReading) {
    b.lastChange = millis();
    b.lastReading = reading;
  }

  if ((millis() - b.lastChange) > DEBOUNCE_MS && reading != b.stableState) {
    b.stableState = reading;
    // Active LOW: pressed on HIGH->LOW, released on LOW->HIGH.
    if (b.stableState == LOW) {
      b.pressedEdge = true;
    } else {
      b.releasedEdge = true;
    }
  }
}

// Pure reads of the edges latched by pollButton() - safe to call repeatedly.
bool wasPressed(const Button &b)  { return b.pressedEdge; }
bool wasReleased(const Button &b) { return b.releasedEdge; }

// Helpers that mirror every write to USB Serial *and* to BT when a client is
// connected.  Overloads cover every call-site type used in this sketch so a
// plain search-replace of Serial.print -> xsPrint is sufficient.
inline void xsPrint(const char* v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(const String& v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(char v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(int v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(unsigned int v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(long v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(unsigned long v) {
  Serial.print(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v);
#endif
}
inline void xsPrint(float v, int d=2) {
  Serial.print(v,d);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v,d);
#endif
}
inline void xsPrint(double v, int d=2) {
  Serial.print(v,d);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.print(v,d);
#endif
}

inline void xsPrintln(const char* v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(const String& v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(char v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(int v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(unsigned int v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(long v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(unsigned long v) {
  Serial.println(v);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v);
#endif
}
inline void xsPrintln(float v, int d=2) {
  Serial.println(v,d);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v,d);
#endif
}
inline void xsPrintln(double v, int d=2) {
  Serial.println(v,d);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println(v,d);
#endif
}
inline void xsPrintln() {
  Serial.println();
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.println();
#endif
}

inline void xsWrite(uint8_t b) {
  Serial.write(b);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.write(b);
#endif
}
inline void xsWrite(const uint8_t* b, size_t n){
  Serial.write(b,n);
#if XS_HAS_BT
  if (SerialBT.hasClient()) SerialBT.write(b,n);
#endif
}

// Forward for handleStream
void handleCommand(const String &line);
inline void handleStream(Stream &s){
  while(s.available()){
    String line = s.readStringUntil('\n');
    line.trim();
    if(line.length()==0) continue;
    handleCommand(line);
  }
}

// ---------------------------------------------------------------------------



// ---------------------------------------------------------------------------
// PULSE / SPO2 SENSOR VARIABLES (HEMOSYNC-style batch algorithm)
// ---------------------------------------------------------------------------
#define PULSE_BUFFER_SIZE 100
uint32_t irBuffer[PULSE_BUFFER_SIZE];
uint32_t redBuffer[PULSE_BUFFER_SIZE];
int32_t  spo2Raw, heartRateRaw;
int8_t   validSPO2, validHeartRate;
int      pulseBufferFillIndex = 0; // how many samples collected in the current pass

// ---------------------------------------------------------------------------
// DIGITAL STETHOSCOPE - ADC SAMPLING + BANDPASS FILTER (20 Hz - 800 Hz)
// ---------------------------------------------------------------------------
// Sampled and streamed at 2 kHz (Nyquist covers heart sounds ~20-200Hz and
// lung sounds ~100-1000Hz). Each compact four-byte frame needs 80 kbps at
// 8N1, below the 115200-baud serial link capacity.
const int STETH_SAMPLE_RATE_HZ = 2000;
const unsigned long STETH_SAMPLE_INTERVAL_US = 1000000UL / STETH_SAMPLE_RATE_HZ;

float hp_alpha, lp_alpha;          // single-pole IIR coefficients (computed in setup)
float hp_prev_in = 0, hp_prev_out = 0;
float lp_prev_out = 0;
unsigned long lastStethSampleTime = 0; // micros() - drives the 2kHz cadence

// ---------------------------------------------------------------------------
// TIMERS
// ---------------------------------------------------------------------------
unsigned long lastDrawTime = 0;
unsigned long stateEnterTime = 0;
unsigned long lastLinkHeartbeat = 0;
unsigned long lastAnimFrame = 0;
// Throttles live temperature streaming. The MLX90614 settles in ~100ms, so
// anything faster just fills the link with duplicate values.
unsigned long lastTempSend = 0;
const unsigned long TEMP_SEND_INTERVAL_MS = 200;

// ---------------------------------------------------------------------------
// TIMED READING WINDOWS
// ---------------------------------------------------------------------------
// Both sensor stations finish their own reading. They used to wait for a SELECT
// press to lock one in, which asked a walk-in to know that OK means "keep this"
// while still holding a finger on the sensor - and the press finalised with
// whatever values happened to be in hand, including a heart rate with no SpO2
// behind it.
//
// The clock starts on the first *complete* reading, not on arming, so the window
// measures how long a good reading was held rather than how long the user spent
// finding the sensor. Losing contact resets it to zero: a reading spliced across
// a break in contact is two readings, and averaging them would hide that.
//
// 20s on pulse covers several of the batch algorithm's 100-sample windows. 5s on
// temperature is shorter on purpose - the MLX90614 settles in about 100ms, so its
// window exists to prove the aim was held, not to accumulate samples.
const unsigned long PULSE_SCAN_MS = 20000;
const unsigned long TEMP_SCAN_MS  = 5000;
unsigned long pulseScanStartMs = 0;   // 0 = no complete reading yet
unsigned long tempScanStartMs  = 0;
int animFrame = 0;

// ===========================================================================
// SETUP
// ===========================================================================
void setup() {
  Serial.begin(115200);
#if XS_HAS_BT
  SerialBT.begin(BT_NAME);
  SerialBT.setTimeout(20);
  // Alt name helps tablets that cached an old advertisement
  // (some stacks show the first name they saw forever).
#endif
  // readStringUntil() otherwise blocks for the default 1000ms whenever a
  // command arrives without its terminating newline. On this sketch that
  // stalls the draw loop and the 2kHz stethoscope sampler for a full second.
  Serial.setTimeout(20);
#if XS_HAS_BT
  SerialBT.setTimeout(20);
#endif

  pinMode(BTN_UP, INPUT_PULLUP);
  pinMode(BTN_DOWN, INPUT_PULLUP);
  pinMode(BTN_SELECT, INPUT_PULLUP);
  pinMode(BTN_BACK, INPUT_PULLUP);

  pinMode(PIN_TEMPLED, OUTPUT);
  pinMode(PIN_PULSELED, OUTPUT);
  digitalWrite(PIN_TEMPLED, LOW);
  digitalWrite(PIN_PULSELED, LOW);

  pinMode(PIN_MIC, INPUT);
  analogReadResolution(12);        // 0-4095
  analogSetAttenuation(ADC_11db);  // full 0-3.3V range

  // Precompute stethoscope bandpass filter coefficients
  {
    float dt = 1.0 / STETH_SAMPLE_RATE_HZ;

    float hp_cutoff = 20.0; // Hz - removes DC drift / motion artifacts
    float hp_rc = 1.0 / (2 * PI * hp_cutoff);
    hp_alpha = hp_rc / (hp_rc + dt);

    float lp_cutoff = 800.0; // Hz - removes hiss above lung-sound range
    float lp_rc = 1.0 / (2 * PI * lp_cutoff);
    lp_alpha = dt / (lp_rc + dt);
  }

  Wire.begin(); // SDA 21, SCL 22 on ESP32

  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    // If OLED fails, blink pulse LED forever as an error signal
    while (true) {
      digitalWrite(PIN_PULSELED, !digitalRead(PIN_PULSELED));
      delay(200);
    }
  }
  display.clearDisplay();
  display.display();

  if (!maxSensor.begin(Wire, I2C_SPEED_FAST)) {
    pulseSensorOk = false;
    xsPrintln("ERR:SENSOR");
  } else {
    pulseSensorOk = true;
    maxSensor.setup();
    maxSensor.setPulseAmplitudeRed(0x1F);
    maxSensor.setPulseAmplitudeIR(0x1F);
    maxSensor.setPulseAmplitudeGreen(0);
  }

  // MLX90614's begin() reports whether the device answered on the bus; the
  // previous code discarded it, so a disconnected thermometer silently
  // reported whatever readObjectTempC() returned on failure.
  tempSensorOk = mlx.begin();
  if (!tempSensorOk) xsPrintln("ERR:SENSOR");

  currentState = STATE_INTRO;
  stateEnterTime = millis();
  xsPrintln("READY:1");
}

// ===========================================================================
// MAIN LOOP
// ===========================================================================
void loop() {
  handleSerialInput();

  // Keep the companion app aware of the device even when it connects after
  // the one-time READY:1 startup message.
  if (millis() - lastLinkHeartbeat > 2000) {
    xsPrintln("LINK:1");
    lastLinkHeartbeat = millis();
  }

  // Sample every button exactly once per pass, then read the latched edges.
  pollButton(btnUp);
  pollButton(btnDown);
  pollButton(btnSelect);
  pollButton(btnBack);

  bool up             = wasPressed(btnUp);
  bool down           = wasPressed(btnDown);
  bool select         = wasPressed(btnSelect);
  bool selectReleased = wasReleased(btnSelect);
  bool back           = wasPressed(btnBack);

  switch (currentState) {
    case STATE_INTRO:   handleIntro(select, back);                    break;
    case STATE_MENU:    handleMenu(up, down, select, back);           break;
    case STATE_XRAY:    handleXray(select, back);                     break;
    case STATE_STETH:   handleSteth(select, back);                    break;
    case STATE_PULSE:   handlePulse(select, back);                    break;
    case STATE_TEMP:    handleTemp(select, back);                     break;
    case STATE_SUMMARY: handleSummary(back);                          break;
    case STATE_ASSIST:  handleAssist(select, selectReleased, back);   break;
    case STATE_SETTINGS: handleSettings(back);                        break;
    case STATE_CONSENT: handleConsent(up, down, select, back);         break;
  }

  // Redraw at ~20fps max (pulse/steth screens redraw faster internally if needed)
  if (millis() - lastDrawTime > 50) {
    drawCurrentScreen();
    lastDrawTime = millis();
  }
}

// ===========================================================================
// SERIAL INPUT FROM COMPANION SOFTWARE
// ===========================================================================
void handleSerialInput() {
  handleStream(Serial);
#if XS_HAS_BT
  handleStream(SerialBT);
#endif
}

// Everything after the first ':' - avoids the magic substring offsets the
// previous version used (substring(14) for "XRAY_UPLOADED:" and friends),
// which silently truncate if a command is ever renamed.
String argOf(const String &line) {
  int sep = line.indexOf(':');
  if (sep < 0) return String("");
  String arg = line.substring(sep + 1);
  arg.trim();
  return arg;
}

// Clears every reading. Called when the app links a different patient, so one
// person's vitals can never appear under the next person's name.
void resetSession() {
  xrayUploaded = false;
  xraySub      = SUB_WAITING;

  stethValue = 0;
  stethDone  = false;
  stethSub   = SUB_IDLE;

  bpmValue   = 0;
  spo2Value  = 0;
  vitalsDone = false;
  pulseSub   = SUB_IDLE;
  pulseBufferFillIndex = 0;
  pulseScanStartMs = 0;

  tempValue = 0.0;
  tempDone  = false;
  tempValid = false;
  tempSub   = SUB_IDLE;
  tempScanStartMs = 0;

  digitalWrite(PIN_PULSELED, LOW);
  digitalWrite(PIN_TEMPLED, LOW);
}

// Drives the OLED to the screen the app is showing. Deliberately silent: the
// app already knows where it navigated, and echoing NAV:/STATE: back would be
// parsed as a fresh user action and bounced straight here again.
void applyAppState(AppState s) {
  if (s == currentState) return;
  // Leaving a measurement screen must also stop that measurement, or the
  // stethoscope keeps streaming and the LEDs stay lit behind the app's back.
  if (currentState == STATE_STETH && s != STATE_STETH && stethSub == SUB_ACTIVE) {
    stethSub = SUB_DONE;
    stethDone = true;
    // Informational, not a navigation echo: the app needs to know the stream
    // ended so it can close out the recording it was buffering.
    xsPrintln("STETH_DONE:1");
  }
  if (currentState == STATE_PULSE && s != STATE_PULSE) {
    if (pulseSub == SUB_WAITING) pulseSub = SUB_IDLE;
    pulseBufferFillIndex = 0;
    pulseScanStartMs = 0;
    digitalWrite(PIN_PULSELED, LOW);
  }
  if (currentState == STATE_TEMP && s != STATE_TEMP) {
    if (tempSub == SUB_ACTIVE) tempSub = SUB_IDLE;
    tempScanStartMs = 0;
    digitalWrite(PIN_TEMPLED, LOW);
  }
  goToState(s);
}

// Maps an inbound STATE:<n> to a screen. Numbering is shared with the app;
// see the protocol block at the top. Anything out of range (the app's own
// Settings screen is 8) leaves the OLED where it is rather than blanking it.
bool applyStateNumber(int n) {
  switch (n) {
    case 0: applyAppState(STATE_INTRO);    return true;
    case 1: applyAppState(STATE_MENU);     return true;
    case 2: applyAppState(STATE_XRAY);     return true;
    case 3: applyAppState(STATE_STETH);    return true;
    case 4: applyAppState(STATE_PULSE);    return true;
    case 5: applyAppState(STATE_TEMP);     return true;
    case 6: applyAppState(STATE_SUMMARY);  return true;
    case 7: applyAppState(STATE_ASSIST);   return true;
    // 8 is the app's Settings screen. The OLED can follow it now that staff
    // have a menu entry for it; it renders as a deferral, since a settings form
    // is not something 128x64 pixels can show.
    case 8: applyAppState(STATE_SETTINGS); return true;
    // 9 is the app's consent prompt. Entering it resets the highlight so a
    // second prompt does not open on whatever the last one left selected.
    case 9:
      if (currentState != STATE_CONSENT) consentIndex = 0;
      applyAppState(STATE_CONSENT);
      return true;
    default: return false;
  }
}

// Maps an inbound NAV:<dest> to a screen, and keeps the menu highlight on the
// matching item so returning to the menu lands where the app was.
//
// The highlight is resolved through the active menu rather than assigned a
// literal position: the two modes order their menus differently and staff have
// one extra entry, so a hardcoded index would point at an unrelated station in
// the other mode.
bool applyNavDest(const String &dest) {
  if (dest == "HOME") { applyAppState(STATE_INTRO); return true; }
  if (dest == "MENU") { applyAppState(STATE_MENU);  return true; }

  int i = menuIndexOfToken(dest);
  if (i < 0) return false;   // not reachable in this mode — leave the OLED alone
  menuIndex = i;
  applyAppState(activeMenu()[i].state);
  return true;
}

// Reads the thermometer and reports whether the value is a plausible body
// temperature. Keeps the range check in one place so the OLED, the summary,
// and the serial stream can never disagree about validity.
bool readBodyTemp(float &out) {
  if (!tempSensorOk) return false;
  float object = mlx.readObjectTempC();
  if (isnan(object) || object < TEMP_MIN_VALID_C || object > TEMP_MAX_VALID_C) {
    return false;
  }
  // Presence check, and the one that actually does the work: skin on the sensor
  // reads warmer than the air in front of it. Skipped rather than failed when the
  // ambient channel itself returns NaN - a broken second channel should not take
  // the station down when the object reading is still good.
  float ambient = mlx.readAmbientTempC();
  if (!isnan(ambient) && (object - ambient) < TEMP_MIN_OVER_AMBIENT_C) {
    return false;
  }
  out = object;
  return true;
}

// Table-free CRC32 (reflected, poly 0xEDB88320) — matches zlib/python
// binascii.crc32, so the kiosk can verify chunks with any standard impl.
uint32_t fwCrc32(const uint8_t *data, size_t len) {
  uint32_t crc = 0xFFFFFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (uint8_t k = 0; k < 8; k++)
      crc = (crc >> 1) ^ (0xEDB88320 & (-(int32_t)(crc & 1)));
  }
  return ~crc;
}

int fwHexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Decodes hex into otaChunk; returns byte count or -1 on a bad digit.
int fwDecodeHex(const String &hex) {
  if (hex.length() & 1) return -1;
  size_t n = hex.length() / 2;
  if (n > OTA_CHUNK_BYTES) return -1;
  for (size_t i = 0; i < n; i++) {
    int hi = fwHexVal(hex[(unsigned)i * 2]);
    int lo = fwHexVal(hex[(unsigned)i * 2 + 1]);
    if (hi < 0 || lo < 0) return -1;
    otaChunk[i] = (uint8_t)((hi << 4) | lo);
  }
  return (int)n;
}

void handleCommand(const String &line) {
  // ─── Link / status ──────────────────────────────────────────────
  if (line == "PING") {
    xsPrintln("PONG");

  } else if (line == "FW?") {
    xsPrint("FW_VER:");
    xsPrintln(FW_VERSION);

  } else if (line == "STATUS") {
    xsPrint("STATUS:");
    xsPrint(currentState);
    xsPrint(",");
    xsPrint(stethSub);
    xsPrint(",");
    xsPrint(vitalsDone ? 1 : 0);
    xsPrint(",");
    xsPrint(tempDone ? 1 : 0);
    xsPrint(",");
    xsPrintln(xrayUploaded ? 1 : 0);

  // ─── Measurements ───────────────────────────────────────────────
  } else if (line == "READ_VITALS") {
    if (!pulseSensorOk) {
      xsPrintln("ERR:SENSOR");
      return;
    }
    applyAppState(STATE_PULSE);
    pulseSub = SUB_WAITING;
    pulseBufferFillIndex = 0;
    pulseScanStartMs = 0;
    vitalsDone = false;
    bpmValue = 0;
    spo2Value = 0;
    digitalWrite(PIN_PULSELED, HIGH);
    xsPrintln("PULSE_WAITING:1");

  } else if (line == "STOP_VITALS") {
    pulseSub = SUB_IDLE;
    pulseBufferFillIndex = 0;
    pulseScanStartMs = 0;
    bpmValue = 0;
    spo2Value = 0;
    vitalsDone = false;
    digitalWrite(PIN_PULSELED, LOW);
    // No NAV:HOME here. The app is the one cancelling, and echoing a
    // navigation back at it used to yank its own UI to the dashboard.
    applyAppState(STATE_INTRO);
    xsPrintln("PULSE_CANCELLED:1");

  } else if (line == "START_STETH") {
    applyAppState(STATE_STETH);
    stethSub = SUB_ACTIVE;
    stethDone = false;
    resetStethFilter();
    xsPrintln("STETH_START:1");

  } else if (line == "STOP_STETH") {
    if (stethSub == SUB_ACTIVE) {
      stethSub = SUB_DONE;
      stethDone = true;
      xsPrintln("STETH_DONE:1");
    }

  } else if (line == "START_TEMP") {
    if (!tempSensorOk) {
      xsPrintln("ERR:SENSOR");
      return;
    }
    applyAppState(STATE_TEMP);
    tempSub = SUB_ACTIVE;
    tempDone = false;
    tempScanStartMs = 0;
    digitalWrite(PIN_TEMPLED, HIGH);
    // Announce the state first and let the sampling loop publish readings, so
    // the app sees the same TEMP_ACTIVE handshake it gets from the hardware
    // button. The old version skipped it and pushed one raw TEMP: instead.
    xsPrintln("TEMP_ACTIVE:1");

  } else if (line == "STOP_TEMP") {
    tempSub = SUB_IDLE;
    tempValue = 0.0;
    tempValid = false;
    tempDone = false;
    tempScanStartMs = 0;
    digitalWrite(PIN_TEMPLED, LOW);

  // ─── Over-serial firmware update ────────────────────────────────
  // The kiosk streams the .bin the server serves, in CRC-checked hex
  // chunks with per-chunk acknowledgement, then reboots the hub into the
  // new firmware. Runs over USB *or* the BT SPP link — whichever stream
  // delivered the OTA_BEGIN is the one answers go back on, same as every
  // other command (the xsPrint mirror handles that).
  } else if (line.startsWith("OTA_BEGIN:")) {
    if (otaActive) { xsPrintln("OTA_ERR:BUSY"); return; }
    size_t size = strtoul(line.c_str() + 10, nullptr, 10);
    if (size == 0) { xsPrintln("OTA_ERR:SIZE"); return; }
    if (!Update.begin(size)) {
      xsPrint("OTA_ERR:BEGIN:");
      xsPrintln(Update.errorString());
      return;
    }
    otaActive = true;
    otaNextSeq = 0;
    xsPrint("OTA_READY:");          // tells the kiosk the max chunk size
    xsPrintln(OTA_CHUNK_BYTES);

  } else if (line.startsWith("OTA:")) {
    // OTA:<seq>:<crc32-hex>:<hex-data>
    if (!otaActive) { xsPrintln("OTA_ERR:NOT_STARTED"); return; }
    int c1 = line.indexOf(':', 4);
    int c2 = line.indexOf(':', c1 + 1);
    if (c1 < 0 || c2 < 0) { xsPrintln("OTA_ERR:FRAME"); return; }
    uint32_t seq = strtoul(line.substring(4, c1).c_str(), nullptr, 10);
    uint32_t crc = strtoul(line.substring(c1 + 1, c2).c_str(), nullptr, 16);
    int n = fwDecodeHex(line.substring(c2 + 1));
    if (n < 0) { xsPrintln("OTA_ERR:HEX"); return; }
    if (seq != otaNextSeq) { xsPrint("OTA_NAK:"); xsPrintln((unsigned long)seq); return; }
    if (fwCrc32(otaChunk, n) != crc) { xsPrint("OTA_NAK:"); xsPrintln((unsigned long)seq); return; }
    if (Update.write(otaChunk, n) != (size_t)n) {
      otaActive = false;
      Update.end(false);
      xsPrint("OTA_ERR:WRITE:");
      xsPrintln(Update.errorString());
      return;
    }
    otaNextSeq++;
    xsPrint("OTA_ACK:");            // only after the chunk is on flash
    xsPrintln((unsigned long)seq);

  } else if (line == "OTA_END") {
    if (!otaActive) { xsPrintln("OTA_ERR:NOT_STARTED"); return; }
    if (!Update.end(true)) {
      otaActive = false;
      xsPrint("OTA_ERR:END:");
      xsPrintln(Update.errorString());
      return;
    }
    xsPrintln("OTA_OK");
    otaActive = false;
    delay(250);                      // let the ack leave the UART
    ESP.restart();

  } else if (line == "OTA_ABORT") {
    if (otaActive) {
      Update.end(false);
      otaActive = false;
    }
    xsPrintln("OTA_ABORTED");

  // ─── Session / identity ─────────────────────────────────────────
  } else if (line == "NEW_SESSION") {
    resetSession();
    applyAppState(STATE_INTRO);
    xsPrintln("SESSION_ACK:1");

  } else if (line == "MODE:GUEST") {
    setMode(MODE_GUEST);
    // Handing the kiosk back to the public: the previous session's identity
    // must not stay on the display.
    staffName = "";
    patientName = "";
    xsPrintln("MODE_ACK:GUEST");

  } else if (line == "MODE:STAFF") {
    setMode(MODE_STAFF);
    xsPrintln("MODE_ACK:STAFF");

  } else if (line.startsWith("STAFF:")) {
    staffName = argOf(line);
    xsPrint("STAFF_ACK:");
    xsPrintln(staffName);

  } else if (line.startsWith("PATIENT:")) {
    patientName = argOf(line);
    xsPrint("PATIENT_ACK:");
    xsPrintln(patientName);

  } else if (line.startsWith("XRAY_UPLOADED:")) {
    xrayUploaded = (argOf(line) == "1");
    xraySub = xrayUploaded ? SUB_DONE : SUB_WAITING;

  // ─── OLED follows the app's navigation ──────────────────────────
  } else if (line.startsWith("STATE:")) {
    applyStateNumber(argOf(line).toInt());

  } else if (line.startsWith("NAV:")) {
    applyNavDest(argOf(line));

  } else if (line.startsWith("MENU_SEL:")) {
    // Preferred inbound highlight: an identity, so it stays correct whichever
    // mode each side currently believes it is in.
    int i = menuIndexOfToken(argOf(line));
    if (i >= 0) menuIndex = i;

  } else if (line.startsWith("MENU_INDEX:")) {
    // Legacy positional form, kept so an older app build still drives the
    // highlight. Clamped against the *active* menu, which is shorter in guest
    // mode — an unclamped index used to be able to point past the end.
    int idx = argOf(line).toInt();
    if (idx >= 0 && idx < activeMenuCount()) menuIndex = idx;
  }
}

// ===========================================================================
// STATE: INTRO
// ===========================================================================
void handleIntro(bool select, bool back) {
  // Only SELECT advances to menu. OLED stays on XSIGHT logo until user presses OK.
  (void)back;
  if (select) {
    xsPrintln("MENU:READY");
    goToState(STATE_MENU);
  }
}

// ===========================================================================
// STATE: CONSENT
// ===========================================================================
// The kiosk is asking whether to adopt a patient record pushed from the web
// portal. The app puts this screen up with STATE:9 and names the subject with
// PATIENT:<name>; UP/DOWN move the highlight and SELECT answers.
//
// The highlight is mirrored back as CONSENT_SEL: so the kiosk screen and this
// display never disagree about which option is about to be confirmed — the whole
// point of driving it from here.
void handleConsent(bool up, bool down, bool select, bool back) {
  if (up || down) {
    consentIndex = consentIndex == 0 ? 1 : 0;
    xsPrint("CONSENT_SEL:");
    xsPrintln(consentIndex == 0 ? "ACCEPT" : "DECLINE");
  }

  if (select) {
    xsPrint("CONSENT:");
    xsPrintln(consentIndex == 0 ? "ACCEPT" : "DECLINE");
    // Back to the idle screen either way. The app drives the next screen: on an
    // accept it sends STATE:1 for the menu, and it stays on the intro otherwise.
    consentIndex = 0;
    goToState(STATE_INTRO);
    return;
  }

  // BACK is a decline rather than a dismissal. Leaving the prompt up with no
  // answer would hold the portal waiting on a session nobody is going to start.
  if (back) {
    xsPrintln("CONSENT:DECLINE");
    consentIndex = 0;
    goToState(STATE_INTRO);
  }
}

// ===========================================================================
// STATE: MENU
// ===========================================================================
void handleMenu(bool up, bool down, bool select, bool back) {
  const int count = activeMenuCount();
  if (count == 0) return;

  if (up || down) {
    menuIndex = (menuIndex + (down ? 1 : -1) + count) % count;
    reportMenuHighlight();
  }

  if (select) {
    const MenuEntry &item = activeMenu()[menuIndex];
    // Identity, not position: the app resolves the token through
    // XSModules.forNav, so this cannot select the wrong station even if the
    // menus are reordered or a mode change is still in flight.
    xsPrint("MENU_SELECT:");
    xsPrintln(item.navToken);
    xsPrint("NAV:");
    xsPrintln(item.navToken);
    goToState(item.state);
  }
  if (back) {
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
  }
}

// ===========================================================================
// STATE: UPLOAD XRAY
// ===========================================================================
// The upload itself happens in the companion app; this screen only mirrors it.
// SELECT used to fake a successful upload for bench testing, which meant a
// press on the kiosk could make the OLED and the summary claim a radiograph
// existed when none had been sent. On a triage device that is a false record,
// so SELECT now only clears a completed upload.
void handleXray(bool select, bool back) {
  if (back) { xsPrintln("NAV:HOME"); goToState(STATE_INTRO); return; }

  if (select && xraySub == SUB_DONE) {
    xrayUploaded = false;
    xraySub = SUB_WAITING;
    xsPrintln("XRAY_STATUS:0");
  }
}

// ===========================================================================
// STATE: DIGITAL STETHOSCOPE
// ===========================================================================
// Clears the IIR history so a previous recording's tail cannot bleed into the
// start of the next one.
void resetStethFilter() {
  hp_prev_in = 0;
  hp_prev_out = 0;
  lp_prev_out = 0;
  lastStethSampleTime = micros();
}

void handleSteth(bool select, bool back) {
  if (back) {
    stethSub = SUB_IDLE;
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
    return;
  }

  if (select) {
    if (stethSub == SUB_IDLE || stethSub == SUB_DONE) {
      // START / READ AGAIN
      stethSub = SUB_ACTIVE;
      stethDone = false;
      resetStethFilter();
      xsPrintln("STETH_START:1");
    } else if (stethSub == SUB_ACTIVE) {
      // STOP
      stethSub = SUB_DONE;
      stethDone = true;
      xsPrintln("STETH_DONE:1");
    }
  }

  if (stethSub == SUB_ACTIVE) {
    updateSteth();
  }
}

// ---------------------------------------------------------------------------
// STETHOSCOPE SAMPLING (20-800 Hz bandpass, 2 kHz internal sample rate)
// ---------------------------------------------------------------------------
void updateSteth() {
  unsigned long nowUs = micros();
  if (nowUs - lastStethSampleTime < STETH_SAMPLE_INTERVAL_US) return;
  lastStethSampleTime = nowUs;

  int raw = analogRead(PIN_MIC); // 0-4095

  // High-pass ~20 Hz: removes DC drift / very slow motion artifacts
  float hp_out = hp_alpha * (hp_prev_out + raw - hp_prev_in);
  hp_prev_in = raw;
  hp_prev_out = hp_out;

  // Low-pass ~800 Hz: removes high-frequency hiss/noise above lung sound range
  float lp_out = lp_prev_out + lp_alpha * (hp_out - lp_prev_out);
  lp_prev_out = lp_out;

  stethValue = (int)lp_out;

  // Binary framing preserves all samples for WAV generation. Text STETH:
  // frames at 50 Hz discard the lung-sound spectrum before classification.
  int16_t sample = (int16_t)constrain(stethValue, -32768, 32767);
  xsWrite(0xA5);
  xsWrite(0x5A);
  xsWrite((uint8_t)(sample & 0xFF));
  xsWrite((uint8_t)((sample >> 8) & 0xFF));
}

// ===========================================================================
// STATE: HEART RATE / SPO2
// ===========================================================================
void handlePulse(bool select, bool back) {
  if (back) {
    pulseSub = SUB_IDLE;
    pulseBufferFillIndex = 0;
    pulseScanStartMs = 0;
    bpmValue = 0;
    spo2Value = 0;
    vitalsDone = false;
    digitalWrite(PIN_PULSELED, LOW);
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
    return;
  }

  if (select) {
    if (pulseSub == SUB_IDLE || pulseSub == SUB_DONE) {
      // START / READ AGAIN. Refuse rather than sit in SUB_WAITING forever when
      // the sensor never answered on the I2C bus - with no finger check to
      // fail, that state is indistinguishable from "still waiting".
      if (!pulseSensorOk) {
        xsPrintln("ERR:SENSOR");
        return;
      }
      pulseSub = SUB_WAITING; // waiting for finger
      pulseBufferFillIndex = 0;
      pulseScanStartMs = 0;
      vitalsDone = false;
      bpmValue = 0;
      spo2Value = 0;
      digitalWrite(PIN_PULSELED, HIGH);
    }
    // Mid-reading, SELECT is deliberately inert. It used to finalise on the spot
    // with the best-known values, which is how a heart rate with no SpO2 behind
    // it - or one measured before the finger settled - got locked in and written
    // to a record. The window finishes the reading; BACK abandons it.
  }

  if (pulseSub == SUB_WAITING || pulseSub == SUB_ACTIVE) {
    runPulseMeasurement();
  }
}

// ---------------------------------------------------------------------------
// PULSE / SPO2 MEASUREMENT (ported from HEMOSYNC.ino)
// ---------------------------------------------------------------------------
// Fills a 100-sample IR+RED buffer, then runs the reference
// maxim_heart_rate_and_oxygen_saturation() algorithm on it - same approach
// HEMOSYNC uses. Unlike the original version, this only pulls whatever
// samples are ALREADY available each call instead of blocking until the
// full buffer fills - since handlePulse() is called every loop() pass,
// this keeps SELECT/BACK responsive immediately, even mid-measurement.
void runPulseMeasurement() {
  if (!pulseSensorOk) return;

  // Cheap single-sample check before starting a fresh pass, so we don't
  // sit in SUB_ACTIVE with no finger on the sensor.
  if (pulseBufferFillIndex == 0) {
    long quickIR = maxSensor.getIR();
    if (quickIR < 50000) {
      if (pulseSub != SUB_WAITING) xsPrintln("PULSE_WAITING:1");
      pulseSub = SUB_WAITING;
      pulseScanStartMs = 0;
      return;
    }
    if (pulseSub != SUB_ACTIVE) xsPrintln("PULSE_ACTIVE:1");
    pulseSub = SUB_ACTIVE;
  }

  // Pull in whatever samples the sensor already has ready - non-blocking.
  maxSensor.check();
  while (pulseBufferFillIndex < PULSE_BUFFER_SIZE && maxSensor.available()) {
    redBuffer[pulseBufferFillIndex] = maxSensor.getRed();
    irBuffer[pulseBufferFillIndex]  = maxSensor.getIR();
    maxSensor.nextSample();
    pulseBufferFillIndex++;
  }

  if (pulseBufferFillIndex < PULSE_BUFFER_SIZE) return; // not full yet - finish next loop() pass

  // Buffer full - re-check for finger before trusting it, then compute.
  long avgIR = 0;
  for (int i = 0; i < PULSE_BUFFER_SIZE; i++) avgIR += irBuffer[i];
  avgIR /= PULSE_BUFFER_SIZE;
  pulseBufferFillIndex = 0; // reset for the next pass either way

  if (avgIR < 50000) {
    // Announce it, not just record it. The kiosk's countdown is driven off these
    // frames, so a silent revert here left it running against a window this side
    // had already thrown away.
    if (pulseSub != SUB_WAITING) xsPrintln("PULSE_WAITING:1");
    pulseSub = SUB_WAITING;
    pulseScanStartMs = 0;
    return;
  }

  maxim_heart_rate_and_oxygen_saturation(
    irBuffer, PULSE_BUFFER_SIZE, redBuffer,
    &spo2Raw, &validSPO2, &heartRateRaw, &validHeartRate);

  // Both, or nothing. A window where only one of the two resolved is not a
  // vitals reading: publishing it let the kiosk start its countdown against a
  // heart rate with no SpO2 behind it, and the window could run out before an
  // SpO2 ever appeared. The stale-value hazard was worse - `bpmValue` persisted
  // between windows, so a fresh SpO2 could be published beside a heart rate
  // measured seconds earlier and nothing downstream could tell.
  if (!validHeartRate || !validSPO2) return;

  bpmValue  = heartRateRaw;
  spo2Value = spo2Raw;

  // The first complete reading starts the window.
  if (pulseScanStartMs == 0) pulseScanStartMs = millis();

  // Publish every completed window so the kiosk's live values track the sensor.
  xsPrint("VITALS:");
  xsPrint(bpmValue);
  xsPrint(",");
  xsPrintln(spo2Value);

  // Then finish it ourselves. The values above are already on the wire, so the
  // app has the final reading before it sees DONE.
  if (millis() - pulseScanStartMs >= PULSE_SCAN_MS) {
    pulseSub = SUB_DONE;
    vitalsDone = true;
    pulseScanStartMs = 0;
    digitalWrite(PIN_PULSELED, LOW);
    xsPrintln("PULSE_DONE:1");
  }
}

// ===========================================================================
// STATE: TEMPERATURE
// ===========================================================================
void handleTemp(bool select, bool back) {
  if (back) {
    tempSub = SUB_IDLE;
    tempValue = 0.0;
    tempValid = false;
    tempDone = false;
    tempScanStartMs = 0;
    digitalWrite(PIN_TEMPLED, LOW);
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
    return;
  }

  if (select) {
    if (tempSub == SUB_IDLE || tempSub == SUB_DONE) {
      // START / READ AGAIN
      if (!tempSensorOk) {
        xsPrintln("ERR:SENSOR");
        return;
      }
      tempSub = SUB_ACTIVE;
      tempDone = false;
      tempValid = false;
      tempScanStartMs = 0;
      digitalWrite(PIN_TEMPLED, HIGH);
      xsPrintln("TEMP_ACTIVE:1");
    }
    // Mid-reading, SELECT is inert - the window locks the reading in. The old
    // STOP branch is what made "press OK while holding your fingertip on the
    // sensor" a step in the flow, and it reported ERR:TEMP when the press happened
    // to land on a sample the presence check rejected.
  }

  if (tempSub == SUB_ACTIVE) {
    // Stream live readings while the user aims the sensor, so the app's
    // thermometer guide tracks the real value instead of guessing.
    float c;
    if (readBodyTemp(c)) {
      tempValue = c;
      tempValid = true;
      // The first in-range reading starts the window. `readBodyTemp` is the only
      // range check in the sketch, so anything that gets here is already a
      // plausible body temperature rather than a reading off the room.
      if (tempScanStartMs == 0) tempScanStartMs = millis();
      if (millis() - lastTempSend > TEMP_SEND_INTERVAL_MS) {
        xsPrint("TEMP:");
        xsPrintln(tempValue, 2);
        lastTempSend = millis();
      }
      if (millis() - tempScanStartMs >= TEMP_SCAN_MS) {
        tempSub = SUB_DONE;
        tempDone = true;
        tempScanStartMs = 0;
        digitalWrite(PIN_TEMPLED, LOW);
        xsPrint("TEMP:");
        xsPrintln(tempValue, 2);
        xsPrintln("TEMP_DONE:1");
      }
    } else {
      // Aim lost. Restart the window rather than carrying the elapsed time
      // across the gap - the point of the window is that the aim was *held*.
      tempValid = false;
      tempScanStartMs = 0;
    }
  }
}

// ===========================================================================
// STATE: READINGS SUMMARY
// ===========================================================================
void handleSummary(bool back) {
  if (back) {
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
  }
}

// ===========================================================================
// STATE: SETTINGS (staff only)
// ===========================================================================
// BACK is the only control. The form itself lives on the kiosk screen, and OK
// is deliberately inert here: there is nothing on this display to confirm, and
// a button that appears to do something to a configuration screen it cannot
// show would be worse than one that does nothing.
void handleSettings(bool back) {
  if (back) {
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
  }
}

// ===========================================================================
// STATE: AI ASSISTANT
// ===========================================================================
void handleAssist(bool select, bool selectReleased, bool back) {
  if (back) {
    xsPrintln("NAV:HOME");
    goToState(STATE_INTRO);
    return;
  }
  if (select) {
    xsPrintln("VOICE_DOWN");
  }
  if (selectReleased) {
    xsPrintln("VOICE_UP");
  }
}

// ===========================================================================
// STATE TRANSITION HELPER
// ===========================================================================
void goToState(AppState s) {
  currentState = s;
  stateEnterTime = millis();
}

// ===========================================================================
// DRAWING
// ===========================================================================
// Draws `text` centered (both axes) inside the rectangle (bx,by,bw,bh),
// accounting for the font's actual glyph bounding box (x1/y1 offsets) so
// text never sits flush against - or overlaps - the box border.
void drawCentered(const char* text, int bx, int by, int bw, int bh, uint8_t textSize) {
  display.setTextSize(textSize);
  int16_t x1, y1; uint16_t w, h;
  display.getTextBounds(text, 0, 0, &x1, &y1, &w, &h);
  int16_t cx = bx + (bw - (int)w) / 2 - x1;
  int16_t cy = by + (bh - (int)h) / 2 - y1;
  display.setCursor(cx, cy);
  display.print(text);
}

void drawHeader(const char* title) {
  display.drawRect(0, 0, 128, 16, SSD1306_WHITE);
  display.setTextColor(SSD1306_WHITE);
  drawCentered(title, 0, 0, 128, 16, 2);
}

void drawSubHeader(const char* sub) {
  display.drawRect(0, 16, 128, 12, SSD1306_WHITE);
  drawCentered(sub, 0, 16, 128, 12, 1);
}

void drawBox(const char* line1) {
  display.drawRect(0, 28, 128, 36, SSD1306_WHITE);
  drawCentered(line1, 0, 28, 128, 36, 1);
}

// Draws a big value (size2) + a caption (size1) centered within the column
// [xStart,xEnd), keeping everything clear of the column's own borders.
void drawStatColumn(int xStart, int xEnd, long value, const char* caption) {
  char buf[8];
  sprintf(buf, "%ld", value);
  drawCentered(buf, xStart, 30, xEnd - xStart, 20, 2);
  drawCentered(caption, xStart, 50, xEnd - xStart, 14, 1);
}

// Draws a simple two-lobe lung icon (white fill, dark bronchi lines)
// centered at (cx, cy) - used on the boot/intro screen.
void drawLungIcon(int cx, int cy) {
  const int lobeW = 18, lobeH = 24, gap = 6;
  int leftX  = cx - gap / 2 - lobeW;
  int rightX = cx + gap / 2;
  int topY   = cy - lobeH / 2;

  // Lobes
  display.fillRoundRect(leftX,  topY, lobeW, lobeH, 6, SSD1306_WHITE);
  display.fillRoundRect(rightX, topY, lobeW, lobeH, 6, SSD1306_WHITE);

  // Trachea (trunk above the split)
  display.fillRect(cx - 2, topY - 8, 4, 9, SSD1306_WHITE);

  // Bronchi branching from the trachea into each lobe
  display.drawLine(cx, topY, leftX + lobeW - 4, topY + 4, SSD1306_WHITE);
  display.drawLine(cx, topY, rightX + 4, topY + 4, SSD1306_WHITE);

  // Branch detail inside each lobe, drawn in black so it reads as
  // vein/bronchi lines against the white fill
  display.drawLine(leftX + lobeW - 4, topY + 4, leftX + 4, topY + lobeH - 6, SSD1306_BLACK);
  display.drawLine(leftX + lobeW - 4, topY + 4, leftX + 8, topY + 10, SSD1306_BLACK);
  display.drawLine(rightX + 4, topY + 4, rightX + lobeW - 4, topY + lobeH - 6, SSD1306_BLACK);
  display.drawLine(rightX + 4, topY + 4, rightX + lobeW - 8, topY + 10, SSD1306_BLACK);
}

// ---------------------------------------------------------------------------
// ANIMATED SENSOR GUIDES (finger approaching the sensor, bottom to top)
// ---------------------------------------------------------------------------
// Sensor disc with pulsing rings and a finger arriving from below.
//
// Shared by both sensor stations. The MLX90614 is mounted beside the MAX30102 and
// reads the same fingertip, so the gesture this display teaches has to be
// identical at both: temperature used to draw a forehead silhouette with a
// thermometer flying at it, which coached an action the hardware cannot perform.
//
// `frameCount` is the caller's cycle length, so each station keeps its own cadence
// without a second copy of the geometry.
void drawSensorFingerArt(int frame, int frameCount) {
  if (frameCount < 4) frameCount = 4;   // keeps the divisions below meaningful
  const int sensorX = 64;
  const int sensorY = 22;
  const int sensorR = 12;

  // Pulsing rings around the sensor.
  for (int i = 0; i < 3; i++) {
    int ringPhase = (frame + i * (frameCount / 3)) % frameCount;
    int ringR = sensorR + (ringPhase * 20 / frameCount);
    if (ringR > 0 && ringR < 30) {
      display.drawCircle(sensorX, sensorY, ringR, SSD1306_WHITE);
    }
  }

  // Sensor disc, hollowed, with its LED dot.
  display.fillCircle(sensorX, sensorY, sensorR, SSD1306_WHITE);
  display.fillCircle(sensorX, sensorY, sensorR - 3, SSD1306_BLACK);
  display.fillCircle(sensorX, sensorY, 2, SSD1306_WHITE);

  // The finger rises for three quarters of the cycle, then rests on the sensor -
  // the rest is the part being taught, so it gets its own beat.
  const int moveFrames = frameCount * 3 / 4;
  const int holdFrames = frameCount - moveFrames;
  int fingerY;
  if (frame < moveFrames) {
    fingerY = 58 - (frame * 24 / moveFrames);
  } else {
    fingerY = 34 + ((frame - moveFrames) * 2 / (holdFrames > 0 ? holdFrames : 1));
  }
  const int fingerX = 64;

  display.fillRect(fingerX - 6, fingerY - 12, 12, 20, SSD1306_WHITE);   // body
  display.fillCircle(fingerX, fingerY - 12, 6, SSD1306_WHITE);          // tip
  display.fillRect(fingerX - 3, fingerY - 16, 6, 4, SSD1306_BLACK);     // nail
}

// Bottom-left session mode. Clear of the finger, which runs up the centre column.
void drawModeFooter() {
  display.setTextSize(1);
  display.setCursor(2, 55);
  display.print(currentMode == MODE_GUEST ? "GUEST" : "STAFF");
}

void drawAnimatedFingerGuide() {
  if (millis() - lastAnimFrame > 80) {
    animFrame = (animFrame + 1) % 40;
    lastAnimFrame = millis();
  }
  display.drawRect(0, 0, 128, 64, SSD1306_WHITE);
  drawSensorFingerArt(animFrame, 40);
  drawModeFooter();
}

void drawAnimatedTempGuide() {
  if (millis() - lastAnimFrame > 100) {
    animFrame = (animFrame + 1) % 30;
    lastAnimFrame = millis();
  }
  display.drawRect(0, 0, 128, 64, SSD1306_WHITE);
  drawSensorFingerArt(animFrame, 30);

  // Live reading, top right - clear of the widest pulsing ring. Never a
  // placeholder: this used to print a hardcoded "36.5", which on a thermometer
  // screen reads as a measured value.
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(92, 4);
  if (tempValid) {
    display.print(tempValue, 1);
  } else {
    display.print("--.-");
  }

  drawModeFooter();

  // Right-aligned so it clears the mode footer on the left and the finger in the
  // centre. Without it, an absent reading is just dashes with no explanation.
  if (!tempValid) {
    const char* prompt = "PLACE FINGER";
    int w = strlen(prompt) * 6;
    display.setCursor(124 - w, 55);
    display.print(prompt);
  }
}

// The station is running, but on the kiosk screen rather than here.
//
// An X-ray image, a report, a conversation and a settings form are all things
// this display cannot represent, and a fake summary of them is worse than none:
// the user looks at the wrong surface. So these say plainly where to look, and
// name any hardware control that still does something from the module.
void drawDeferredToScreen(const char* station, const char* hint) {
  drawHeader("XSIGHT");
  drawSubHeader(station);

  display.drawRect(0, 28, 128, 22, SSD1306_WHITE);
  drawCentered("ON KIOSK SCREEN", 0, 28, 128, 22, 1);

  if (hint != nullptr) {
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    // Right-aligned-ish centring by hand: drawCentered needs a box, and the
    // footer is a bare line under the frame.
    int w = strlen(hint) * 6;
    int x = (128 - w) / 2;
    if (x < 0) x = 0;
    display.setCursor(x, 54);
    display.print(hint);
  }
}

void drawCurrentScreen() {
  display.clearDisplay();

  switch (currentState) {
    case STATE_INTRO: {
      // Outer double-line frame
      display.drawRect(0, 0, 128, 64, SSD1306_WHITE);
      display.drawRect(2, 2, 124, 60, SSD1306_WHITE);

      // "XSIGHT" title in its own bordered bar
      display.setTextColor(SSD1306_WHITE);
      drawCentered("XSIGHT", 10, 6, 108, 18, 2);

      // Lung icon, lifted to leave room for the session footer.
      drawLungIcon(64, 40);

      // One-line breadcrumb: who this session belongs to. Kept to a single line
      // so the idle screen stays the logo, but without it the module cannot say
      // whether it is serving a walk-in or a linked patient — the thing that
      // makes it read as part of a kiosk rather than a standalone gadget.
      display.setTextSize(1);
      String footer;
      if (currentMode == MODE_STAFF) {
        footer = patientName.length() ? patientName : String("STAFF");
      } else {
        footer = "WALK-IN";
      }
      if (footer.length() > 20) footer = footer.substring(0, 20);
      int fx = (128 - (int)footer.length() * 6) / 2;
      if (fx < 4) fx = 4;
      display.setCursor(fx, 53);
      display.print(footer);
      break;
    }

    case STATE_CONSENT: {
      drawHeader("SESSION");

      // Who the portal is asking about. Without the name the prompt is a bare
      // yes/no about nothing, and a walk-in could accept a stranger's record.
      display.setTextSize(1);
      String who = patientName.length() ? patientName : String("Web patient");
      if (who.length() > 20) who = who.substring(0, 20);
      drawCentered(who.c_str(), 0, 17, 128, 11, 1);

      // Two options, the highlighted one inverted so it reads across the room.
      const char* labels[2] = {"ACCEPT & START", "DECLINE"};
      for (int i = 0; i < 2; i++) {
        const int y = 30 + i * 17;
        const bool on = (consentIndex == i);
        if (on) {
          display.fillRect(4, y, 120, 15, SSD1306_WHITE);
          display.setTextColor(SSD1306_BLACK);
        } else {
          display.drawRect(4, y, 120, 15, SSD1306_WHITE);
          display.setTextColor(SSD1306_WHITE);
        }
        drawCentered(labels[i], 4, y, 120, 15, 1);
      }
      display.setTextColor(SSD1306_WHITE);
      break;
    }

    case STATE_MENU: {
      drawHeader("SELECT");
      display.setTextSize(1);
      const MenuEntry* menu = activeMenu();
      const int count = activeMenuCount();
      // The menu is taller than the five available rows in both modes, so keep
      // the selected item inside a scrolling window.
      const int visibleRows = 5;
      int firstItem = menuIndex - visibleRows + 1;
      if (firstItem < 0) firstItem = 0;
      int lastFirst = count - visibleRows;
      if (lastFirst < 0) lastFirst = 0;
      if (firstItem > lastFirst) firstItem = lastFirst;
      for (int row = 0; row < visibleRows; row++) {
        int i = firstItem + row;
        if (i >= count) break;
        int y = 18 + row * 9;
        if (i == menuIndex) {
          display.fillRect(0, y - 1, 128, 9, SSD1306_WHITE);
          display.setTextColor(SSD1306_BLACK);
        } else {
          display.setTextColor(SSD1306_WHITE);
        }
        display.setCursor(4, y);
        display.print(menu[i].label);
      }
      display.setTextColor(SSD1306_WHITE);
      break;
    }

    case STATE_XRAY: {
      // The film arrives by phone or file on the kiosk side; nothing about it
      // is renderable here. Upload state is still worth reporting, since it is
      // the one fact the module knows and the user may be standing at it.
      drawDeferredToScreen(labelForState(STATE_XRAY),
                           xraySub == SUB_DONE ? "FILE RECEIVED"
                                               : "WAITING FOR UPLOAD");
      break;
    }

    case STATE_STETH: {
      drawHeader("XSIGHT");
      drawSubHeader("DIGITAL STETHOSCOPE");
      if (stethSub == SUB_ACTIVE) {
        drawBox("READING....");
      } else if (stethSub == SUB_DONE) {
        drawBox("COMPLETED");
      } else {
        drawBox("PRESS OK TO START");
      }
      break;
    }

    case STATE_PULSE: {
      if (!pulseSensorOk) {
        drawHeader("XSIGHT");
        drawSubHeader("HEART RATE & SPO2");
        drawBox("SENSOR NOT FOUND");
      } else if (pulseSub == SUB_IDLE) {
        // Initial state - show instruction
        drawHeader("XSIGHT");
        drawSubHeader("HEART RATE & SPO2");
        drawBox("PRESS OK TO START");
      } else if (pulseSub == SUB_WAITING) {
        // Animated finger guidance - bottom to top approach
        drawAnimatedFingerGuide();
      } else {
        drawHeader("XSIGHT");
        display.drawRect(0, 16, 128, 12, SSD1306_WHITE);
        drawCentered(pulseSub == SUB_DONE ? "COMPLETED" : "MEASURING...", 0, 16, 128, 12, 1);

        display.drawRect(0, 28, 128, 36, SSD1306_WHITE);
        display.drawFastVLine(64, 28, 36, SSD1306_WHITE);

        drawStatColumn(0, 64, bpmValue, "HEART RATE");
        drawStatColumn(64, 128, spo2Value, "SPO2");
      }
      break;
    }

    case STATE_TEMP: {
      if (!tempSensorOk) {
        drawHeader("XSIGHT");
        drawSubHeader("TEMPERATURE");
        drawBox("SENSOR NOT FOUND");
      } else if (tempSub == SUB_ACTIVE) {
        // Animated thermometer guidance
        drawAnimatedTempGuide();
      } else if (tempSub == SUB_DONE) {
        // Show final reading
        drawHeader("XSIGHT");
        drawSubHeader("TEMPERATURE");
        display.drawRect(0, 28, 128, 36, SSD1306_WHITE);
        char buf[12];
        // %.1f is unreliable on some ESP32 cores' printf, so format the
        // integer and fractional parts by hand. The carry matters: 36.98
        // rounds to frac 10, which would otherwise render as "36.10 C".
        int whole = (int)tempValue;
        int frac = (int)((tempValue - whole) * 10.0 + 0.5);
        if (frac >= 10) { whole += 1; frac = 0; }
        sprintf(buf, "%d.%d C", whole, frac);
        drawCentered(buf, 0, 28, 128, 36, 2);
      } else {
        // Initial state - show instruction
        drawHeader("XSIGHT");
        drawSubHeader("TEMPERATURE");
        drawBox("PRESS OK TO START");
      }
      break;
    }

    case STATE_SUMMARY: {
      drawHeader("SUMMARY");
      display.setTextSize(1);
      display.setCursor(2, 18);
      display.print("XRAY: ");
      display.print(xrayUploaded ? "UPLOADED" : "NOT UPLOADED");

      display.setCursor(2, 28);
      display.print("STETH: ");
      display.print(stethDone ? "DONE" : "NOT DONE");

      display.setCursor(2, 38);
      display.print("BPM/SPO2: ");
      if (vitalsDone) {
        display.print(bpmValue);
        display.print("/");
        display.print(spo2Value);
      } else {
        display.print("--");
      }

      display.setCursor(2, 48);
      display.print("TEMP: ");
      // tempValid as well as tempDone: a locked-in reading that failed the
      // range check must not appear here as a measurement.
      if (tempDone && tempValid) {
        display.print(tempValue, 1);
        display.print(" C");
      } else {
        display.print("--");
      }

      // Which stations are done is data this module owns, so it is worth
      // showing. The risk assessment built from them is not — that is CDSS
      // output on the kiosk screen, and the old "BACK: home" footer left no
      // hint that there was more to see.
      display.setCursor(2, 58);
      display.print("ASSESSMENT ON SCREEN");
      break;
    }

    case STATE_ASSIST: {
      // The conversation is on the kiosk screen, but the module still owns the
      // push-to-talk button, so name it.
      drawDeferredToScreen(labelForState(STATE_ASSIST), "HOLD OK TO TALK");
      break;
    }

    case STATE_SETTINGS: {
      // Staff-only, and a server-address form is the clearest example of
      // something 128x64 pixels should not attempt.
      drawDeferredToScreen("SETTINGS", "BACK TO EXIT");
      break;
    }
  }

  display.display();
}
