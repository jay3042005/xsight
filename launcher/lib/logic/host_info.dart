import 'dart:io';

/// Host facts for the panel: the LAN address the kiosk should point at, and
/// the machine name.
class HostInfo {
  HostInfo._();

  /// First non-loopback IPv4 of this machine, parsed from `ipconfig` on
  /// Windows. Empty string when nothing parsable came back — the UI then
  /// shows only `localhost`, which is still correct for on-machine use.
  static Future<String> lanIp() async {
    if (!Platform.isWindows) return '';
    try {
      final r = await Process.run('ipconfig', []);
      if (r.exitCode != 0) return '';
      final out = r.stdout as String;
      final ips = RegExp(r'IPv4 Address[. ]*:\s*(\d+\.\d+\.\d+\.\d+)')
          .allMatches(out)
          .map((m) => m.group(1)!)
          .where((ip) => !ip.startsWith('127.') && !ip.startsWith('169.254.'));
      return ips.isEmpty ? '' : ips.first;
    } catch (_) {
      return '';
    }
  }

  static String get machineName => Platform.localHostname;
}
