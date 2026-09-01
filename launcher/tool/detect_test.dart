// Empirical check of ServerFinder: one layout per fresh fake HOME, so a
// hit can't be masked by an earlier one.
import 'dart:io';

import 'package:xsight_launcher/logic/server_finder.dart';

void makeServer(String path) {
  Directory(path).createSync(recursive: true);
  File('$path/main.py').writeAsString('# xsight server');
  File('$path/app/main.py').createSync(recursive: true);
}

Future<void> main() async {
  final home = '/tmp/fakehome';
  final layouts = <String, String>{
    'repo folder on Desktop (Desktop/xsight/server)': '$home/Desktop/xsight/server',
    'repo under any name (Desktop/myproject/server)': '$home/Desktop/myproject/server',
    'bare server copy (Desktop/server)': '$home/Desktop/server',
    'repo on Documents (Documents/x/xsight/server)': '$home/Documents/x/xsight/server',
    'one deeper (Desktop/a/b/server)': '$home/Desktop/a/b/server',
    'two deeper (Desktop/a/b/c/server)': '$home/Desktop/a/b/c/server',
    'renamed server dir (Desktop/xsight/backend)': '$home/Desktop/xsight/backend',
    'on Downloads (Downloads/xsight/server)': '$home/Downloads/xsight/server',
  };
  for (final e in layouts.entries) {
    await runOne(home, e.key, e.value);
  }
  // Rejection: a main.py without app/main.py must never match.
  await runOne(home, 'trap: main.py only, no app/ (must MISS)',
      '$home/Desktop/trap', trap: true);
}

Future<void> runOne(String home, String name, String path, {bool trap = false}) async {
  await Directory(home).deleteIfExists();
  if (trap) {
    Directory(path).createSync(recursive: true);
    File('$path/main.py').writeAsString('# not xsight');
  } else {
    makeServer(path);
  }
  final found = await ServerFinder.find();
  final ok = trap ? found == null : found?.serverDir == path;
  print('${ok ? 'PASS' : 'FAIL'}  $name  →  ${found == null ? 'not detected' : found.serverDir}');
}

extension on Directory {
  Future<void> deleteIfExists() async {
    if (await exists()) {
      try {
        await delete(recursive: true);
      } catch (_) {}
    }
  }
}
