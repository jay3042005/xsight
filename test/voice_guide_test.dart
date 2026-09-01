import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xsight_app/core/voice/voice_guide.dart';

/// Guards the link between the recorded clips on disk and the cues that ask for
/// them. Both halves are edited by hand — a clip is added by dropping an MP3 in
/// a folder — so a typo in either one is silent at runtime: the cue simply never
/// speaks, and a kiosk that says nothing looks exactly like a kiosk with the
/// guidance switched off.
void main() {
  // Needed for `rootBundle`, which reaches through the services binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const dir = 'assets/voice/en';

  test('cue ids are unique', () {
    final seen = <String, XSVoiceCue>{};
    for (final cue in XSVoiceCue.values) {
      final clash = seen[cue.file];
      expect(clash, isNull,
          reason: '${cue.name} and ${clash?.name} both claim "${cue.file}"');
      seen[cue.file] = cue;
    }
  });

  test('every recorded clip belongs to a cue', () {
    final declared = {for (final c in XSVoiceCue.values) c.file};
    final orphans = Directory(dir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.mp3'))
        .map((n) => n.substring(0, n.length - 4))
        .where((id) => !declared.contains(id))
        .toList()
      ..sort();

    expect(orphans, isEmpty,
        reason: 'clips no cue will ever play — check the filenames against '
            'voice-guide.md');
  });

  test('recorded clips are reachable through the asset bundle', () async {
    final recorded = Directory(dir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.mp3'))
        .toList()
      ..sort();

    // A folder that has stopped being copied is the failure this catches, so an
    // empty folder must not pass by having nothing to check.
    expect(recorded, isNotEmpty);

    for (final name in recorded) {
      final data = await rootBundle.load('$dir/$name');
      expect(data.lengthInBytes, greaterThan(0), reason: '$name is empty');
    }
  });
}
