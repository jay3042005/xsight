import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single reading from the ESP32 sensor hub transmitted over USB serial.
class SensorSnapshot {
  final double hr;
  final double spo2;
  final double temp;
  final double rr;
  final double sbp;
  final double dbp;
  final DateTime ts;

  const SensorSnapshot({
    required this.hr,
    required this.spo2,
    required this.temp,
    required this.rr,
    required this.sbp,
    required this.dbp,
    required this.ts,
  });

  factory SensorSnapshot.fromJson(Map<String, dynamic> json) {
    return SensorSnapshot(
      hr: (json['hr'] as num?)?.toDouble() ?? 0,
      spo2: (json['spo2'] as num?)?.toDouble() ?? 0,
      temp: (json['temp'] as num?)?.toDouble() ?? 0,
      rr: (json['rr'] as num?)?.toDouble() ?? 0,
      sbp: (json['sbp'] as num?)?.toDouble() ?? 0,
      dbp: (json['dbp'] as num?)?.toDouble() ?? 0,
      ts: DateTime.now(),
    );
  }

  Map<String, double> toVitalsMap() => {
    'hr': hr,
    'spo2': spo2,
    'temp': temp,
    'rr': rr,
    'sbp': sbp,
    'dbp': dbp,
  };

  @override
  String toString() =>
      'SensorSnapshot(hr=$hr, spo2=$spo2, temp=$temp, rr=$rr, bp=$sbp/$dbp)';
}

class StethSample {
  final double value;
  final DateTime ts;
  const StethSample(this.value, this.ts);
}

typedef Esp32NavigationCallback = void Function(String destination);
typedef Esp32PulseStateCallback = void Function(String state);
typedef Esp32DeviceStateCallback = void Function(int state);
typedef Esp32BackCallback = void Function();
typedef Esp32XrayStatusCallback = void Function(bool uploaded);
typedef Esp32MenuCallback = void Function(int index);

/// The module highlighted a station, named by its `NAV:` identity.
///
/// Preferred over [Esp32MenuCallback]: guest and staff menus differ in order and
/// length, so a bare index does not name the same station on both sides, and one
/// still in flight during a mode change resolves against the wrong table.
typedef Esp32MenuSelectCallback = void Function(String navToken);
typedef Esp32MenuReadyCallback = void Function();

/// The hub answered the consent prompt: `'ACCEPT'` or `'DECLINE'`.
typedef Esp32ConsentCallback = void Function(String action);

/// The hub moved the consent prompt's highlight without answering yet, so the
/// kiosk screen can mirror which option is about to be confirmed.
typedef Esp32ConsentSelectCallback = void Function(String action);
typedef Esp32VoiceOkCallback = void Function();
typedef Esp32VoiceDownCallback = void Function();
typedef Esp32VoiceUpCallback = void Function();
typedef Esp32StethStateCallback = void Function(String state);
typedef Esp32TempStateCallback = void Function(String state);
typedef Esp32ModeQueryCallback = void Function();

/// The module reported which menu table it is actually using.
///
/// Sent by the sketch after every `MODE:` command, and unconditionally: its
/// `setMode` returns early when the mode is unchanged, but the acknowledgement is
/// printed either way. So a redundant `MODE:GUEST` still produces a fresh ack,
/// which is what lets a caller re-send and compare without looping forever.
///
/// [isStaff] is the module's view, not the app's. They disagree when a `MODE:`
/// frame is lost on the wire, and that disagreement is otherwise invisible:
/// nothing else in the protocol reports the module's mode, and the module never
/// asks. Both sides resolve highlights by identity against their own table and
/// decline what does not fit, so drift loses a keypress rather than moving the
/// highlight to the wrong station — but it stays lost until the next mode change
/// or a reboot.
typedef Esp32ModeAckCallback = void Function(bool isStaff);

/// Reports a hardware fault the app cannot infer from a missing reading:
/// `SENSOR` for a module that failed to initialise, `TEMP` for a reading
/// outside the plausible body-temperature window.
typedef Esp32SensorErrorCallback = void Function(String kind);

/// Which physical link is carrying the XSIGHT protocol.
enum Esp32Transport { usb, bluetooth, none }

/// USB Serial + Bluetooth Classic SPP connection to an ESP32 sensor hub.
///
/// The ESP32 now advertises as "XSIGHT" over Bluetooth Classic SPP **and**
/// exposes the same protocol over USB CDC (see firmware/XSIGHT/XSIGHT.ino).
/// This client tries **USB first** (fast, no pairing), then transparently
/// falls back to Bluetooth when no USB device is found or the Android USB
/// permission/open fails.  Once connected over either transport it speaks the
/// *identical* newline-delimited protocol, so the rest of the app does not
/// need to know which link is active.
///
/// Auto-reconnect: every 2 s after a disconnect the client retries USB first,
/// then Bluetooth (using the last successful BT address without a fresh scan).
/// Bluetooth discovery is only run when there is no last-known device or when
/// [connectBluetooth] is called with `scanIfNeeded:true`.
///
/// On platforms without Classic BT (iOS-unpaired, or lack of adapter) the BT
/// path degrades to `false` and leaves [_error] explaining why.
class Esp32SerialClient extends ChangeNotifier {
  static final shared = Esp32SerialClient();
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _sub;
  StreamSubscription<dynamic>? _androidSub;
  static const _android = MethodChannel('xsight_usb_serial');
  static const _androidEvents = EventChannel('xsight_usb_serial/events');
  final StringBuffer _lineBuf = StringBuffer();

