import 'dart:io';

import 'package:flutter/foundation.dart';

import 'host_info.dart';
import 'server_finder.dart';
import 'server_process.dart';
import 'updater.dart';

/// Wires the logic pieces together and hands the panel an interface.
class LauncherController extends ChangeNotifier {
  LauncherController() {
    _proc.logs.listen((l) {
      logLines.add(l);
      notifyListeners();
    });
    _proc.status.listen((s) {
      status = s;
      notifyListeners();
    });
    _proc.health.listen((h) {
      health = h;
      notifyListeners();
    });
  }

  final ServerProcess _proc = ServerProcess();
  final List<String> logLines = [];

  /// Repo config lives beside the exe so it survives launcher updates.
  final Updater updater = Updater(
    File('${File(Platform.resolvedExecutable).parent.path}\\launcher.json'),
  );

  ServerLocation? location;
  ServerStatus status = ServerStatus.stopped;
  Map<String, dynamic>? health;
  String lanIp = '';
  bool searching = false;

  UpdateCheck? update;
  bool checkingUpdate = false;
  bool updating = false;

  bool get canStart =>
      location != null && location!.hasPython && status == ServerStatus.stopped;

  Future<void> init() async {
    lanIp = await HostInfo.lanIp();
    notifyListeners();
    await updater.loadConfig();
    await detect();
    await checkUpdate();
  }

  Future<void> detect() async {
    searching = true;
    notifyListeners();
    final found = await ServerFinder.find();
    if (found != null &&
        found.serverDir != location?.serverDir &&
        status != ServerStatus.stopped) {
      // A different directory while the server runs would orphan the process;
      // surface the swap in the console instead of applying it silently.
      logLines.add('! server dir changed to ${found.serverDir} — applies on next start');
    }
    location = found;
    searching = false;
    notifyListeners();
  }

  Future<void> useManualPath(String path) async {
    searching = true;
    notifyListeners();
    location = await ServerFinder.validate(path);
    searching = false;
    if (location == null) {
      logLines.add('✗ "$path" is not an XSIGHT server dir (needs main.py + app/main.py)');
    }
    notifyListeners();
  }

  Future<void> checkUpdate() async {
    final loc = location;
    if (loc == null || updater.config == null) {
      update = null;
      notifyListeners();
      return;
    }
    checkingUpdate = true;
    notifyListeners();
    update = await updater.check(loc.serverDir);
    checkingUpdate = false;
    notifyListeners();
  }

  /// One click: stop the server if it runs, merge the latest code, restart
  /// it if it was running. Local data (`.env`, DB, models) survives — see
  /// [Updater.apply].
  Future<void> applyUpdate() async {
    final loc = location;
    if (loc == null || updating) return;
    updating = true;
    final wasRunning = status == ServerStatus.running;
    notifyListeners();
    try {
      if (status != ServerStatus.stopped) await _proc.stop();
      final sha = await updater.apply(loc.serverDir, onProgress: logLines.add);
      logLines.add('✓ now at ${sha.length > 12 ? sha.substring(0, 12) : sha}');
      update = await updater.check(loc.serverDir);
      if (wasRunning) await start();
    } catch (e) {
      logLines.add('✗ update failed: $e');
    } finally {
      updating = false;
      notifyListeners();
    }
  }

  Future<void> setRepo(String slugAndBranch) async {
    // Accept `owner/name`, `owner/name@branch`, or a full GitHub URL.
    var s = slugAndBranch.trim().replaceFirst(RegExp(r'^https?://github\.com/'), '');
    s = s.replaceFirst(RegExp(r'\.git$'), '').replaceFirst(RegExp(r'/tree/'), '@');
    final branch = s.contains('@') ? s.split('@').last : 'main';
    final slug = s.split('@').first;
    final parts = slug.split('/');
    if (parts.length < 2) {
      logLines.add('✗ "$slugAndBranch" is not owner/name — nothing saved');
      notifyListeners();
      return;
    }
    await updater.saveConfig(RepoConfig(owner: parts[0], name: parts[1], branch: branch));
    logLines.add('✓ updates from ${parts[0]}/${parts[1]}@$branch');
    await checkUpdate();
  }

  Future<void> start() async {
    final loc = location;
    if (loc == null || !loc.hasPython) return;
    logLines.clear();
    await _proc.start(pythonPath: loc.pythonPath!, serverDir: loc.serverDir);
  }

  Future<void> stop() => _proc.stop();

  @override
  void dispose() {
    _proc.dispose();
    super.dispose();
  }
}
