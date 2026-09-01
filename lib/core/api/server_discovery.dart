import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// An IPv4 /24 this device is attached to.
@immutable
class XSLocalNetwork {
  /// First three octets with the trailing dot, e.g. `192.168.1.`.
  final String prefix;

  /// This device's own last octet on that network.
  final int ownHost;

  const XSLocalNetwork({required this.prefix, required this.ownHost});
}

/// A backend found on the network.
@immutable
class XSServerCandidate {
  /// Base URL, ready to hand to [XSSettings.setBackendUrl].
  final String baseUrl;

  /// Host that answered, for display.
  final String host;
  final int port;

  /// How the server described itself — the `/health` body. Lets the caller show
  /// which providers and models are live before committing to it.
  final Map<String, dynamic> health;

  /// Round-trip time of the probe. The nearest server is usually the right one
  /// when a LAN somehow has two.
  final Duration latency;

  const XSServerCandidate({
    required this.baseUrl,
    required this.host,
    required this.port,
    required this.health,
    required this.latency,
  });

  /// Short description for a picker row: what this server can actually do.
  String get summary {
    final bits = <String>[];
    final chat = health['chat_provider'];
    if (chat is String && chat.isNotEmpty) bits.add('chat: $chat');
    final vision = health['vision_provider'];
    if (vision is String && vision.isNotEmpty) bits.add('vision: $vision');
    if (health['xray_local'] is Map &&
        (health['xray_local'] as Map)['available'] == true) {
      bits.add('X-ray model');
    }
    return bits.isEmpty ? 'XSIGHT backend' : bits.join('  ·  ');
  }

  @override
  String toString() => 'XSServerCandidate($baseUrl, ${latency.inMilliseconds}ms)';
}

/// Finds the XSIGHT backend on the local network.
///
/// The kiosk's server address is the one setting a walk-up operator cannot guess:
/// it changes with the venue's DHCP, and typing it needs a keyboard the kiosk
/// deliberately does not have. This sweeps the device's own /24 for something
/// that answers `/health` like an XSIGHT server.
///
/// Cheap because it never waits on unreachable hosts: the probe's
/// [HttpClient.connectionTimeout] is what bounds the scan, and a silent address
/// fails in that window rather than at the request timeout. A /24 at
/// [concurrency] 24 and a 400 ms connect timeout settles in a few seconds.
class XSServerDiscovery {
  XSServerDiscovery._();

  /// Ports worth trying, in order. 8000 is the documented default.
  static const defaultPorts = <int>[8000, 8080];

  /// How many probes are in flight at once.
  ///
  /// Held well below the /24 size on purpose: Android caps a process's open
  /// sockets, and firing 254 connects at once gets some of them refused by the
  /// platform rather than by the host — which reads as "not found" for a server
  /// that was there.
  static const defaultConcurrency = 24;

  /// A host is only accepted when it answers like *this* product.
  ///
  /// `status: ok` alone would latch onto any unrelated service that happens to
  /// serve a health endpoint on the same port, and silently point the kiosk at it.
  @visibleForTesting
  static bool looksLikeXsight(Map<String, dynamic> body) {
    if (body['status'] != 'ok') return false;
    // Keys only this backend's /health reports. Two of three, so a version that
    // drops one field is still recognised.
    final markers = [
      body.containsKey('chat_provider'),
      body.containsKey('vision_provider'),
      body.containsKey('xray_local') || body.containsKey('lung_local'),
    ].where((e) => e).length;
    return markers >= 2;
  }

  /// The device's own IPv4 /24 prefixes, e.g. `192.168.1.`.
  ///
  /// Assumes a /24, which is what home and clinic routers hand out. A wider mask
  /// would need a sweep too large to run from a tablet, and a narrower one is a
  /// subset of what this covers.
  static Future<List<String>> localPrefixes() async =>
      [for (final net in await localNetworks()) net.prefix];

  /// The IPv4 /24s this device sits on, and where in each the device itself is.
  ///
  /// Indirected through a field so a test can substitute a network without
  /// depending on whatever the host machine happens to be attached to.
  static Future<List<XSLocalNetwork>> Function() localNetworks = _localNetworks;

  /// The real implementation, for a test to restore after substituting one.
  static Future<List<XSLocalNetwork>> Function() get defaultLocalNetworks =>
      _localNetworks;

