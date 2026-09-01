import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xsight_app/core/api/server_discovery.dart';

/// A throwaway HTTP server on the loopback interface, so the probe is exercised
/// against real sockets rather than a mock of them — the failure modes that
/// matter here (refused, silent, wrong body) are socket-level.
Future<HttpServer> _serve(
  int status,
  Object? body, {
  String contentType = 'application/json',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.parse(contentType);
    req.response.write(body is String ? body : jsonEncode(body));
    await req.response.close();
  });
  return server;
}

const _xsightHealth = {
  'status': 'ok',
  'ai_configured': true,
  'chat_provider': 'local',
  'model': 'gemini-3-flash',
  'vision_provider': 'local',
  'voice': {'available': false},
  'xray_local': {'available': true, 'arch': 'efficientnet_b0'},
  'lung_local': {'backend': 'torch'},
  'ts': 1.0,
};

void main() {
  group('looksLikeXsight', () {
    test('accepts this backend\'s own health payload', () {
      expect(XSServerDiscovery.looksLikeXsight(_xsightHealth), isTrue);
    });

    test('rejects an unrelated service that also reports status ok', () {
      // The reason the check is not just `status == 'ok'`: adopting any health
      // endpoint on port 8000 would silently point the kiosk at another app.
      expect(
        XSServerDiscovery.looksLikeXsight({'status': 'ok', 'uptime': 42}),
        isFalse,
      );
    });

    test('rejects a backend reporting a problem', () {
      final unhealthy = Map<String, dynamic>.from(_xsightHealth)
        ..['status'] = 'degraded';
      expect(XSServerDiscovery.looksLikeXsight(unhealthy), isFalse);
    });

    test('still accepts a build that drops one marker key', () {
      final partial = Map<String, dynamic>.from(_xsightHealth)
        ..remove('xray_local')
        ..remove('lung_local');
      expect(XSServerDiscovery.looksLikeXsight(partial), isTrue);
    });
  });

  group('probe', () {
    test('finds a real XSIGHT backend and reports what it can do', () async {
      final server = await _serve(200, _xsightHealth);
      addTearDown(() => server.close(force: true));

      final found = await XSServerDiscovery.probe('127.0.0.1', server.port);
      expect(found, isNotNull);
      expect(found!.baseUrl, 'http://127.0.0.1:${server.port}');
      expect(found.port, server.port);
      expect(found.summary, contains('chat: local'));
      expect(found.summary, contains('X-ray model'));
    });

    test('ignores a host serving something else', () async {
      final server = await _serve(200, {'status': 'ok', 'app': 'other'});
      addTearDown(() => server.close(force: true));
      expect(await XSServerDiscovery.probe('127.0.0.1', server.port), isNull);
    });

    test('ignores a non-200 and a non-JSON body', () async {
      final error = await _serve(503, {'detail': 'down'});
      addTearDown(() => error.close(force: true));
      expect(await XSServerDiscovery.probe('127.0.0.1', error.port), isNull);

      final html = await _serve(200, '<html>hello</html>',
          contentType: 'text/html');
      addTearDown(() => html.close(force: true));
      expect(await XSServerDiscovery.probe('127.0.0.1', html.port), isNull);
    });

    test('a closed port fails fast rather than hanging the sweep', () async {
      // Bind and release, so the port is almost certainly unused.
      final probeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probeServer.port;
      await probeServer.close(force: true);

      final started = DateTime.now();
      final found = await XSServerDiscovery.probe(
        '127.0.0.1',
        deadPort,
        connectTimeout: const Duration(milliseconds: 400),
      );
      final elapsed = DateTime.now().difference(started);

      expect(found, isNull);
      // The whole sweep's cost is this multiplied out, so a refused connection
      // must not wait out the timeout.
      expect(elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('scan', () {
    test('a reachable preferred URL is returned before any sweep', () async {
      final server = await _serve(200, _xsightHealth);
      addTearDown(() => server.close(force: true));

      final found = await XSServerDiscovery.findFirst(
        preferred: 'http://127.0.0.1:${server.port}',
        // An empty port list keeps the sweep from running at all, so this only
        // passes if the preferred URL short-circuits it.
        ports: const [],
        overallTimeout: const Duration(seconds: 5),
      );
      expect(found, isNotNull);
      expect(found!.port, server.port);
    });

    test('findFirst gives up rather than hanging when nothing answers',
        () async {
      final found = await XSServerDiscovery.findFirst(
        ports: const [],
        preferred: '',
        overallTimeout: const Duration(seconds: 5),
      );
      expect(found, isNull);
    });
  });

  group('hostOrder', () {
    test('covers every host on the /24 exactly once', () {
      for (final own in [1, 2, 100, 240, 254]) {
        final order = XSServerDiscovery.hostOrder(own);
        expect(order.length, 254, reason: 'own=$own');
        expect(order.toSet().length, 254, reason: 'own=$own has duplicates');
        expect(order.reduce((a, b) => a < b ? a : b), 1);
        expect(order.reduce((a, b) => a > b ? a : b), 254);
      }
    });

    test('probes the device\'s neighbours before the far end of the subnet', () {
      // The point of the ordering: a server on .241 next to a kiosk on .240 used
      // to be the 241st address probed, which cost eight seconds.
      final order = XSServerDiscovery.hostOrder(240);
      expect(order.indexOf(241), lessThan(4));
      expect(order.indexOf(239), lessThan(4));
      expect(order.indexOf(100), greaterThan(order.indexOf(241)));
    });

    test('the device\'s own address is probed first', () {
      // A desktop kiosk runs the backend on the same machine, so its own LAN
      // address is the server's and must resolve immediately.
      expect(XSServerDiscovery.hostOrder(240).first, 240);
      expect(XSServerDiscovery.hostOrder(1).first, 1);
    });

    test('the router address is not left until last', () {
      // .1 is a common place to host things and is maximally distant from a
      // high-numbered device, so pure radial order would probe it last.
      final order = XSServerDiscovery.hostOrder(250);
      expect(order.indexOf(1), lessThan(24));
    });
  });

  group('sweep order', () {
    test('rules out the whole subnet on the default port first', () async {
      // Port-major, not host-major: interleaving 8000 and 8080 doubled the work
      // before the documented default had even been ruled out.
      XSServerDiscovery.localNetworks = () async => [
            const XSLocalNetwork(prefix: '10.9.9.', ownHost: 5),
          ];
      addTearDown(() => XSServerDiscovery.localNetworks =
          XSServerDiscovery.defaultLocalNetworks);

      final probed = <String>[];
      final found = await XSServerDiscovery.findFirst(
        preferred: '',
        ports: const [8000, 8080],
        concurrency: 4,
        connectTimeout: const Duration(milliseconds: 1),
        overallTimeout: const Duration(seconds: 20),
        onProgress: (p, t) => probed.add('$p/$t'),
      );
      expect(found, isNull, reason: '10.9.9.0/24 should hold nothing');
      // 254 hosts x 2 ports.
      expect(probed.last, '508/508');
    });
  });

  test('localPrefixes returns dotted /24 prefixes for this host', () async {
    final prefixes = await XSServerDiscovery.localPrefixes();
    for (final prefix in prefixes) {
      expect(prefix, endsWith('.'));
      expect(prefix.split('.').where((p) => p.isNotEmpty).length, 3,
          reason: '"$prefix" should be the first three octets');
    }
  });
}
