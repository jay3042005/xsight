import 'dart:convert';
import 'dart:io';

/// Host facts for the panel: the LAN address the kiosk should point at, and
/// the machine name.
class HostInfo {
  HostInfo._();

  /// First non-loopback IPv4 of this machine, via each platform's native
  /// tool. Empty string when nothing parsable came back — the UI then shows
  /// only `localhost`, which is still correct for on-machine use.
  static Future<String> lanIp() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('ipconfig', []);
        if (r.exitCode != 0) return '';
        final ips = RegExp(r'IPv4 Address[. ]*:\s*(\d+\.\d+\.\d+\.\d+)')
            .allMatches(r.stdout as String)
            .map((m) => m.group(1)!)
            .where(_isLan);
        return ips.isEmpty ? '' : ips.first;
      }
      // Linux: `ip -json addr` is the modern interface; `hostname -I` is the
      // fallback (and is NOT universal — inetutils hostname rejects -I).
      var r = await Process.run('ip', ['-json', '-4', 'addr', 'show', 'scope', 'global']);
      if (r.exitCode == 0) {
        final addrs = jsonDecode(r.stdout as String) as List<dynamic>;
        for (final iface in addrs) {
          final info = iface['addr_info'] as List<dynamic>?;
          for (final a in info ?? const <dynamic>[]) {
            final ip = a['local'] as String?;
            if (ip != null && _isLan(ip)) return ip;
          }
        }
        return '';
      }
      r = await Process.run('hostname', ['-I']);
      if (r.exitCode != 0) return '';
      final ips = (r.stdout as String)
          .trim()
          .split(RegExp(r'\s+'))
          .where((ip) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip))
          .where(_isLan);
      return ips.isEmpty ? '' : ips.first;
    } catch (_) {
      return '';
    }
  }

  /// Loopback and link-local addresses are not usable by a kiosk on the LAN.
  static bool _isLan(String ip) => !ip.startsWith('127.') && !ip.startsWith('169.254.');

  static String get machineName => Platform.localHostname;
}
