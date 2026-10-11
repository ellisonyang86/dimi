/// 首启隐私同意流程测试：弹窗不可绕过，不同意再说明可返回，同意后持久化标记。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dimi/screens/privacy_consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('不同意 → 再说明 → 返回 → 同意后持久化并回调', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    var agreed = false;

    await tester.pumpWidget(PrivacyConsentApp(onAgreed: () async {
      agreed = true;
    }));
    await tester.pumpAndSettle();

    // 同意弹窗（非消）展示协议说明与链接
    expect(find.text('隐私政策与用户协议'), findsOneWidget);
    expect(find.textContaining('《用户服务协议》', findRichText: true), findsOneWidget);
    expect(find.textContaining('《隐私政策》', findRichText: true), findsOneWidget);

    // 不同意 → 再说明弹窗，含退出入口
    await tester.tap(find.text('不同意'));
    await tester.pumpAndSettle();
    expect(find.text('需要同意后才能使用'), findsOneWidget);
    expect(find.text('退出应用'), findsOneWidget);

    // 再看看 → 回到同意弹窗
    await tester.tap(find.text('再看看'));
    await tester.pumpAndSettle();
    expect(find.text('隐私政策与用户协议'), findsOneWidget);

    // 同意 → 持久化 privacy_consent_v1 并触发回调
    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();
    expect(agreed, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kPrivacyConsentKey), isTrue);
  });

  testWidgets('isPrivacyConsented 读取持久化标记', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    expect(await isPrivacyConsented(), isFalse);
    SharedPreferences.setMockInitialValues({kPrivacyConsentKey: true});
    expect(await isPrivacyConsented(), isTrue);
  });
}
