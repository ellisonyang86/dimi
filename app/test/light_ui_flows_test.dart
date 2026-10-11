import 'dart:convert';

import 'package:dimi/api/client.dart';
import 'package:dimi/api/models.dart';
import 'package:dimi/screens/fellow.dart';
import 'package:dimi/screens/my_qrcode.dart';
import 'package:dimi/screens/profile_edit.dart';
import 'package:dimi/screens/search.dart';
import 'package:dimi/state/session.dart';
import 'package:dimi/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dimi/screens/data_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response reply(Object? data, {int code = 0}) => http.Response(
    jsonEncode({
      'code': code,
      'message': code == 0 ? 'ok' : '网络暂时不可用',
      'data': data,
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget host(Widget page, Session session, MockClient transport) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<Session>.value(value: session),
        Provider<DimiApi>(
            create: (_) => DimiApi(ApiClient(
                accessTokenProvider: () => 'test',
                refreshTokenProvider: () => 'refresh',
                onTokenRefreshed: (_, __, ___) async {},
                onAuthExpired: () {},
                httpClient: transport)))
      ],
      child: MaterialApp(
          theme: buildDimiTheme(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: page),
    );

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('主动生成个人信息，复制完整 JSON 不重复请求', (tester) async {
    final session = Session();
    addTearDown(session.dispose);
    var requests = 0;
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final payload = {
      'profile': {'nickname': '备份测试'},
      'educations': <Object>[],
      'friends': <Object>[]
    };
    await tester.pumpWidget(
        host(const DataExportScreen(), session, MockClient((r) async {
      requests++;
      return reply(payload);
    })));
    await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.tap(find.text('生成我的数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制完整数据'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(jsonDecode(copied.single), payload);
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料清空出生年提交 null，保存失败保留草稿，小屏可操作', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    await session.updateCurrentUser(
        UserSelf(userId: 1, nickname: '原昵称', birthYear: 1990));
    final writes = <Map<String, dynamic>>[];
    await tester.pumpWidget(
        host(const ProfileEditScreen(), session, MockClient((r) async {
      if (r.method == 'PUT') {
        writes.add(jsonDecode(r.body) as Map<String, dynamic>);
      }
      return reply(null, code: 40001);
    })));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '新昵称');
    await tester.enterText(find.byType(TextField).at(1), '');
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(writes.single.containsKey('birth_year'), isTrue);
    expect(writes.single['birth_year'], isNull);
    expect(writes.single['nickname'], '新昵称');
    expect(find.text('新昵称'), findsOneWidget);
    expect(find.text('网络暂时不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DIMI 号取消不保存，改号刷新名片，二维码用户标识保持不变', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    await session.updateCurrentUser(
        UserSelf(userId: 7, nickname: '名字比较长的用户', dimiNo: 'DM10000007'));
    final values = <String>[];
    await tester
        .pumpWidget(host(const MyQrcodeScreen(), session, MockClient((r) async {
      values.add((jsonDecode(r.body) as Map)['dimi_no'] as String);
      return reply({
        'user_id': 7,
        'nickname': '名字比较长的用户',
        'dimi_no': 'hello_dimi',
        'dimi_no_changed_at': DateTime.now().toIso8601String()
      });
    })));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('设置 DIMI 号'));
    await tester.tap(find.text('设置 DIMI 号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(values, isEmpty);
    await tester.tap(find.text('设置 DIMI 号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'HELLO_DIMI');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(values, ['hello_dimi']);
    expect(session.currentUser!.userId, 7);
    expect(find.text('hello_dimi'), findsOneWidget);
    await tester.ensureVisible(find.text('修改 DIMI 号'));
    await tester.tap(find.text('修改 DIMI 号'));
    await tester.pumpAndSettle();
    expect(find.textContaining('下次可修改'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同学筛选修改后清除旧结果，失败展示重试而非空结果', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    var searches = 0;
    await tester.pumpWidget(host(
        SearchScreen(
            initialEducation: Education(
                id: 1,
                schoolId: 1001,
                schoolName: '一个比较长的测试学校名称',
                enrollYear: 1996)),
        session, MockClient((r) async {
      if (r.url.path.endsWith('/classmates')) {
        searches++;
        return searches == 1
            ? reply({
                'items': [
                  {'user_id': 2, 'nickname': '老同学'}
                ]
              })
            : reply(null, code: 40001);
      }
      return reply({'items': <Object>[]});
    })));
    await tester.pumpAndSettle();
    expect(find.text('已找到 1 位同学'), findsOneWidget);
    await tester.tap(find.text('班级、姓名（选填）'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '测试');
    await tester.pumpAndSettle();
    expect(find.text('已找到 1 位同学'), findsNothing);
    final search = find.widgetWithText(FilledButton, '找同学');
    await tester.ensureVisible(search);
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('重试'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('暂未找到同学'), findsNothing);
    expect(find.text('网络暂时不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('老乡翻页保留已加载人员且去重，小屏大字无溢出', (tester) async {
    narrow(tester);
    final session = Session();
    addTearDown(session.dispose);
    final pages = <String?>[];
    await tester
        .pumpWidget(host(const FellowScreen(), session, MockClient((r) async {
      if (r.url.path.endsWith('/hometown')) {
        return reply({
          'items': [
            {
              'type': 1,
              'region_code': '411623102',
              'path': ['河南省', '周口市', '商水县', '城关镇']
            }
          ]
        });
      }
      pages.add(r.url.queryParameters['page']);
      return reply({
        'items': [
          {'user_id': 2, 'nickname': '第一位老乡'},
          if (pages.length == 2) {'user_id': 3, 'nickname': '第二位老乡'}
        ],
        'next_cursor': pages.length == 1 ? '2' : null
      });
    })));
    await tester.pumpAndSettle();
    final search = find.widgetWithText(FilledButton, '找老乡');
    await tester.ensureVisible(search);
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('加载更多'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(pages, ['1', '2']);
    expect(find.text('已找到 2 位老乡'), findsOneWidget);
    expect(find.text('第一位老乡'), findsOneWidget);
    expect(find.text('第二位老乡'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