  static Future<List<XSLocalNetwork>> _localNetworks() async {
    final out = <XSLocalNetwork>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
          final own = int.tryParse(parts[3]) ?? 1;
          if (out.every((n) => n.prefix != prefix)) {
            out.add(XSLocalNetwork(prefix: prefix, ownHost: own));
          }
        }
      }
    } catch (e) {
      debugPrint('[discovery] interface list failed: $e');
    }
    return out;
  }

  /// Host octets to sweep, nearest the device's own address first.
  ///
  /// A kiosk and its server take DHCP leases from the same pool at around the
  /// same time, so their addresses are usually numerically close. Sweeping
  /// 1..254 blindly found a server on .240 only after 240 probes; radiating
  /// outwards from the device's own octet finds it in a handful.
  @visibleForTesting
  static List<int> hostOrder(int ownHost) {
    // The device's own address first: on a desktop kiosk the backend runs on the
    // same machine, so its LAN address *is* the server's. Omitting it made the
    // one setup that should resolve instantly the one that never resolved.
    final out = <int>[if (ownHost >= 1 && ownHost <= 254) ownHost];
    for (var d = 1; d <= 254 && out.length < 254; d++) {
      for (final h in [ownHost - d, ownHost + d]) {
        if (h >= 1 && h <= 254 && !out.contains(h)) out.add(h);
      }
    }
    // The router is a common place to host things, and .1 is maximally distant
    // from a high-numbered device, so pure radial order would probe it last.
    // Only promote it when it is not already early — unconditionally moving it
    // pushed .1 off the front for a device that *is* .1.
    const earlyWindow = 16;
    final at = out.indexOf(1);
    if (at > earlyWindow) {
      out.removeAt(at);
      out.insert(earlyWindow, 1);
    }
    return out;
  }

  /// Probe one address. Returns null for anything that is not an XSIGHT backend.
  static Future<XSServerCandidate?> probe(
    String host,
    int port, {
    Duration connectTimeout = const Duration(milliseconds: 400),
    Duration readTimeout = const Duration(milliseconds: 900),
  }) async {
    final started = DateTime.now();
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final req = await client
          .getUrl(Uri.parse('http://$host:$port/health'))
          .timeout(connectTimeout);
      final resp = await req.close().timeout(readTimeout);
      if (resp.statusCode != 200) return null;
      final text = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(readTimeout);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic> || !looksLikeXsight(decoded)) {
        return null;
      }
      return XSServerCandidate(
        baseUrl: 'http://$host:$port',
        host: host,
        port: port,
        health: decoded,
        latency: DateTime.now().difference(started),
      );
    } catch (_) {
      // Unreachable, refused, timed out, or not JSON — all "not here".
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Sweep the local network, emitting each backend as it is found.
  ///
  /// [onProgress] reports (probed, total) so a kiosk screen can show a bar rather
  /// than an indeterminate spinner on a scan that takes seconds.
  ///
  /// [preferred] is tried first and, when it answers, is emitted before any sweep
  /// begins — a kiosk whose address has not actually changed should not pay for a
  /// scan to find that out.
  static Stream<XSServerCandidate> scan({
    List<int> ports = defaultPorts,
    int concurrency = defaultConcurrency,
    Duration connectTimeout = const Duration(milliseconds: 400),
    String? preferred,
    void Function(int probed, int total)? onProgress,
  }) {
    final controller = StreamController<XSServerCandidate>();

    Future<void> run() async {
      final seen = <String>{};

      Future<bool> emit(XSServerCandidate? found) async {
        if (found == null || controller.isClosed) return false;
        if (!seen.add(found.baseUrl)) return false;
        controller.add(found);
        return true;
      }

      if (preferred != null && preferred.isNotEmpty) {
        final uri = Uri.tryParse(preferred);
        if (uri != null && uri.host.isNotEmpty) {
          await emit(await probe(
            uri.host,
            uri.hasPort ? uri.port : ports.first,
            connectTimeout: connectTimeout,
          ));
        }
      }

      final networks = await localNetworks();
      final targets = <(String, int)>[
        // Port-major: 8000 is the documented default, so rule the whole subnet
        // out on it before spending a second pass on the alternates.
        for (final port in ports)
          for (final net in networks)
            for (final host in hostOrder(net.ownHost)) ('${net.prefix}$host', port),
      ];

      var probed = 0;
      onProgress?.call(0, targets.length);

      for (var i = 0; i < targets.length; i += concurrency) {
        if (controller.isClosed) break;
        final batch = targets.skip(i).take(concurrency);
        final results = await Future.wait(
          batch.map((t) => probe(t.$1, t.$2, connectTimeout: connectTimeout)),
        );
        for (final found in results) {
          await emit(found);
        }
        probed += results.length;
        onProgress?.call(probed, targets.length);
      }

      if (!controller.isClosed) await controller.close();
    }

    controller.onListen = run;
    return controller.stream;
  }

  /// The first backend found, or null when the sweep finds none.
  ///
  /// Stops as soon as something answers, so the common case — a server on a low
  /// address — returns long before the /24 is exhausted.
  static Future<XSServerCandidate?> findFirst({
    List<int> ports = defaultPorts,
    int concurrency = defaultConcurrency,
    Duration connectTimeout = const Duration(milliseconds: 400),
    String? preferred,
    Duration overallTimeout = const Duration(seconds: 25),
    void Function(int probed, int total)? onProgress,
  }) async {
    try {
      return await scan(
        ports: ports,
        concurrency: concurrency,
        connectTimeout: connectTimeout,
        preferred: preferred,
        onProgress: onProgress,
      ).first.timeout(overallTimeout);
    } on TimeoutException {
      return null;
    } on StateError {
      return null;   // stream closed with nothing found
    }
  }
}