  // ─── Bluetooth ──────────────────────────────────────────────────────
  final FlutterClassicBluetooth _bt = FlutterClassicBluetooth();
  BtcConnection? _btConn;
  StreamSubscription<Uint8List>? _btSub;
  StreamSubscription<BtcConnectionState>? _btStateSub;
  static const _btPrefsKey = 'xsight_last_bt_address';
  static const _btNamePrefixes = ['XSIGHT', 'XSIGHT-THORACIC'];
  Esp32Transport _transport = Esp32Transport.none;
  bool _btConnecting = false;

  SensorSnapshot? _latest;
  bool _connected = false;
  bool _deviceReady = false;
  String? _error;
  String _portName = '';
  StethSample? _latestSteth;
  final List<int> _stethSamples = [];
  bool _stethNotifyPending = false;
  int _stethFrameState = 0;
  int _stethFrameLow = 0;

  /// True once the module has named a station by token, which means it speaks
  /// the identity dialect and its `MENU_INDEX:` lines are redundant echoes.
  bool _menuTokensSeen = false;
  String? _pulseState;
  String? _tempState;
  Esp32NavigationCallback? onNavigate;
  Esp32PulseStateCallback? onPulseState;
  Esp32DeviceStateCallback? onDeviceState;
  Esp32BackCallback? onBack;
  Esp32XrayStatusCallback? onXrayStatus;
  Esp32MenuCallback? onMenuIndex;
  Esp32MenuSelectCallback? onMenuSelect;
  Esp32MenuReadyCallback? onMenuReady;
  Esp32ConsentCallback? onConsent;
  Esp32ConsentSelectCallback? onConsentSelect;
  Esp32VoiceOkCallback? onVoiceOk;
  Esp32VoiceDownCallback? onVoiceDown;
  Esp32VoiceUpCallback? onVoiceUp;
  Esp32StethStateCallback? onStethState;
  Esp32TempStateCallback? onTempState;
  Esp32ModeQueryCallback? onModeQuery;
  Esp32ModeAckCallback? onModeAck;
  Esp32SensorErrorCallback? onSensorError;
  Future<bool>? _connectInFlight;
  Timer? _handshakeTimer;
  Timer? _reconnectTimer;
  int _handshakeAttempts = 0;

  SensorSnapshot? get latest => _latest;

  /// The module's last reported pulse station state — `WAITING`, `ACTIVE`,
  /// `DONE`, `CANCELLED` — or null before the station has run.
  ///
  /// Published as well as dispatched to [onPulseState] because the callbacks are
  /// single-owner fields the shell holds for the voice cues; a screen that has to
  /// follow the scan's progress would otherwise have to take them over.
  String? get pulseState => _pulseState;

  /// The module's last reported temperature station state — `ACTIVE` or `DONE`.
  String? get tempState => _tempState;
  bool get connected => _connected;
  bool get deviceReady => _deviceReady;
  String? get error => _error;
  String get portName => _portName;
  Esp32Transport get transport => _transport;
  bool get usingBluetooth => _transport == Esp32Transport.bluetooth;
  bool get usingUsb => _transport == Esp32Transport.usb;

  /// Human label for UI chips, e.g. "USB: /dev/ttyUSB0" or "BT: XSIGHT (AA:..)"
  String get transportLabel {
    if (_transport == Esp32Transport.bluetooth) return 'BT: $_portName';
    if (_transport == Esp32Transport.usb) return 'USB: $_portName';
    return 'No link';
  }

  StethSample? get latestSteth => _latestSteth;
  List<int> get stethSamples => List.unmodifiable(_stethSamples);
  void clearStethSamples() => _stethSamples.clear();

  /// Begin a new pulse-oximeter acquisition without carrying the previous
  /// scan's HR/SpO2 pair into the station that is about to mount.
  ///
  /// Temperature and optional slow-sensor fields are retained because they
  /// belong to other stations. The patient session keeps the last completed
  /// result separately, so clearing this transport cache does not erase the
  /// dashboard or report.
  void beginVitalsScan() {
    final prev = _latest;
    _latest = SensorSnapshot(
      hr: 0,
      spo2: 0,
      temp: prev?.temp ?? 0,
      rr: prev?.rr ?? 0,
      sbp: prev?.sbp ?? 0,
      dbp: prev?.dbp ?? 0,
      ts: DateTime.now(),
    );
    _pulseState = null;
    notifyListeners();
  }

  /// Begin a new thermometer acquisition without treating the previous
  /// station's temperature as contact for the new timed window.
  void beginTempScan() {
    final prev = _latest;
    _latest = SensorSnapshot(
      hr: prev?.hr ?? 0,
      spo2: prev?.spo2 ?? 0,
      temp: 0,
      rr: prev?.rr ?? 0,
      sbp: prev?.sbp ?? 0,
      dbp: prev?.dbp ?? 0,
      ts: DateTime.now(),
    );
    _tempState = null;
    notifyListeners();
  }

  /// Drop every cached reading and station state.
  ///
  /// Called when the session's subject changes (Stop Session, new patient
  /// linked). The client is app-lifetime, so without this the *next* person's
  /// vitals and temperature screens came up showing the previous person's
  /// numbers: [latest] still held the old snapshot, and both screens seed
  /// themselves from it on mount. Clearing here makes "new session" mean
  /// zeroed gauges everywhere, whatever path reset the session.
  void clearReadings() {
    _latest = null;
    _latestSteth = null;
    _stethSamples.clear();
    _pulseState = null;
    _tempState = null;
    _cancelSimulation();
    notifyListeners();
  }

