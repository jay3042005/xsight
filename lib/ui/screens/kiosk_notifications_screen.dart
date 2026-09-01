import 'package:flutter/material.dart';
import '../../core/api/emr_client.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_spacing.dart';
import '../components/xs_button.dart';

/// Kiosk notifications — alerts, CDSS warnings, system status.
class KioskNotificationsScreen extends StatefulWidget {
  const KioskNotificationsScreen({super.key});
  @override
  State<KioskNotificationsScreen> createState() => _KioskNotificationsScreenState();
}

class _KioskNotificationsScreenState extends State<KioskNotificationsScreen> {
  final EMRClient _emr = EMRClient();
  List<dynamic> _notifications = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _notifications = await _emr.getNotifications();
    } catch (_) {}
    setState(() => _loading = false);
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'critical': return XSColors.accentRed;
      case 'high': return XSColors.accentOrange;
      case 'moderate': return XSColors.accentOrange;
      case 'warning': return XSColors.accentOrange;
      case 'info': return XSColors.accentBlue;
      default: return XSColors.accentGreen;
    }
  }

  IconData _severityIcon(String severity) {
    switch (severity) {
      case 'critical': return Icons.error;
      case 'high': return Icons.warning;
      case 'moderate': return Icons.info;
      case 'warning': return Icons.warning_amber;
      case 'info': return Icons.info_outline;
      default: return Icons.check_circle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = XSPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(XSSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Title lives in the pushing page's app bar.
              Text('Clinical alerts',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: palette.textSecondary)),
              const Spacer(),
              XSButton(icon: Icons.done_all, tooltip: 'Mark All Read', onPressed: () async {
                await _emr.markAllRead();
                _load();
              }),
            ],
          ),
          const SizedBox(height: XSSpacing.md),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _notifications.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.notifications_none, size: 48, color: palette.textSecondary.withValues(alpha: 0.3)),
                            const SizedBox(height: XSSpacing.md),
                            Text('No notifications', style: TextStyle(color: palette.textSecondary)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _notifications.length,
                        itemBuilder: (ctx, i) {
                          final n = _notifications[i];
                          final read = (n['read'] ?? 0) == 1;
                          final color = _severityColor(n['severity'] ?? 'info');
                          return Card(
                            color: read ? null : color.withValues(alpha: 0.05),
                            child: ListTile(
                              leading: Icon(_severityIcon(n['severity'] ?? 'info'), color: color, size: 20),
                              title: Text(n['title'] ?? '',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: read ? FontWeight.w400 : FontWeight.w600)),
                              subtitle: Text(n['message'] ?? '',
                                  style: TextStyle(fontSize: 13, color: palette.textSecondary)),
                              trailing: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 120),
                                child: Text(n['created_at'] ?? '',
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 2,
                                    style: TextStyle(fontSize: 13, color: palette.textSecondary)),
                              ),
                              onTap: () async {
                                if (!read) {
                                  await _emr.markRead(n['id']);
                                  _load();
                                }
                              },
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
