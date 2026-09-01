import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xsight_app/main.dart';

void main() {
  testWidgets('XSightApp renders splash screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    // Discovery off: the splash's LAN sweep holds real sockets and its
    // 8-second budget timer would outlive the fake-async test zone.
    await tester.pumpWidget(const XSightApp(autoDiscoverServer: false));
    await tester.pump(const Duration(milliseconds: 1500));

    expect(find.byType(XSightApp), findsOneWidget);
  });
}


