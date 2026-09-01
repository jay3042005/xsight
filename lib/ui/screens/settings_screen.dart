import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_shadows.dart';
import '../../core/theme/xs_spacing.dart';
import '../../state/xs_settings.dart';
import '../components/xs_app_bar.dart';
import '../components/xs_button.dart';
import '../components/xs_card.dart';
import '../components/xs_input_field.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  String? _statusText;
  _StatusKind _statusKind = _StatusKind.idle;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _controller.text = XSSettings.I.backendUrl;
  }

  Future<void> _save() async {
    await XSSettings.I.setBackendUrl(_controller.text);
    if (!mounted) return;
    setState(() {
      _statusText = XSSettings.I.hasBackend
          ? 'Saved: ${XSSettings.I.backendUrl}'
          : 'Cleared (using built-in default)';
      _statusKind = _StatusKind.success;
    });
  }

  Future<void> _reset() async {
    await XSSettings.I.reset();
    if (!mounted) return;
    setState(() {
      _controller.text = XSSettings.I.backendUrl;
      _statusText = 'Reset to default';
      _statusKind = _StatusKind.success;
    });
  }

  Future<void> _ping() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _statusText = 'Enter a server IP first.';
        _statusKind = _StatusKind.error;
      });
      return;
    }
    setState(() {
      _testing = true;
      _statusText = 'Testing...';
      _statusKind = _StatusKind.idle;
    });

    // Save first so the URL gets normalized.
    await XSSettings.I.setBackendUrl(raw);
    final url = XSSettings.I.backendUrl;
    _controller.text = url;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse('$url/health'));
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = await res.transform(utf8.decoder).join();
      if (!mounted) return;
      if (res.statusCode == 200) {
        Map<String, dynamic>? data;
        try {
          data = jsonDecode(body) as Map<String, dynamic>;
        } catch (_) {}
        final ai = data?['ai_configured'] == true;
        final vp = data?['vision_provider'];
        final model = data?['model'];
        setState(() {
          _statusText =
              'Connected — AI: ${ai ? 'configured' : 'mock'}'
              '${model != null ? '\nModel: $model' : ''}'
              '${vp != null ? '\nVision: $vp' : ''}';
          _statusKind = _StatusKind.success;
        });
      } else {
        setState(() {
          _statusText = 'Server replied ${res.statusCode}';
          _statusKind = _StatusKind.error;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Could not reach server.\n$e';
        _statusKind = _StatusKind.error;
      });
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        child: Column(
          children: [
            XSAppBar(
              title: 'Settings',
              leading: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Icon(Icons.arrow_back_ios_new,
                    size: 20, color: palette.textPrimary),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  XSSpacing.lg,
                  XSSpacing.sm,
                  XSSpacing.lg,
                  XSSpacing.xxl,
                ),
                children: [
                  Text('SERVER',
                      style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: XSSpacing.sm),
                  XSCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'XSIGHT Backend Address',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: XSSpacing.xs),
                        Text(
                          'Enter the IP and port of your FastAPI server. '
                          'Examples: 192.168.1.20, 192.168.1.20:8000, '
                          'http://10.0.2.2:8000',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(color: palette.textSecondary),
                        ),
                        const SizedBox(height: XSSpacing.md),
                        XSInputField(
                          controller: _controller,
                          hintText: 'e.g. 192.168.1.20:8000',
                          prefixIcon: Icons.dns_outlined,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _save(),
                        ),
                        const SizedBox(height: XSSpacing.md),
                        Row(
                          children: [
                            Expanded(
                              child: XSButton(
                                label: _testing ? 'Testing...' : 'Test',
                                icon: Icons.wifi_tethering,
                                onPressed: _testing ? null : _ping,
                              ),
                            ),
                            const SizedBox(width: XSSpacing.sm),
                            Expanded(
                              child: XSButton(
                                label: 'Save',
                                inverted: true,
                                icon: Icons.save_outlined,
                                onPressed: _save,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: XSSpacing.sm),
                        TextButton(
                          onPressed: _reset,
                          child: Text(
                            'Reset to default',
                            style:
                                TextStyle(color: palette.textSecondary),
                          ),
                        ),
                        if (_statusText != null) ...[
                          const SizedBox(height: XSSpacing.sm),
                          _StatusBox(text: _statusText!, kind: _statusKind),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: XSSpacing.lg),
                  Text('NOTES',
                      style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: XSSpacing.sm),
                  XSCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Note(
                          title: 'Android emulator',
                          body: 'Use http://10.0.2.2:8000 to reach the host PC.',
                        ),
                        _Divider(palette: palette),
                        _Note(
                          title: 'iOS simulator',
                          body: 'Use http://localhost:8000.',
                        ),
                        _Divider(palette: palette),
                        _Note(
                          title: 'Physical device',
                          body:
                              'Use the LAN IP of your laptop (e.g. 192.168.x.x) '
                              'and make sure both devices are on the same Wi-Fi.',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _StatusKind { idle, success, error }

class _StatusBox extends StatelessWidget {
  final String text;
  final _StatusKind kind;
  const _StatusBox({required this.text, required this.kind});

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    final icon = switch (kind) {
      _StatusKind.success => Icons.check_circle_outline,
      _StatusKind.error => Icons.error_outline,
      _StatusKind.idle => Icons.info_outline,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(XSSpacing.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(XSRadius.md),
        boxShadow: XSShadows.pressed(palette),
        border: Border.all(color: palette.divider, width: 0.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: palette.textPrimary),
          const SizedBox(width: XSSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String title;
  final String body;
  const _Note({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: XSSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontSize: 14)),
          const SizedBox(height: 2),
          Text(body,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: palette.textSecondary)),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final XSPalette palette;
  const _Divider({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.6,
      color: palette.divider,
      margin: const EdgeInsets.symmetric(vertical: XSSpacing.xs),
    );
  }
}
