import 'dart:async';
import 'dart:convert';

import 'package:dimi/api/client.dart';
import 'package:dimi/screens/home.dart';
import 'package:dimi/screens/login.dart';
import 'package:dimi/screens/privacy_consent.dart';
import 'package:dimi/state/preview_login.dart';
import 'package:dimi/state/session.dart';
import 'package:dimi/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response loginResponse() => http.Response(
    jsonEncode({
      'code': 0,
      'data': {
        'access_token': 'preview-access',
        'refresh_token': 'preview-refresh',
        'expires_in': 7200,
        'user': {'user_id': 1, 'nickname': '体验用户'}
      }
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

DimiApi previewApi(MockClient transport) => DimiApi(ApiClient(
      accessTokenProvider: () => null,
      refreshTokenProvider: () => null,
      onTokenRefreshed: (_, __, ___) async {},
      onAuthExpired: () {},
      httpClient: transport,
    ));

Widget host(DimiApi api, Session session) => MultiProvider(
      providers: [
        Provider<DimiApi>.value(value: api),
        ChangeNotifierProvider<Session>.value(value: session),
      ],
      child: MaterialApp(
        theme: buildDimiTheme(),
        home: const LoginScreen(),
        routes: {
          MainShell.routeName: (_) => const Scaffold(body: Text('已进入主程序')),
        },
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({kPrivacyConsentKey: true});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
  });

  test('预置账号走正常密码登录且不发送短信或注册账号', () async {
    final requests = <http.Request>[];
    final api = previewApi(MockClient((request) async {
      requests.add(request);
      return loginResponse();
    }));
    final token = await authenticatePreview(api);
    expect(token.accessToken, 'preview-access');
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/v1/auth/login');
    expect(jsonDecode(requests.single.body)['grant_type'], 'password');
    expect(jsonDecode(requests.single.body)['phone'], kDevLoginPhone);
  }, skip: !kDevAutoLogin);

  test('登录响应缺少用户或令牌时拒绝进入体验', () async {
    final api = previewApi(
        MockClient((_) async => http.Response('{"code":0,"data":{}}', 200)));
    await expectLater(authenticatePreview(api), throwsA(isA<ApiException>()));
  }, skip: !kDevAutoLogin);

  testWidgets('未同意隐私政策时体验入口不发送网络请求', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final session = Session();
    addTearDown(session.dispose);
    final api = previewApi(MockClient((_) async {
      calls++;
      return loginResponse();
    }));
    await tester.pumpWidget(host(api, session));
    await tester.tap(find.text('直接体验（免注册）'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(session.isLoggedIn, isFalse);
    expect(find.textContaining('请先在首次启动页面'), findsOneWidget);
  }, skip: !kDevAutoLogin);

  testWidgets('服务断开提示原因，恢复后无需手机号即可重试进入主程序', (tester) async {
    var available = false;
    final session = Session();
    addTearDown(session.dispose);
    final api = previewApi(MockClient((_) async {
      if (!available) throw http.ClientException('offline');
      return loginResponse();
    }));
    await tester.pumpWidget(host(api, session));
    await tester.tap(find.text('直接体验（免注册）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无需申请账号'), findsOneWidget);
    expect(session.isLoggedIn, isFalse);
    available = true;
    await tester.tap(find.text('直接体验（免注册）'));
    await tester.pumpAndSettle();
    expect(find.text('已进入主程序'), findsOneWidget);
    expect(session.isLoggedIn, isTrue);
    expect(session.onboarded, isTrue);
    expect(tester.takeException(), isNull);
  }, skip: !kDevAutoLogin);

  testWidgets('请求未返回时重复点击不会创建第二次登录', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final session = Session();
    addTearDown(session.dispose);
    final api = previewApi(MockClient((_) {
      calls++;
      return pending.future;
    }));
    await tester.pumpWidget(host(api, session));
    final button = find.widgetWithText(FilledButton, '直接体验（免注册）');
    final position = tester.getCenter(button);
    await tester.tapAt(position);
    await tester.pump();
    await tester.tapAt(position);
    await tester.pump();
    expect(calls, 1);
    pending.complete(loginResponse());
    await tester.pumpAndSettle();
    expect(find.text('已进入主程序'), findsOneWidget);
  }, skip: !kDevAutoLogin);

  testWidgets('关闭体验开关后隐藏入口且拒绝体验登录请求', (tester) async {
    var calls = 0;
    final session = Session();
    addTearDown(session.dispose);
    final api = previewApi(MockClient((_) async {
      calls++;
      return loginResponse();
    }));
    await tester.pumpWidget(host(api, session));
    expect(find.text('直接体验（免注册）'), findsNothing);
    await expectLater(authenticatePreview(api), throwsA(isA<ApiException>()));
    expect(calls, 0);
  }, skip: kDevAutoLogin);
}
