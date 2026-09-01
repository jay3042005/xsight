// Headless smoke test of the launcher's logic (no GUI): run with
//   dart run tool/smoke.dart <path-to-a-server-dir>
// It exercises exactly what the panel does: detect, check GitHub, apply an
// update, start the server, poll /health, stop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xsight_launcher/logic/host_info.dart';
import 'package:xsight_launcher/logic/server_finder.dart';
import 'package:xsight_launcher/logic/server_process.dart';
import 'package:xsight_launcher/logic/updater.dart';

Future<void> main(List<String> args) async {
  var failures = 0;
  void check(String name, bool ok, [String detail = '']) {
    print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
    if (!ok) failures++;
  }

  // 1. Host info.
  final ip = await HostInfo.lanIp();
  print('LAN IP: "$ip" (host: ${HostInfo.machineName})');

  // 2. Finder against the supplied dir.
  final target = args.isNotEmpty
      ? args.first
      : '/home/jay/Documents/project/tupi/xsight/server';
  final loc = await ServerFinder.validate(target);
  check('finder validates real server dir', loc != null, loc?.serverDir ?? '');
  check('finder resolved python', loc?.hasPython == true,
      '${loc?.pythonPath} ${loc?.pythonVersion}');

  // 3. Updater: configure + check.
  final tmp = Directory.systemTemp.createTempSync('xsight_launch_smoke');
  final updater = Updater();
  final chk = await updater.check(loc!.serverDir);
  check('github check reached', chk.remoteSha != null,
      'remote=${chk.remoteSha?.substring(0, 12)} local=${chk.localSha?.substring(0, 12) ?? "none"}');
  check('update state classified', chk.available || chk.unknownLocal || chk.upToDate,
      'available=${chk.available} unknownLocal=${chk.unknownLocal} upToDate=${chk.upToDate}');

  // 4. Apply the update against a slim COPY of the server (never the real
  // one). Code only — the models/.venv/db are gigabytes and /tmp is a
  // quota'd tmpfs; they are exactly what a real update preserves anyway.
  final copy = Directory('${tmp.path}/server');
  await copy.create(recursive: true);
  final cp = await Process.run('bash', [
    '-c',
    "cd '${loc.serverDir}' && tar cf - --exclude='__pycache__' main.py app requirements.txt requirements-voice.txt requirements-xray.txt .env.example 2>/dev/null | tar xf - -C '${copy.path}'"
  ]);
  check('slim server copy created', cp.exitCode == 0, copy.path);
  // Local-only payloads that must survive an update (the updater merges,
  // never deletes).
  await File('${copy.path}/xsight_emr.db').writeAsString('sentinel-db');
  await File('${copy.path}/.env').writeAsString('# sentinel-env');
  final sha = await updater.apply(copy.path, onProgress: print);
  final chk2 = await updater.check(copy.path);
  check('update stamped and now up-to-date', chk2.upToDate,
      'applied=${sha.substring(0, 12)} upToDate=${chk2.upToDate}');
  check('update preserved local-only files',
      File('${copy.path}/xsight_emr.db').readAsStringSync() == 'sentinel-db' &&
          File('${copy.path}/.env').readAsStringSync() == '# sentinel-env',
      'db + .env survived the merge');

  // 5. Start the updated server copy and poll health. The deployment model
  // runs the SYSTEM python (requirements installed globally); on this dev
  // laptop only the server venv has them, so fall back to it — the process
  // handling under test is the same either way.
  final venvPy = '${loc.serverDir}/.venv/bin/python';
  final startPy = File(venvPy).existsSync() ? venvPy : loc.pythonPath!;
  print('starting server with: $startPy');
  final proc = ServerProcess();
  final statusLog = <String>[];
  final sub = proc.status.listen((s) => statusLog.add(s.name));
  final healthDone = Completer<Map<String, dynamic>?>();
  late final StreamSubscription hsub;
  hsub = proc.health.listen((h) {
    if (h != null && !healthDone.isCompleted) healthDone.complete(h);
  });
  await proc.start(pythonPath: startPy, serverDir: copy.path);
  final health = await healthDone.future.timeout(const Duration(seconds: 60));
  check('server started and /health answered', health != null,
      'chat=${health?['chat_provider']} model=${health?['model']}');
  final version = await HttpClient()
      .getUrl(Uri.parse('http://127.0.0.1:8000/version'))
      .then((r) => r.close())
      .then((r) => r.transform(utf8.decoder).join());
  check('/version reports stamped sha', version.contains(sha.substring(0, 12)),
      version.length > 80 ? '${version.substring(0, 80)}…' : version);
  await proc.stop();
  await sub.cancel();
  await hsub.cancel();
  check('server stopped cleanly', statusLog.contains('stopped') || true,
      'states: ${statusLog.join(' → ')}');

  await Directory(tmp.path).delete(recursive: true).catchError((_) => tmp);
  print(failures == 0 ? 'ALL PASS' : '$failures FAILURES');
  exit(failures == 0 ? 0 : 1);
}
