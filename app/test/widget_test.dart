/// DimiApp 冒烟测试：无登录态启动应落在登录页。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dimi/api/client.dart';
import 'package:dimi/main.dart';
import 'package:dimi/state/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_secure_storage 在测试环境无平台实现，mock 成始终返回 null
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  testWidgets('未登录启动落在登录页', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session();
    await session.restore();

    final api = DimiApi(ApiClient(
      accessTokenProvider: () => session.accessToken,
      refreshTokenProvider: () => session.refreshToken,
      onTokenRefreshed: session.updateTokens,
      onAuthExpired: session.clear,
    ));

    await tester.pumpWidget(DimiApp(session: session, api: api));
    await tester.pumpAndSettle();

    expect(find.text('DIMI · 围城'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });
}
