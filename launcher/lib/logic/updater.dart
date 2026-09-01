import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Which GitHub repo the updates come from. Persisted beside the exe so a
/// field tech can repoint a kiosk at a fork without a rebuild.
class RepoConfig {
  RepoConfig({required this.owner, required this.name, this.branch = 'main'});

  final String owner;
  final String name;
  final String branch;

  String get slug => '$owner/$name';

  Map<String, dynamic> toJson() => {'owner': owner, 'name': name, 'branch': branch};

  static RepoConfig? fromJson(Map<String, dynamic> j) {
    final owner = j['owner'], name = j['name'];
    if (owner is String && name is String && owner.isNotEmpty && name.isNotEmpty) {
      return RepoConfig(
        owner: owner,
        name: name,
        branch: (j['branch'] as String?) ?? 'main',
      );
    }
    return null;
  }
}

/// Outcome of a check against GitHub.
class UpdateCheck {
  UpdateCheck({
    this.remoteSha,
    this.localSha,
    this.offline = false,
    this.repoMissing = false,
  });

  final String? remoteSha;
  final String? localSha;
  final bool offline;
  final bool repoMissing;

  /// Different SHA locally and remotely — a real update waiting.
  bool get available => remoteSha != null && localSha != null && remoteSha != localSha;

  /// Remote reachable but no local stamp — server predates the updater.
  bool get unknownLocal => remoteSha != null && localSha == null;

  bool get upToDate => remoteSha != null && remoteSha == localSha;
}

/// Checks GitHub for a newer server and applies it in one click.
///
/// Model of operation:
///   - the *commit SHA* of the repo's branch tip is the version number;
///   - the SHA last applied is stamped into `<serverDir>/.update_sha`;
///   - update = download the branch zip, merge its `server/` folder over the
///     local one. Merge (never delete) because the server dir holds
///     untracked payloads that must survive an update: `.env`, the SQLite
///     EMR, and the ML model binaries — none of which are in the repo.
class Updater {
  Updater(this._configFile);

  final File _configFile;
  RepoConfig? _config;

  RepoConfig? get config => _config;

  /// Load the persisted repo config (beside the exe). Null until first save.
  Future<RepoConfig?> loadConfig() async {
    try {
      if (await _configFile.exists()) {
        final j = jsonDecode(await _configFile.readAsString());
        if (j is Map<String, dynamic>) _config = RepoConfig.fromJson(j);
      }
    } catch (_) {}
    return _config;
  }

  Future<void> saveConfig(RepoConfig c) async {
    _config = c;
    await _configFile.writeAsString(jsonEncode(c.toJson()));
  }

  Future<UpdateCheck> check(String serverDir) async {
    final cfg = _config;
    if (cfg == null) return UpdateCheck(repoMissing: true);
    final localSha = await _stamp(serverDir);
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('https://api.github.com/repos/${cfg.slug}/commits/${cfg.branch}'))
          .timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', 'xsight-launcher');
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 404) return UpdateCheck(repoMissing: true, localSha: localSha);
      if (res.statusCode != 200) throw HttpException('GitHub API ${res.statusCode}');
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final sha = body['sha'] as String?;
      if (sha == null) throw const HttpException('no sha in response');
      return UpdateCheck(remoteSha: sha, localSha: localSha);
    } on Exception {
      return UpdateCheck(offline: true, localSha: localSha);
    } finally {
      client.close();
    }
  }

  /// Download and merge the branch zip over the server dir.
  ///
  /// [onProgress] gets human-readable stage text for the console. Returns
  /// the applied SHA (or 'applied' when the archive name carried none).
  Future<String> apply(String serverDir, {void Function(String)? onProgress}) async {
    final cfg = _config;
    if (cfg == null) throw StateError('no repo configured');
    final p = onProgress ?? (_) {};
    final client = HttpClient();
    try {
      p('↓ downloading ${cfg.slug}@${cfg.branch}…');
      final req = await client
          .getUrl(Uri.parse('https://codeload.github.com/${cfg.slug}/zip/refs/heads/${cfg.branch}'))
          .timeout(const Duration(seconds: 15));
      req.headers.set('User-Agent', 'xsight-launcher');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw HttpException('download failed: HTTP ${res.statusCode}');
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      p('  ${bytes.length} bytes received');

      p('· extracting…');
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.isEmpty) throw const HttpException('empty archive');
      // The archive's top folder is `<repo>-<ref>/`.
      final prefix = archive.files.first.name.split('/').first;

      var copied = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final rel = f.name.substring(prefix.length + 1);
        // Only the backend is hot-updatable: the Flutter kiosk and firmware
        // are installed apps, not mergeable source, and the launcher cannot
        // replace a kiosk APK it is not part of.
        if (!rel.startsWith('server/')) continue;
        final target = File('$serverDir\\${rel.substring('server/'.length)}');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(f.content as List<int>);
        copied++;
      }
      p('✓ merged $copied files into $serverDir');

      final sha = _shaFromArchiveName(prefix);
      await File('$serverDir\\.update_sha').writeAsString(sha ?? 'applied ${DateTime.now()}');
      p('✓ update applied');
      return sha ?? 'applied';
    } finally {
      client.close();
    }
  }

  Future<String?> _stamp(String serverDir) async {
    try {
      final f = File('$serverDir\\.update_sha');
      if (await f.exists()) {
        final s = (await f.readAsString()).trim();
        return s.isEmpty ? null : s;
      }
    } catch (_) {}
    return null;
  }

  /// Archive folders look like `xsight-<full40charSha>`; recover the sha.
  String? _shaFromArchiveName(String prefix) {
    final m = RegExp(r'-([0-9a-f]{40})$').firstMatch(prefix);
    return m?.group(1);
  }
}
