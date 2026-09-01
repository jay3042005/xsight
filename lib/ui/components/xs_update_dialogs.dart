import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/updates_client.dart';
import '../../core/sensor/esp32_serial_client.dart';
import '../../core/sensor/firmware_ota.dart';
import '../../core/theme/xs_colors.dart';
import '../../core/theme/xs_radius.dart';
import '../../core/theme/xs_spacing.dart';

/// The update popups: a firmware offer (with live flash progress) and the
/// server-code notice. Shown by the shell when [UpdateCheckService] fires.
///
/// Deliberately plain dialogs, not screens: they are interruptions, and the
/// kiosk's navigation is hardware-owned — a route the shell did not push
/// would strand the ESP32's BACK button.
class XSUpdateDialogs {
  XSUpdateDialogs._();

  /// "Your hub firmware is behind — flash it now?" with progress while it
  /// streams. Returns true if the hub was flashed (it reboots itself).
  static Future<bool> showFirmware(
    BuildContext context, {
    required String current,
    required String expected,
    required Esp32SerialClient esp32,
    required UpdatesClient updates,
  }) async {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: XSColors.slate,
        title: const Text('Hub update available'),
        content: Text(
          'The sensor hub is running firmware $current;\n'
          'the current version is $expected.\n\n'
          'Update it now? Takes a few minutes over the '
          'existing cable — do not unplug the hub.',
          style: const TextStyle(color: XSColors.mint, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('LATER', style: TextStyle(color: XSColors.sage)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: XSColors.teal),
            onPressed: () => Navigator.pop(ctx, 'update'),
            child: const Text('UPDATE NOW'),
          ),
        ],
      ),
    );

    if (action != 'update' || !context.mounted) return false;
    return _flash(context, esp32, updates);
  }

  /// Live state for the progress dialog. Notifiers, not setState: the
  /// transfer runs outside the widget tree, and the dialog must reflect it
  /// every chunk without rebuilding anything else.
  static Future<bool> _flash(
    BuildContext context,
    Esp32SerialClient esp32,
    UpdatesClient updates,
  ) async {
    final ota = FirmwareOta(esp32, updates);
    final progress = ValueNotifier<double>(0);
    final phase = ValueNotifier<_FlashPhase>(_FlashPhase.flashing);
    final message = ValueNotifier<String?>(null);

    unawaited(
      ota.run(onProgress: (p) => progress.value = p).then((_) {
        phase.value = _FlashPhase.done;
      }).catchError((e) {
        message.value = e.toString();
        phase.value = _FlashPhase.failed;
      }),
    );

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<_FlashPhase>(
        valueListenable: phase,
        builder: (context, ph, _) => AlertDialog(
          backgroundColor: XSColors.slate,
          title: Text(switch (ph) {
            _FlashPhase.flashing => 'Updating hub…',
            _FlashPhase.done => 'Hub updated',
            _FlashPhase.failed => 'Update failed',
          }),
          content: ph == _FlashPhase.failed
              ? Text(
                  '${message.value}\n\nThe hub was not modified — it still '
                  'runs its previous firmware.',
                  style: const TextStyle(color: XSColors.sage, height: 1.5),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: progress,
                      builder: (context, p, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(
                            value: ph == _FlashPhase.done ? 1 : p,
                            backgroundColor: XSColors.tealDark,
                            valueColor:
                                const AlwaysStoppedAnimation(XSColors.teal),
                            minHeight: 8,
                            borderRadius: BorderRadius.circular(XSRadius.sm),
                          ),
                          const SizedBox(height: XSSpacing.sm),
                          Text(
                            ph == _FlashPhase.done
                                ? 'The hub is rebooting into the new firmware.'
                                : '${(p * 100).round()}% — keep the cable plugged in.',
                            style: const TextStyle(color: XSColors.sage),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
          actions: [
            if (ph == _FlashPhase.flashing)
              TextButton(
                onPressed: () {
                  ota.abort();
                  Navigator.pop(context, false);
                },
                child: const Text('CANCEL', style: TextStyle(color: XSColors.sage)),
              ),
            if (ph != _FlashPhase.flashing)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: XSColors.teal),
                onPressed: () => Navigator.pop(context, ph == _FlashPhase.done),
                child: const Text('OK'),
              ),
          ],
        ),
      ),
    );
    progress.dispose();
    phase.dispose();
    message.dispose();
    return ok ?? false;
  }

  /// The "server code is behind" notice. Informational — the fix happens on
  /// the machine running the launcher, not on this tablet.
  static Future<void> showServer(BuildContext context) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: XSColors.slate,
          title: const Text('Server update available'),
          content: const Text(
            'The screening server is one version behind.\n\n'
            'Run UPDATE on the server launcher (the machine this kiosk '
            'connects to) to bring it current. No action needed on the kiosk.',
            style: TextStyle(color: XSColors.mint, height: 1.5),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: XSColors.teal),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
}

enum _FlashPhase { flashing, done, failed }
