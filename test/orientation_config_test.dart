import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile app is locked to landscape on every platform layer', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final iosInfo = File('ios/Runner/Info.plist').readAsStringSync();

    expect(mainSource, contains('DeviceOrientation.landscapeLeft'));
    expect(mainSource, contains('DeviceOrientation.landscapeRight'));
    expect(mainSource, isNot(contains('DeviceOrientation.portraitUp')));
    expect(mainSource, isNot(contains('DeviceOrientation.portraitDown')));

    expect(
      androidManifest,
      contains('android:screenOrientation="sensorLandscape"'),
    );

    expect(iosInfo, contains('UIInterfaceOrientationLandscapeLeft'));
    expect(iosInfo, contains('UIInterfaceOrientationLandscapeRight'));
    expect(iosInfo, isNot(contains('UIInterfaceOrientationPortrait')));
  });
}
