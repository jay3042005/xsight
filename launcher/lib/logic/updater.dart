import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// The one repo this launcher updates from. Hardcoded per product decision —
/// the kiosk operator should never be asked where the server comes from;
/// repointing at a fork is a rebuild, not a field option.
final RepoConfig kRepo = RepoConfig(
  owner: 'jay3042005',
  name: 'xsight',
  branch: 'main',
);

/// Which GitHub repo the updates come from.
class RepoConfig {
  RepoConfig({required this.owner, required this.name, this.branch = 'main'});

  final String owner;
  final String name;
  final String branch;

  String get slug => '$owner/$name';
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
  final RepoConfig config = kRepo;

  Future<UpdateCheck> check(String serverDir) async {
    final cfg = config;
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
  /// the applied SHA.
  Future<String> apply(String serverDir, {void Function(String)? onProgress}) async {
    final cfg = config;
    final p = onProgress ?? (_) {};
    final client = HttpClient();
    try {
      // Pin the download to the commit SHA, not the branch name: the branch
      // tip can move between the check and this download, and the archive's
      // top folder name (`repo-<ref>`) is where the stamp SHA comes from —
      // a branch zip would stamp "main", which never matches and would read
      // as an update forever.
      final remoteSha = await _latestSha(client, cfg);
      p('↓ downloading ${cfg.slug} @ ${remoteSha.substring(0, 12)}…');
      final req = await client
          .getUrl(Uri.parse('https://codeload.github.com/${cfg.slug}/zip/$remoteSha'))
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
      // The archive's top folder is `<repo>-<sha>/`.
      final prefix = archive.files.first.name.split('/').first;

      var copied = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final rel = f.name.substring(prefix.length + 1);
        // Only the backend is hot-updatable: the Flutter kiosk and firmware
        // are installed apps, not mergeable source, and the launcher cannot
        // replace a kiosk APK it is not part of.
        if (!rel.startsWith('server/')) continue;
        final target = File('$serverDir${Platform.pathSeparator}${rel.substring('server/'.length)}');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(f.content as List<int>);
        copied++;
      }
      p('✓ merged $copied files into $serverDir');

      await File(_stampPath(serverDir)).writeAsString(remoteSha);
      p('✓ update applied');
      return remoteSha;
    } finally {
      client.close();
    }
  }

  Future<String> _latestSha(HttpClient client, RepoConfig cfg) async {
    final req = await client
        .getUrl(Uri.parse('https://api.github.com/repos/${cfg.slug}/commits/${cfg.branch}'))
        .timeout(const Duration(seconds: 10));
    req.headers.set('User-Agent', 'xsight-launcher');
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw HttpException('GitHub API ${res.statusCode}');
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final sha = body['sha'] as String?;
    if (sha == null) throw const HttpException('no sha in response');
    return sha;
  }

  static String _stampPath(String serverDir) =>
      '$serverDir${Platform.pathSeparator}.update_sha';

  Future<String?> _stamp(String serverDir) async {
    try {
      final f = File(_stampPath(serverDir));
      if (await f.exists()) {
        final s = (await f.readAsString()).trim();
        return s.isEmpty ? null : s;
      }
    } catch (_) {}
    return null;
  }
}