  // ─── Keyboard-triggered simulation (hardware-free demos) ───────────

  /// True while a keyboard-triggered simulation is standing in for the module.
  ///
  /// Screens read this so a simulated reading stays labelled SIMULATED instead
  /// of passing as a module measurement.
  bool _simulating = false;
  Timer? _simTimer;
  Timer? _simFrameTimer;
  final Random _simRng = Random();

  bool get simulating => _simulating;

  /// Emulates a finger on the pulse sensor: `PULSE_ACTIVE`, a 1 Hz stream of
  /// `VITALS:` frames, then the final pair and `PULSE_DONE` — the same frame
  /// sequence the firmware emits, so the vitals station runs its real phases
  /// (contact detect, countdown, completion) untouched.
  ///
  /// The window is 5s rather than the firmware's 20s `PULSE_SCAN_MS` so a demo
  /// does not wait; the station completes on `PULSE_DONE` whenever it lands.
  /// No-op when a real module is linked, because then the module owns the
  /// protocol and injecting frames would interleave two clocks.
  void simulateVitalsScan() {
    if (_connected) return;
    _cancelSimulation();
    _simulating = true;
    _parseLine('PULSE_ACTIVE:1');
    _simFrameTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _emitSimVitals();
    });
    _simTimer = Timer(const Duration(seconds: 5), () {
      _simFrameTimer?.cancel();
      _simFrameTimer = null;
      _emitSimVitals();
      _parseLine('PULSE_DONE:1');
      _simulating = false;
    });
  }

  /// Emulates a fingertip on the IR sensor: `TEMP_ACTIVE` plus a reading, then
  /// a final reading and `TEMP_DONE` on the same 5s window the firmware uses.
  void simulateTempScan() {
    if (_connected) return;
    _cancelSimulation();
    _simulating = true;
    _parseLine('TEMP_ACTIVE:1');
    _parseLine('TEMP:${(36.2 + _simRng.nextDouble()).toStringAsFixed(1)}');
    _simTimer = Timer(const Duration(seconds: 5), () {
      _parseLine('TEMP:${(36.2 + _simRng.nextDouble()).toStringAsFixed(1)}');
      _parseLine('TEMP_DONE:1');
      _simulating = false;
    });
  }

  void _emitSimVitals() {
    final hr = 62 + _simRng.nextDouble() * 33;
    final spo2 = 95 + _simRng.nextDouble() * 4;
    _parseLine('VITALS:${hr.toStringAsFixed(0)},${spo2.toStringAsFixed(0)}');
  }

  void _cancelSimulation() {
    _simTimer?.cancel();
    _simTimer = null;
    _simFrameTimer?.cancel();
    _simFrameTimer = null;
    _simulating = false;
  }

  /// Latest available port matching common USB-serial profiles.
  /// Returns null if none found.
  static String? findEsp32Port() {
    final List<String> ports;
    try {
      ports = SerialPort.availablePorts;
    } catch (e) {
      // libserialport may be absent (headless host, unbundled desktop build).
      // Treat it as "no module attached" rather than letting an FFI load
      // failure escape into the widget tree.
      debugPrint('[esp32] serial enumeration unavailable: $e');
      return null;
    }
    for (final name in ports) {
      final sp = SerialPort(name);
      try {
        if (sp.open(mode: SerialPortMode.readWrite)) {
          final vid = sp.vendorId;
          sp.close();
          // Common ESP32 USB-CDC / CH340 / CP210x identifiers
          if (vid == 0x303A || // Espressif ESP32-S3 native USB
              vid == 0x1A86 || // CH340
              vid == 0x10C4 || // CP210x
              vid == 0x0403 || // FTDI
              name.contains('ttyUSB') ||
              name.contains('ttyACM') ||
              name.contains('usbserial')) {
            return name;
          }
        }
        sp.close();
      } catch (_) {
        try {
          sp.close();
        } catch (_) {}
      }
    }
    return ports.isNotEmpty ? ports.first : null;
  }

  /// Open a connection, trying **USB first, then Bluetooth**.
  ///
  /// * `portName` forces a specific USB serial port (desktop/Linux).
  /// * `bluetoothAddress` forces a specific BT MAC; when null the client
  ///   auto-discovers: last-known bonded address → any bonded XSIGHT* →
  ///   short discovery scan for XSIGHT*.
  ///
  /// Returns `true` if either transport linked and the handshake started.
  Future<bool> connect({String? portName, String? bluetoothAddress}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_connected) return Future<bool>.value(true);
    final running = _connectInFlight;
    if (running != null) return running;
    final future = _connectWithFallback(
      portName: portName,
      bluetoothAddress: bluetoothAddress,
    );
    _connectInFlight = future;
    return future.whenComplete(() => _connectInFlight = null);
  }

  /// Explicit Bluetooth connect, bypassing the USB attempt.
  ///
  /// Used by the Bluetooth picker / manual "Pair XSIGHT" button.  When
  /// [address] is null the same auto-discovery as [connect] is used.  Set
  /// [scanIfNeeded] false to avoid a discovery scan (only bonded/last-known).
  Future<bool> connectBluetooth({
    String? address,
    bool scanIfNeeded = true,
  }) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_btConnecting) return false;
    await disconnect(); // closes USB if open, resets state
    final ok = await _tryBluetoothConnect(
      address: address,
      scanIfNeeded: scanIfNeeded,
    );
    if (ok) {
      _connected = true;
      notifyListeners();
    }
    return ok;
  }

  /// Explicitly scan for XSIGHT devices (paired + discoverable).
  ///
  /// Returned list is de-duplicated and sorted strongest RSSI first.
  Future<List<BtcDevice>> scanForXsight({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final List<BtcDevice> out = [];
    try {
      // Start with bonded XSIGHT* — always available without a live scan
      final bonded = await _bt.getPairedDevices();
      for (final d in bonded) {
        final n = (d.name ?? d.alias ?? '').toUpperCase();
        if (_btNamePrefixes.any((p) => n.contains(p))) out.add(d);
      }
      // Add live discovery if platform allows it
      BtcPlatformCapabilities? caps;
      try {
        caps = await _bt.getPlatformCapabilities();
      } catch (_) {
        caps = null;
      }
      if (caps != null && caps.canDiscoverDevices) {
        List<BtcDevice> found = [];
        try {
          found = await _bt.scan(timeout: timeout);
        } catch (_) {
          found = [];
        }
        for (final d in found) {
          final n = (d.name ?? d.alias ?? '').toUpperCase();
          if (_btNamePrefixes.any((p) => n.contains(p)) ||
              n.contains('XSIGHT')) {
            if (!out.any((e) => e.address == d.address)) out.add(d);
          }
        }
        out.sort((a, b) => (b.rssi ?? -1000).compareTo(a.rssi ?? -1000));
      }
    } catch (e) {
      debugPrint('[esp32][bt] scanForXsight error: $e');
    }
    return out;
  }

  /// Get currently paired XSIGHT devices (no scan).
  Future<List<BtcDevice>> getPairedXsightDevices() async {
    try {
      final bonded = await _bt.getPairedDevices();
      return bonded.where((d) {
        final n = (d.name ?? d.alias ?? '').toUpperCase();
        return _btNamePrefixes.any((p) => n.contains(p));
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> _connectWithFallback({
    String? portName,
    String? bluetoothAddress,
  }) async {
    // USB first — fastest, no pairing, lowest latency
    final usbOk = await _tryUsbConnect(portName: portName);
    if (usbOk) return true;
    debugPrint(
      '[esp32] USB unavailable (${_error ?? "no port"}), trying Bluetooth fallback…',
    );
    // Keep the USB error for the UI if BT also fails; the combined message
    // explains both legs.
    final usbError = _error;
    final btOk = await _tryBluetoothConnect(
      address: bluetoothAddress,
      scanIfNeeded: true,
    );
    if (btOk) return true;
    // Neither leg worked — surface both reasons so the helper bubble can say
    // "No USB and no BT XSIGHT found".
    if (usbError != null && _error != null && !_error!.contains('USB')) {
      _error = '$usbError  |  BT: $_error';
      notifyListeners();
    }
    // A clean failure (nothing found / module still booting) is exactly the
    // state a kiosk is in while its hub powers up, so keep trying. Without
    // this the first attempt was also the last: reconnect was only scheduled
    // from stream error/done callbacks, which a never-opened link never fires.
    _scheduleReconnect();
    return false;
  }

  Future<bool> _tryUsbConnect({String? portName}) async {
    // Close any prior link (including BT) before probing USB
    await _closeBluetooth(silent: true);
    await _closeUsb(silent: true);
    _transport = Esp32Transport.none;
    _portName = '';
    _connected = false;
    _deviceReady = false;

    if (Platform.isAndroid) {
      final ok = await _connectAndroid();
      if (ok) {
        _transport = Esp32Transport.usb;
        _portName = 'Android USB';
        // _connectAndroid already set _connected, _deviceReady, handshake
        return true;
      }
      // Android USB failed — let caller try BT
      return false;
    }

    final name = portName ?? findEsp32Port();
    if (name == null || name.isEmpty) {
      _error = Platform.isLinux
          ? 'No USB serial device found. Will try Bluetooth…'
          : 'No USB serial port found. Will try Bluetooth…';
      notifyListeners();
      return false;
    }

    _portName = name;
    _port = SerialPort(name);

    if (!_port!.open(mode: SerialPortMode.readWrite)) {
      _error =
          'Failed to open $name: ${SerialPort.lastError}  — trying Bluetooth…';
      _connected = false;
      _port = null;
      notifyListeners();
      return false;
    }

    // ESP32 default baud — USB-CDC ignores baud but set anyway.
    final config = _port!.config;
    config.baudRate = 115200;
    config.bits = 8;
    config.parity = SerialPortParity.none;
    config.stopBits = 1;
    _port!.config = config;
    _port!.flush();

    _reader = SerialPortReader(_port!);
    _sub = _reader!.stream.listen(
      _onData,
      onError: (e) {
        debugPrint('[esp32] stream error: $e');
        _error = 'Serial error: $e';
        _connected = false;
        _transport = Esp32Transport.none;
        _scheduleReconnect();
        notifyListeners();
      },
      onDone: () {
        debugPrint('[esp32] stream closed');
        _connected = false;
        _transport = Esp32Transport.none;
        try {
          _port?.close();
        } catch (_) {}
        _port = null;
        _reader = null;
        _scheduleReconnect();
        if (hasListeners) notifyListeners();
      },
    );

    _connected = true;
    _transport = Esp32Transport.usb;
    _deviceReady = false;
    _error = null;
    debugPrint('[esp32] connected on $name (USB)');
    await _resetEsp32();
    _startHandshake();
    notifyListeners();
    return true;
  }

  Future<void> _resetEsp32() async {
    final port = _port;
    if (port == null || !Platform.isLinux) return;
    try {
      // Release both CP210x modem lines. Pulsing DTR/RTS can assert GPIO0 and
      // leave classic ESP32 boards in DOWNLOAD_BOOT mode.
      final config = port.config;
      config.rts = 1;
      config.dtr = 1;
      port.config = config;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      port.flush();
    } catch (e) {
      debugPrint('[esp32] modem-line setup unavailable: $e');
    }
  }

  Future<bool> _connectAndroid() async {
    try {
      // Subscribe before requesting permission; the ESP32 may answer immediately.
      await _androidSub?.cancel();
      _androidSub = _androidEvents.receiveBroadcastStream().listen(
        (data) => _onAndroidData(data),
        onError: (e) {
          _error = 'USB serial error: $e';
          _connected = false;
          _transport = Esp32Transport.none;
          notifyListeners();
        },
      );
      final ok = await _android.invokeMethod<bool>('connect') ?? false;
      if (!ok) {
        _error = 'USB connection failed.';
        await _androidSub?.cancel();
        _androidSub = null;
        notifyListeners();
        return false;
      }
      _portName = 'Android USB-C';
      _connected = true;
      _deviceReady = false;
      _error = null;
      _startHandshake();
      notifyListeners();
      return true;
    } on PlatformException catch (e) {
      _error = e.message ?? 'USB connection failed';
      await _androidSub?.cancel();
      _androidSub = null;
      notifyListeners();
      return false;
    }
  }

  // ─── Bluetooth path ───────────────────────────────────────────────

  Future<bool> _tryBluetoothConnect({
    String? address,
    bool scanIfNeeded = true,
  }) async {
    if (_btConnecting) return false;
    _btConnecting = true;
    try {
      // Permissions (Android 12+ needs runtime BLUETOOTH_SCAN/CONNECT)
      if (Platform.isAndroid) {
        try {
          // Request without blocking forever: permission_handler returns quickly
          try {
            await Permission.bluetoothScan.request();
          } catch (_) {}
          try {
            await Permission.bluetoothConnect.request();
          } catch (_) {}
        } catch (_) {}
      }

      bool supported = false;
      try {
        supported = await _bt.isSupported();
      } catch (_) {
        supported = false;
      }
      if (!supported) {
        _error = 'Bluetooth Classic not supported on this device.';
        debugPrint('[esp32][bt] not supported');
        return false;
      }

      bool enabled = false;
      try {
        enabled = await _bt.isEnabled();
      } catch (_) {
        enabled = false;
      }
      if (!enabled) {
        debugPrint('[esp32][bt] adapter off, requesting enable…');
        try {
          final en = await _bt.enableBluetooth();
          if (!en) {
            _error = 'Bluetooth is off. Enable Bluetooth and retry.';
            return false;
          }
        } catch (e) {
          _error = 'Bluetooth enable failed: $e';
          return false;
        }
      }

      BtcDevice? target;

      // 1) Explicit address wins
      if (address != null && address.isNotEmpty) {
        target = BtcDevice(address: address, name: address);
      }

      // 2) Last-known address (persisted after last successful BT connect)
      if (target == null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final last = prefs.getString(_btPrefsKey);
          if (last != null && last.isNotEmpty) {
            // Prefer the bonded entry with that address so we get its name
            List<BtcDevice> bonded = [];
            try {
              bonded = await _bt.getPairedDevices();
            } catch (_) {
              bonded = [];
            }
            final match = bonded
                .where((d) => d.address.toUpperCase() == last.toUpperCase())
                .toList();
            if (match.isNotEmpty) {
              target = match.first;
              debugPrint(
                '[esp32][bt] using last-known ${target.displayName} @ ${target.address}',
              );
            } else {
              // Even if not bonded any more, try the raw address — the ESP32 may be pairable
              target = BtcDevice(address: last, name: last);
              debugPrint('[esp32][bt] last-known raw address $last');
            }
          }
        } catch (_) {}
      }

      // 3) Any bonded XSIGHT* device
      if (target == null) {
        try {
          final bonded = await _bt.getPairedDevices();
          for (final d in bonded) {
            final n = (d.name ?? d.alias ?? '').toUpperCase();
            if (_btNamePrefixes.any((p) => n.contains(p))) {
              target = d;
              debugPrint(
                '[esp32][bt] found bonded XSIGHT ${d.displayName} @ ${d.address}',
              );
              break;
            }
          }
        } catch (e) {
          debugPrint('[esp32][bt] getPairedDevices failed: $e');
        }
      }

      // 4) Short discovery scan for XSIGHT* (only when allowed)
      if (target == null && scanIfNeeded) {
        try {
          final caps = await _bt.getPlatformCapabilities();
          if (caps.canDiscoverDevices) {
            debugPrint('[esp32][bt] scanning 8s for XSIGHT…');
            final found = await _bt.scan(timeout: const Duration(seconds: 8));
            // Strongest RSSI first already, but ensure XSIGHT filtering
            for (final d in found) {
              final n = (d.name ?? d.alias ?? '').toUpperCase();
              if (_btNamePrefixes.any((p) => n.contains(p)) ||
                  n.contains('XSIGHT')) {
                target = d;
                debugPrint(
                  '[esp32][bt] discovered ${d.displayName} @ ${d.address} rssi ${d.rssi}',
                );
                break;
              }
            }
            if (target == null && found.isNotEmpty) {
              debugPrint(
                '[esp32][bt] scan found ${found.length} devices but none matching XSIGHT prefix',
              );
            }
          } else {
            debugPrint('[esp32][bt] discovery not supported on this platform');
          }
        } catch (e) {
          debugPrint('[esp32][bt] scan failed: $e');
        }
      }

      if (target == null) {
        _error = scanIfNeeded
            ? 'No XSIGHT Bluetooth device found. Pair "XSIGHT" in system Bluetooth settings, bring the module within 1 m, then tap Retry. (USB also unavailable)'
            : 'No bonded XSIGHT device. Pair XSIGHT in Bluetooth settings first.';
        debugPrint('[esp32][bt] no target found');
        return false;
      }

      // Tear down any stale BT state
      await _closeBluetooth(silent: true);

      debugPrint(
        '[esp32][bt] connecting to ${target.address} (${target.displayName})…',
      );
      _portName = '${target.displayName} (${target.address})';

      try {
        _btConn = await _bt.connect(
          address: target.address,
          secure: true,
          timeout: const Duration(seconds: 12),
        );
      } catch (e) {
        _error = 'Bluetooth connect to ${target.displayName} failed: $e';
        debugPrint('[esp32][bt] connect error: $e');
        return false;
      }

      // Wire up byte stream — same framing as USB so steth binary frames work
      _btSub = _btConn!.input.listen(
        _onData,
        onError: (e) {
          debugPrint('[esp32][bt] stream error: $e');
          _error = 'Bluetooth error: $e';
          _connected = false;
          _transport = Esp32Transport.none;
          _scheduleReconnect();
          notifyListeners();
        },
        onDone: () {
          debugPrint('[esp32][bt] stream closed');
          _connected = false;
          _transport = Esp32Transport.none;
          _btConn?.dispose();
          _btConn = null;
          _scheduleReconnect();
          if (hasListeners) notifyListeners();
        },
      );

      _btStateSub = _btConn!.stateStream.listen((s) {
        debugPrint('[esp32][bt] state $s');
        if (s == BtcConnectionState.disconnected) {
          _connected = false;
          _transport = Esp32Transport.none;
          // RFCOMM drops (module reboot, out-of-range) must re-enter the auto-
          // connect loop; notifying alone left the kiosk offline until a screen's
          // manual Retry was tapped.
          _scheduleReconnect();
          notifyListeners();
        }
      });

      _connected = true;
      _transport = Esp32Transport.bluetooth;
      _deviceReady = false;
      _error = null;

      // Persist for next auto-connect (no scan needed)
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_btPrefsKey, target.address);
      } catch (_) {}

      debugPrint('[esp32][bt] connected to ${target.address} via BT');
      _startHandshake();
      notifyListeners();
      return true;
    } finally {
      _btConnecting = false;
    }
  }

  Future<void> _closeBluetooth({bool silent = false}) async {
    try {
      await _btSub?.cancel();
    } catch (_) {}
    _btSub = null;
    try {
      await _btStateSub?.cancel();
    } catch (_) {}
    _btStateSub = null;
    if (_btConn != null) {
      try {
        await _btConn!.close();
      } catch (_) {}
      try {
        _btConn!.dispose();
      } catch (_) {}
      _btConn = null;
    }
    if (!silent) {
      _transport = Esp32Transport.none;
    }
  }

  Future<void> _closeUsb({bool silent = false}) async {
    try {
      await _androidSub?.cancel();
    } catch (_) {}
    _androidSub = null;
    if (Platform.isAndroid && !silent) {
      try {
        await _android.invokeMethod<void>('disconnect');
      } catch (_) {}
    }
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _reader = null;
    if (_port != null) {
      try {
        _port!.close();
      } catch (_) {}
      _port = null;
    }
    if (!silent) {
      _transport = Esp32Transport.none;
    }
  }

  void _onData(Uint8List data) {
    for (final byte in data) {
      if (_consumeStethByte(byte)) continue;
      // Binary steth frames use non-ASCII sync bytes. Everything else remains
      // newline-delimited protocol text.
      if (byte == 9 ||
          byte == 10 ||
          byte == 13 ||
          (byte >= 32 && byte <= 126)) {
        _lineBuf.writeCharCode(byte);
      }
    }
    var buf = _lineBuf.toString();
    while (buf.contains('\n')) {
      final idx = buf.indexOf('\n');
      final line = buf.substring(0, idx).trim();
      buf = buf.substring(idx + 1);
      if (line.isEmpty) continue;
      debugPrint('[esp32] <$line>');
      _parseLine(line);
    }
    _lineBuf.clear();
    _lineBuf.write(buf);
  }

  bool _consumeStethByte(int byte) {
    switch (_stethFrameState) {
      case 0:
        if (byte != 0xA5) return false;
        _stethFrameState = 1;
        return true;
      case 1:
        if (byte == 0x5A) {
          _stethFrameState = 2;
        } else {
          _stethFrameState = byte == 0xA5 ? 1 : 0;
        }
        return true;
      case 2:
        _stethFrameLow = byte;
        _stethFrameState = 3;
        return true;
      default:
        final value = _stethFrameLow | (byte << 8);
        _stethFrameState = 0;
        _addStethSample(value >= 0x8000 ? value - 0x10000 : value);
        return true;
    }
  }

  void _addStethSample(int value) {
    _latestSteth = StethSample(value.toDouble(), DateTime.now());
    _stethSamples.add(value);
    if (_stethSamples.length > 2000 * 30) _stethSamples.removeAt(0);
    if (!_stethNotifyPending) {
      _stethNotifyPending = true;
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        _stethNotifyPending = false;
        if (hasListeners) notifyListeners();
      });
    }
  }

  void _onAndroidData(dynamic data) {
    if (data is Uint8List) {
      _onData(data);
    } else if (data is List) {
      _onData(Uint8List.fromList(data.cast<int>()));
    } else if (data is String) {
      _onData(Uint8List.fromList(utf8.encode(data)));
    }
  }

  /// Feed one already-framed protocol line as if it had arrived over the wire.
  ///
  /// Exists so the line protocol — which is where the guest/staff highlight bugs
  /// live — can be tested without a serial port or the libserialport FFI.
  @visibleForTesting
  void debugHandleLine(String line) => _parseLine(line);

  void _parseLine(String line) {
    // XSIGHT.ino uses newline-delimited text, not JSON.
    if (line == 'READY:1' ||
        line == 'PONG' ||
        line == 'LINK:1' ||
        line.startsWith('STATUS:')) {
      final wasReady = _deviceReady;
      _deviceReady = true;
      if (line == 'READY:1') {
        // The module rebooted, and a reboot can mean a different firmware build,
        // so re-learn which menu dialect it speaks. Safe because the firmware
        // always prints `MENU_SEL:` immediately before the paired
        // `MENU_INDEX:`, and lines are parsed in arrival order.
        _menuTokensSeen = false;
      }
      _handshakeTimer?.cancel();
      _handshakeTimer = null;
      if (line.startsWith('STATUS:')) {
        final state = int.tryParse(line.substring(7).split(',').first);
        if (state != null) onDeviceState?.call(state);
      }
      // `LINK:1` is a 2-second heartbeat, so doing this unconditionally
      // re-announced the mode and rebuilt every listener ~30 times a minute
      // while the kiosk sat idle. Only a transition into readiness is news —
      // plus `READY:1`, which means the firmware rebooted and has genuinely
      // forgotten which mode it is in.
      if (!wasReady || line == 'READY:1') {
        onModeQuery?.call();
        notifyListeners();
      }
      return;
    }
    if (line.startsWith('ERR:')) {
      final kind = line.substring(4).trim().toUpperCase();
      debugPrint('[esp32] sensor error: $kind');
      onSensorError?.call(kind);
      return;
    }
    if (line.startsWith('MODE_ACK:')) {
      onModeAck?.call(line.substring(9).trim().toUpperCase() == 'STAFF');
      return;
    }
    if (line == 'MODE:GET' || line == 'MODE:QUERY') {
      onModeQuery?.call();
      return;
    }
    if (line == 'MENU:READY') {
      onMenuReady?.call();
      return;
    }
    // Order matters: 'CONSENT:' is a prefix of 'CONSENT_SEL:' only if tested
    // loosely, so the longer, more specific frame is matched first.
    if (line.startsWith('CONSENT_SEL:')) {
      final action = line.substring(12).trim().toUpperCase();
      if (action == 'ACCEPT' || action == 'DECLINE') {
        onConsentSelect?.call(action);
      }
      return;
    }
    if (line.startsWith('CONSENT:')) {
      final action = line.substring(8).trim().toUpperCase();
      if (action == 'ACCEPT' || action == 'DECLINE') {
        onConsent?.call(action);
      }
      return;
    }
    if (line == 'NAV:MENU' || line == 'NAV:HOME') {
      onBack?.call();
      return;
    }
    if (line == 'VOICE_OK') {
      onVoiceOk?.call();
      return;
    }
    if (line == 'VOICE_DOWN') {
      onVoiceDown?.call();
      return;
    }
    if (line == 'VOICE_UP') {
      onVoiceUp?.call();
      return;
    }
    // Identity-based highlight. The firmware emits this *and* a `MENU_INDEX:`
    // for the same event, as two separate lines, so both handlers would
    // otherwise fire — and the index resolves against the pre-token firmware's
    // single menu, which is in staff order. In guest mode that means
    // `MENU_SEL:VITALS` focuses vitals and the `MENU_INDEX:0` right behind it
    // moves the highlight to x-ray. Seeing a token settles which dialect the
    // module speaks; from then on the index is ignored.
    if (line.startsWith('MENU_SEL:')) {
      final token = line.substring(9).trim().toUpperCase();
      if (token.isNotEmpty) {
        _menuTokensSeen = true;
        onMenuSelect?.call(token);
      }
      return;
    }
    if (line.startsWith('MENU_SELECT:')) {
      // The module launched a station from its own OK press. It sends `NAV:` for
      // the same press, which is what actually opens the screen, so this only
      // needs to keep the highlight in step. A numeric payload is the legacy
      // form and is ignored rather than mistaken for a token.
      final token = line.substring(12).trim().toUpperCase();
      if (token.isNotEmpty && int.tryParse(token) == null) {
        _menuTokensSeen = true;
        onMenuSelect?.call(token);
      }
      return;
    }
    if (line.startsWith('MENU_INDEX:')) {
      if (_menuTokensSeen) return;
      final index = int.tryParse(line.substring(11).trim());
      if (index != null) onMenuIndex?.call(index);
      return;
    }
    if (line.startsWith('NAV:')) {
      final destination = line.substring(4).trim().toUpperCase();
      debugPrint('[esp32] navigation: $destination');
      onNavigate?.call(destination);
      return;
    }
    if (line.startsWith('STETH_')) {
      onStethState?.call(line);
      return;
    }
    if (line.startsWith('PULSE_')) {
      final state = line.split(':').first.substring(6);
      _pulseState = state;
      onPulseState?.call(state);
      notifyListeners();
      return;
    }
    if (line.startsWith('TEMP_')) {
      final state = line.split(':').first.substring(5);
      _tempState = state;
      onTempState?.call(state);
      notifyListeners();
      return;
    }
    if (line.startsWith('VITALS:')) {
      debugPrint('[esp32] vitals frame: $line');
      final parts = line.substring(7).split(',');
      if (parts.length >= 2) {
        _merge({
          'hr': double.tryParse(parts[0]),
          'spo2': double.tryParse(parts[1]),
        });
      }
      return;
    }
    if (line.startsWith('XRAY_STATUS:')) {
      onXrayStatus?.call(line.substring(12).trim() == '1');
      return;
    }
    if (line.startsWith('TEMP:')) {
      _merge({'temp': double.tryParse(line.substring(5))});
      return;
    }
    if (line.startsWith('STETH:')) {
      final value = double.tryParse(line.substring(6));
      if (value != null) {
        _addStethSample(value.round().clamp(-32768, 32767));
      }
      return;
    }
    if (line.startsWith('{')) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        _merge(json);
      } catch (e) {
        debugPrint('[esp32] parse error: $e  line=$line');
      }
    }
  }

  /// Merge partial frames so slow sensors (BP) don't clobber fast ones (SpO₂).
  void _merge(Map<String, dynamic> json) {
    final prev = _latest;
    _latest = SensorSnapshot(
      hr: (json['hr'] as num?)?.toDouble() ?? prev?.hr ?? 0,
      spo2: (json['spo2'] as num?)?.toDouble() ?? prev?.spo2 ?? 0,
      temp: (json['temp'] as num?)?.toDouble() ?? prev?.temp ?? 0,
      rr: (json['rr'] as num?)?.toDouble() ?? prev?.rr ?? 0,
      sbp: (json['sbp'] as num?)?.toDouble() ?? prev?.sbp ?? 0,
      dbp: (json['dbp'] as num?)?.toDouble() ?? prev?.dbp ?? 0,
      ts: DateTime.now(),
    );
    notifyListeners();
  }

  /// Sends one of the sketch commands, e.g. `XRAY_UPLOADED:1`.
  ///
  /// Routes to whichever transport is currently linked — BT RFCOMM when
  /// [_transport]==bluetooth, otherwise USB (desktop libserialport or Android
  /// usb_serial channel).
  bool sendCommand(String command) {
    // Bluetooth path — same line protocol, just a different socket
    if (_transport == Esp32Transport.bluetooth) {
      final conn = _btConn;
      if (conn == null || !_connected) return false;
      try {
        // BtcStreamSink.add is ordered and back-pressured; fire-and-forget is
        // fine for the small <32-byte command lines at 2 Hz heartbeat.
        unawaited(conn.output.writeString('$command\n'));
        debugPrint('[esp32][bt] tx $command');
        return true;
      } catch (e) {
        _error = 'Bluetooth write error: $e';
        notifyListeners();
        return false;
      }
    }
    if (Platform.isAndroid) {
      if (!_connected) return false;
      // Guard: if we somehow have a BT transport but Platform.isAndroid gate
      // fired, BT already returned above — this is USB.
      _android.invokeMethod<bool>('write', {
        'data': Uint8List.fromList(utf8.encode('$command\n')),
      });
      return true;
    }
    final port = _port;
    if (!_connected || port == null) return false;
    try {
      final data = Uint8List.fromList(utf8.encode('$command\n'));
      final written = port.write(data);
      debugPrint('[esp32] tx $command ($written/${data.length} bytes)');
      if (written != data.length) {
        _error = 'Serial write incomplete: $written/${data.length} bytes';
        notifyListeners();
        return false;
      }
      return true;
    } catch (e) {
      _error = 'Serial write error: $e';
      notifyListeners();
      return false;
    }
  }

  void _startHandshake() {
    _handshakeTimer?.cancel();
    _handshakeAttempts = 0;
    void sendHandshake(Timer timer) {
      if (!_connected || _deviceReady || _handshakeAttempts >= 8) {
        timer.cancel();
        _handshakeTimer = null;
        if (_connected && !_deviceReady) {
          _error = _transport == Esp32Transport.bluetooth
              ? 'Bluetooth linked, but ESP32 did not answer PING/STATUS. Check firmware is BT build.'
              : 'USB opened, but ESP32 did not answer PING/STATUS.';
          notifyListeners();
        }
        return;
      }
      _handshakeAttempts++;
      debugPrint('[esp32] tx handshake #$_handshakeAttempts via $_transport');
      sendCommand('PING');
      sendCommand('STATUS');
    }

    if (_connected) {
      _handshakeAttempts++;
      debugPrint('[esp32] tx handshake #$_handshakeAttempts via $_transport');
      sendCommand('PING');
      sendCommand('STATUS');
    }
    _handshakeTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      sendHandshake,
    );
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null || !hasListeners) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _reconnectTimer = null;
      if (!_connected && hasListeners) connect();
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _cancelSimulation();
    await _closeBluetooth(silent: false);
    await _closeUsb(silent: false);
    _connected = false;
    _deviceReady = false;
    _transport = Esp32Transport.none;
    _menuTokensSeen = false;
    _lineBuf.clear();
    _portName = '';
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
