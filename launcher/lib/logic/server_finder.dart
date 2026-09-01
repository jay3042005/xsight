import 'dart:io';

/// Result of scanning the machine for the XSIGHT server.
class ServerLocation {
  ServerLocation({
    required this.serverDir,
    required this.origin,
    this.pythonPath,
    this.pythonVersion,
  });

  /// Absolute path of the directory containing `main.py` (the server dir,
  /// e.g. `...\xsight\server`).
  final String serverDir;

  /// How it was found — shown in the UI so the user can tell an auto-detect
  /// hit from a manual paste.
  final String origin;

  /// Resolved python interpreter. Null when none was found.
  String? pythonPath;
  String? pythonVersion;

  bool get hasPython => pythonPath != null;
}

/// Finds the XSIGHT backend on this machine, Windows-style.
///
/// The signature of the server directory is `main.py` **and** `app/main.py`
/// — plenty of projects have a `main.py`, and starting the wrong one would
/// open a console that dies instantly and confuse the log panel with a
/// traceback nobody asked for.
class ServerFinder {
  /// Directories whose children (and grandchildren) are scanned. Ordered by
  /// priority: beside-the-exe first (a launcher shipped inside the repo
  /// should win), then the Desktop — "the server lives on the home desktop"
  /// — then Documents, then fixed fallbacks.
  static List<String> get _roots {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final roots = <String>[
      exeDir,
      if (home.isNotEmpty) ...[
        '$home\\Desktop',
        '$home\\OneDrive\\Desktop',
        '$home\\Documents',
        '$home\\OneDrive\\Documents',
        home,
      ],
      'C:\\XSIGHT',
      'C:\\build\\xsight',
    ];
    // De-dup while keeping order.
    return roots.where((r) => r.isNotEmpty).toSet().toList();
  }

  /// Names a hit folder may carry. The server dir is usually `server` inside
  /// a repo checkout, but a user may have copied just the server out.
  static const _dirNames = ['server', 'xsight', 'XSIGHT'];

  /// Scan all roots. Returns null when nothing matched.
  static Future<ServerLocation?> find() async {
    for (final root in _roots) {
      final rootDir = Directory(root);
      if (!await rootDir.exists()) continue;

      // 1. The root itself (Desktop\server, a repo copied straight out…).
      final direct = await _isServerDir(rootDir);
      if (direct != null) {
        return await _withPython(direct, root);
      }

      // 2. Children, two patterns each:
      //    <root>\server            — bare server copy
      //    <root>\<anything>\server — repo checkout under any folder name
      // Depth is capped at 2 so a Desktop littered with folders stays fast.
      for (final name in _dirNames) {
        final hit = await _isServerDir(Directory('$root\\$name'));
        if (hit != null) return await _withPython(hit, '$root\\$name');
      }
      try {
        final children = rootDir.listSync(followLinks: false).whereType<Directory>();
        for (final child in children) {
          for (final name in _dirNames) {
            final hit = await _isServerDir(Directory('${child.path}\\$name'));
            if (hit != null) return await _withPython(hit, '${child.path}\\$name');
          }
        }
      } on FileSystemException {
        // Permission-denied on some system folder — keep scanning.
      }
    }
    return null;
  }

  /// Validate a user-supplied path the same way auto-detect validates its
  /// hits, so a pasted path gets the same guarantees.
  static Future<ServerLocation?> validate(String path) async {
    final hit = await _isServerDir(Directory(path));
    if (hit == null) return null;
    return _withPython(hit, 'manual path');
  }

  static Future<String?> _isServerDir(Directory dir) async {
    try {
      final main = File('${dir.path}\\main.py');
      final appMain = File('${dir.path}\\app\\main.py');
      if (await main.exists() && await appMain.exists()) return dir.path;
    } on FileSystemException {
      // Not a directory / unreadable — not a hit.
    }
    return null;
  }

  /// Attach a python interpreter to a located server.
  ///
  /// System Python only, per the deployment model: no `.venv` probing, no
  /// bundling — the machine is expected to have one interpreter with the
  /// requirements already installed.
  static Future<ServerLocation> _withPython(String dir, String origin) async {
    final loc = ServerLocation(serverDir: dir, origin: origin);
    for (final candidate in await _pythonCandidates()) {
      try {
        final v = await Process.run(candidate, ['--version']);
        if (v.exitCode == 0) {
          loc.pythonPath = candidate;
          loc.pythonVersion = (v.stdout as String).trim().replaceAll('Python ', '');
          break;
        }
      } on ProcessException {
        // Candidate doesn't exist / isn't runnable — next.
      }
    }
    return loc;
  }

  static Future<List<String>> _pythonCandidates() async {
    final home = Platform.environment['USERPROFILE'] ?? '';
    final candidates = <String>[
      'python.exe',
      'py.exe', // py launcher — invoked as `py main.py` below
    ];
    // Fixed install locations beat whatever `where.exe` finds first when
    // several interpreters live on PATH (e.g. the Microsoft Store shim,
    // which exists but cannot run anything).
    for (final d in [
      'C:\\Program Files\\Python313',
      'C:\\Program Files\\Python312',
      'C:\\Program Files\\Python311',
      'C:\\Program Files\\Python310',
      if (home.isNotEmpty) '$home\\AppData\\Local\\Programs\\Python\\Python313',
      if (home.isNotEmpty) '$home\\AppData\\Local\\Programs\\Python\\Python312',
      if (home.isNotEmpty) '$home\\AppData\\Local\\Programs\\Python\\Python311',
    ]) {
      candidates.insert(0, '$d\\python.exe');
    }
    return candidates;
  }
}
