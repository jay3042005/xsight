import 'package:flutter/material.dart';

import '../core/design.dart';
import '../logic/launcher_controller.dart';
import '../logic/server_finder.dart';
import '../logic/server_process.dart';

/// The launcher's single screen: status card, actions, server facts, and a
/// live console. Same visual family as the kiosk — dark surface, mint type,
/// soft-glow cards — but a back-of-house tool, so information density beats
/// arm's-length legibility here.
class LauncherPanel extends StatefulWidget {
  const LauncherPanel({super.key});

  @override
  State<LauncherPanel> createState() => _LauncherPanelState();
}

class _LauncherPanelState extends State<LauncherPanel> {
  final LauncherController _c = LauncherController();
  final _scroll = ScrollController();
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
    _c.init().then((_) => _maybePromptUpdate());
  }

  /// The "opening the server shows a prompt if there's an update" behaviour:
  /// after the startup check resolves, offer the update once. Declining is
  /// silent — the banner in the status card stays for the whole session.
  Future<void> _maybePromptUpdate() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final u = _c.update;
    if (u == null || !(u.available || u.unknownLocal)) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: XS.surfaceRaised,
        title: const Text('Server update available'),
        content: Text(
          u.available
              ? 'A newer version of the XSIGHT server is on GitHub.\n\n'
                  'Update now? Local data (settings, records, models) is kept.'
              : 'This server was installed before update tracking, so its '
                  'version is unknown.\n\nSync it to the latest code now?',
          style: const TextStyle(color: XS.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'later'),
            child: const Text('LATER', style: TextStyle(color: XS.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: XS.highlight),
            onPressed: () => Navigator.pop(context, 'update'),
            child: const Text('UPDATE NOW'),
          ),
        ],
      ),
    );
    if (action == 'update' && mounted) await _c.applyUpdate();
  }

  void _onChanged() {
    setState(() {});
    // Keep the newest log line in view without stealing focus.
    if (_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    // Controller disposal kills the server process tree (see dispose in
    // LauncherController) — closing the launcher window stops the backend.
    _c.removeListener(_onChanged);
    _c.dispose();
    _scroll.dispose();
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = _c.status == ServerStatus.running;
    final starting = _c.status == ServerStatus.starting;

    return Scaffold(
      body: Container(
        color: XS.surface,
        padding: const EdgeInsets.all(XS.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: XS.lg),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: _statusCard(running, starting)),
                  const SizedBox(width: XS.md),
                  Expanded(flex: 6, child: _logCard()),
                ],
              ),
            ),
            const SizedBox(height: XS.md),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: XS.highlight,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: XS.teal.withValues(alpha: 0.4), blurRadius: 16)],
          ),
          child: const Icon(Icons.monitor_heart_outlined, color: XS.mint, size: 22),
        ),
        const SizedBox(width: XS.sm),
        const Text(
          'XSIGHT SERVER LAUNCHER',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.5,
            color: XS.textPrimary,
          ),
        ),
        const Spacer(),
        if (_c.lanIp.isNotEmpty) ...[
          _chip(Icons.lan_outlined, _c.lanIp, XS.sage),
          const SizedBox(width: XS.xs),
        ],
        _chip(Icons.computer_outlined, 'port 8000', XS.sage),
      ],
    );
  }

  Widget _statusCard(bool running, bool starting) {
    final loc = _c.location;
    return Card(
      color: XS.surfaceRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(XS.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statusBadge(running, starting),
            const SizedBox(height: XS.lg),
            if (_c.searching)
              const Padding(
                padding: EdgeInsets.all(XS.xl),
                child: Center(child: CircularProgressIndicator(color: XS.sage)),
              )
            else if (loc == null) ...[
              _notFound(),
            ] else ...[
              _updateBanner(),
              _fact('Server folder', loc.serverDir),
              _fact('Found via', loc.origin),
              _fact(
                'Python',
                loc.hasPython
                    ? '${loc.pythonPath} (${loc.pythonVersion})'
                    : 'NOT FOUND — install Python 3.10+ on PATH',
                alert: !loc.hasPython,
              ),
              const Divider(color: XS.divider, height: XS.xxl),
              if (running) ..._healthFacts() else _urlHint(),
              const Spacer(),
              _actions(running, starting, loc),
            ],
          ],
        ),
      ),
    );
  }

  /// Update state, one line. Kept in the status card (not only the startup
  /// dialog) so a declined update stays visible for the whole session.
  Widget _updateBanner() {
    final u = _c.update;
    if (_c.updating) {
      return _bannerRow(Icons.downloading, 'APPLYING UPDATE…', XS.warn);
    }
    if (u == null) {
      return const SizedBox.shrink();
    }
    if (u.offline) {
      return _bannerRow(Icons.wifi_off_outlined, 'CANNOT REACH GITHUB', XS.textSecondary);
    }
    if (u.repoMissing) {
      return _bannerRow(Icons.search_off, 'GITHUB REPO NOT FOUND', XS.bad);
    }
    if (u.available || u.unknownLocal) {
      return InkWell(
        onTap: _c.applyUpdate,
        borderRadius: BorderRadius.circular(10),
        child: _bannerRow(Icons.system_update_alt, 'UPDATE AVAILABLE — CLICK TO APPLY', XS.ok),
      );
    }
    return _bannerRow(Icons.verified_outlined, 'UP TO DATE', XS.ok);
  }

  Widget _bannerRow(IconData icon, String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: XS.md),
      padding: const EdgeInsets.symmetric(horizontal: XS.sm, vertical: XS.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: XS.xs),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(bool running, bool starting) {
    final (color, label, icon) = switch (_c.status) {
      ServerStatus.running => (XS.ok, 'RUNNING', Icons.check_circle),
      ServerStatus.starting => (XS.warn, 'STARTING…', Icons.hourglass_top),
      ServerStatus.stopped => (XS.bad, 'STOPPED', Icons.stop_circle_outlined),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: XS.md, vertical: XS.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: XS.xs),
          Text(
            starting ? 'STARTING' : label,
            style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _notFound() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: XS.xl),
      child: Text(
        'No XSIGHT server found on this machine.\n\n'
        'Put the xsight folder (with server/ inside it) on the Desktop and '
        'press DETECT, or type the server folder path below.',
        style: TextStyle(color: XS.textSecondary, height: 1.6),
      ),
    );
  }

  List<Widget> _healthFacts() {
    final h = _c.health ?? {};
    String? voice;
    final v = h['voice'];
    if (v is Map) {
      final avail = v['available'];
      voice = (avail == true) ? (v['tts_provider']?.toString() ?? 'ready') : 'unavailable';
    }
    return [
      _fact('Chat provider', '${h['chat_provider'] ?? '?'} · ${h['model'] ?? '?'}'),
      _fact('Vision provider', '${h['vision_provider'] ?? '?'}'),
      if (voice != null) _fact('Voice', voice),
      _fact('Lung model', _shortBackend(h['lung_local'])),
      _fact('X-ray model', _shortBackend(h['xray_local'])),
    ];
  }

  /// `/health` reports the lung/xray backends as dicts whose exact shape has
  /// drifted across versions; reduce to the one fact that matters (which
  /// backend is live) without assuming fields.
  String _shortBackend(Object? v) {
    if (v is Map) {
      final b = v['backend'] ?? v['status'];
      if (b != null) return b.toString();
    }
    return v?.toString() ?? '—';
  }

  Widget _urlHint() {
    final host = _c.lanIp.isEmpty ? 'localhost' : _c.lanIp;
    return Container(
      padding: const EdgeInsets.all(XS.md),
      decoration: BoxDecoration(
        color: XS.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: XS.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'KIOSK POINTS HERE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: XS.textSecondary,
            ),
          ),
          const SizedBox(height: XS.xxs),
          Text(
            'http://$host:8000',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: XS.highlight,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(bool running, bool starting, ServerLocation loc) {
    return Row(
      children: [
        Expanded(
          child: _button(
            label: running || starting ? 'STOP SERVER' : 'START SERVER',
            icon: running || starting ? Icons.stop : Icons.play_arrow,
            color: running || starting ? XS.bad : XS.highlight,
            onTap: running || starting
                ? _c.stop
                : (loc.hasPython ? _c.start : null),
          ),
        ),
      ],
    );
  }

  Widget _button({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: onTap == null ? XS.surface : color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: onTap == null ? XS.divider : color.withValues(alpha: 0.6),
            ),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: onTap == null ? XS.textSecondary : XS.mint, size: 22),
                const SizedBox(width: XS.sm),
                Text(
                  label,
                  style: TextStyle(
                    color: onTap == null ? XS.textSecondary : XS.mint,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _logCard() {
    return Card(
      color: const Color(0xFF1C282E),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(XS.lg, XS.md, XS.lg, XS.xs),
            child: Row(
              children: [
                const Icon(Icons.terminal_outlined, size: 16, color: XS.textSecondary),
                const SizedBox(width: XS.xs),
                const Text(
                  'SERVER CONSOLE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: XS.textSecondary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18, color: XS.textSecondary),
                  tooltip: 'Clear console',
                  onPressed: () => setState(_c.logLines.clear),
                ),
              ],
            ),
          ),
          const Divider(color: XS.divider, height: 1),
          Expanded(
            child: _c.logLines.isEmpty
                ? const Center(
                    child: Text(
                      'no output yet',
                      style: TextStyle(color: XS.textSecondary, fontStyle: FontStyle.italic),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(XS.md),
                    itemCount: _c.logLines.length,
                    itemBuilder: (context, i) => Text(
                      _c.logLines[i],
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12.5,
                        height: 1.5,
                        color: XS.mint,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _manual,
            style: const TextStyle(color: XS.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText:
                  '…or paste the server folder path, e.g. C:\\Users\\you\\Desktop\\xsight\\server',
              hintStyle: const TextStyle(color: XS.textSecondary, fontSize: 12),
              filled: true,
              fillColor: XS.surfaceRaised,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: XS.divider),
              ),
            ),
            onSubmitted: _c.useManualPath,
          ),
        ),
        const SizedBox(width: XS.sm),
        OutlinedButton.icon(
          onPressed: _c.searching ? null : _c.detect,
          icon: const Icon(Icons.travel_explore, size: 18, color: XS.sage),
          label: const Text(
            'DETECT',
            style: TextStyle(color: XS.sage, fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: XS.sage),
            padding: const EdgeInsets.symmetric(horizontal: XS.lg, vertical: XS.md),
          ),
        ),
        const SizedBox(width: XS.sm),
        if (_c.checkingUpdate)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: XS.sage),
          )
        else
          OutlinedButton.icon(
            onPressed: _c.checkUpdate,
            icon: const Icon(Icons.refresh, size: 18, color: XS.sage),
            label: const Text(
              'CHECK UPDATE',
              style: TextStyle(color: XS.sage, fontWeight: FontWeight.w800, letterSpacing: 1),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: XS.sage),
              padding: const EdgeInsets.symmetric(horizontal: XS.lg, vertical: XS.md),
            ),
          ),
      ],
    );
  }

  Widget _fact(String label, String value, {bool alert = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: XS.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: XS.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: alert ? XS.bad : XS.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: XS.sm, vertical: 6),
      decoration: BoxDecoration(
        color: XS.surfaceRaised,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}
