import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Owns the server child process: start, live log capture, health polling,
/// and a Windows process-tree kill.
///
/// The server is started exactly the way a developer would start it —
/// `python main.py` with the server directory as CWD (it loads `server/.env`
/// relative to CWD before importing the app). No venv, no bundling: the
/// launcher is a trigger, not a package.
class ServerProcess {
  Process? _process;
  Timer? _healthTimer;
  bool _exited = true;
  final int _port = 8000;

  final _logLines = <String>[];
  final _logController = StreamController<String>.broadcast();
  final _statusController = StreamController<ServerStatus>.broadcast();
  final _healthController = StreamController<Map<String, dynamic>?>.broadcast();

  /// New log lines (stdout + stderr merged, prefixed).
  Stream<String> get logs => _logController.stream;

  /// Lifecycle transitions.
  Stream<ServerStatus> get status => _statusController.stream;

  /// Latest `/health` payload, or null while unreachable. Null is also the
  /// stopped state, so the UI treats "process up, health null" as STARTING.
  Stream<Map<String, dynamic>?> get health => _healthController.stream;

  ServerStatus _state = ServerStatus.stopped;
  ServerStatus get state => _state;

  static const _maxLogLines = 500;

  void _setState(ServerStatus s) {
    if (_state == s) return;
    _state = s;
    _statusController.add(s);
  }

  void _log(String line) {
    _logLines.add(line);
    if (_logLines.length > _maxLogLines) _logLines.removeAt(0);
    _logController.add(line);
  }

  /// Start the server. [pythonPath] may be `python.exe` / `py.exe` style —
  /// anything Process.start can resolve.
  Future<void> start({required String pythonPath, required String serverDir}) async {
    if (_state == ServerStatus.starting || _state == ServerStatus.running) return;

    _setState(ServerStatus.starting);
    _log('→ $pythonPath main.py');
    _log('  cwd: $serverDir');

    try {
      _process = await Process.start(
        pythonPath,
        ['main.py'],
        workingDirectory: serverDir,
      );
    } catch (e) {
      _log('✗ failed to start: $e');
      _setState(ServerStatus.stopped);
      return;
    }

    _log('✓ process started (pid ${_process!.pid})');
    _exited = false;

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log);
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log);

    // The authoritative exit signal. Exit of the *process*, not of either
    // stream — a stream closing early (a crashed worker) must not be read
    // as the server being down.
    unawaited(_process!.exitCode.then((code) {
      _exited = true;
      _log('✗ process exited (code $code)');
      _healthTimer?.cancel();
      _healthController.add(null);
      _setState(ServerStatus.stopped);
    }));

    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollHealth());
  }

  /// Kill the whole tree. `taskkill /T /F` on Windows because the server may
  /// have its own children (uvicorn workers); a bare kill would orphan them.
  Future<void> stop() async {
    final p = _process;
    if (p == null) {
      _setState(ServerStatus.stopped);
      return;
    }
    _log('→ stopping (pid ${p.pid})…');
    _healthTimer?.cancel();
    _healthController.add(null);
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${p.pid}', '/T', '/F']);
      } else {
        p.kill();
      }
    } catch (e) {
      _log('  taskkill failed ($e) — killing directly');
      p.kill();
    }
    await p.exitCode;
    _log('✓ stopped');
  }

  Future<void> _pollHealth() async {
    Map<String, dynamic>? payload;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$_port/health'))
          .timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        payload = jsonDecode(body) as Map<String, dynamic>;
      }
      client.close();
    } catch (_) {
      // Unreachable is a normal transient state while the server boots.
    }
    _healthController.add(payload);
    if (payload != null) {
      _setState(ServerStatus.running);
    } else if (_state != ServerStatus.stopped) {
      // Process alive but no health answer yet: still booting. The exitCode
      // future resolves (and flips state itself) if it died instead.
      _setState(_exited ? ServerStatus.stopped : ServerStatus.starting);
    }
  }

  void dispose() {
    _healthTimer?.cancel();
    _process?.kill();
    _logController.close();
    _statusController.close();
    _healthController.close();
  }
}

enum ServerStatus { stopped, starting, running }
