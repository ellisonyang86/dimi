/// DIMI · 围城 V0.9 垂直切片入口。
/// 主色莫兰迪灰绿（见 theme.dart）；启动时恢复本地会话：
/// 未登录 → 登录页；已登录未 onboarded → 经历引导页；已 onboarded → 主页。
/// 首次启动先做隐私同意前置（工信部合规，见 screens/privacy_consent.dart），
/// 同意前不初始化会话/网络等任何业务模块。
/// Debug 构建默认开启开发免登录（种子账号直登，可用
/// --dart-define=DEV_AUTO_LOGIN=false 关闭，DEV_LOGIN_PHONE 换账号）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'screens/devices.dart';
import 'screens/friend_requests.dart';
import 'screens/friends.dart';
import 'screens/blacklist.dart';
import 'screens/fellow.dart';
import 'screens/home.dart';
import 'screens/invite.dart';
import 'screens/login.dart';
import 'screens/onboarding_education.dart';
import 'screens/privacy.dart';
import 'screens/privacy_consent.dart';
import 'screens/register.dart';
import 'screens/search.dart';
import 'state/session.dart';
import 'state/preview_login.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 工信部合规：首启隐私同意前不做任何初始化（本应用无第三方 SDK，
  // 会话恢复、网络客户端等全部延后到同意之后）。
  // 本地存储异常（如加密存储损坏）时按未同意处理，保证 App 一定能起界面
  bool consented = false;
  try {
    consented = await isPrivacyConsented();
  } on Exception {
    consented = false;
  }
  if (!consented) {
    runApp(const PrivacyConsentApp(onAgreed: _bootstrapAndRun));
    return;
  }
  await _bootstrapAndRun();
}

/// 同意后的正式启动：恢复会话并进入主程序
Future<void> _bootstrapAndRun() async {
  final session = Session();
  try {
    await session.restore();
  } on Exception {
    // 本地会话损坏：按未登录启动，不阻塞 runApp
  }

  final client = ApiClient(
    accessTokenProvider: () => session.accessToken,
    refreshTokenProvider: () => session.refreshToken,
    onTokenRefreshed: session.updateTokens,
    onAuthExpired: session.clear,
  );
  final api = DimiApi(client);

  // 同意隐私协议后使用预置体验账号。失败原因在登录页展示，并可直接重试。
  String? previewLoginError;
  if (!session.isLoggedIn && kDevAutoLogin) {
    try {
      final token = await authenticatePreview(api);
      await session.login(token);
      await session.markOnboarded();
    } on Exception catch (error) {
      previewLoginError = previewLoginMessage(error);
    }
  }

  runApp(DimiApp(
      session: session, api: api, previewLoginError: previewLoginError));
}

class DimiApp extends StatefulWidget {
  const DimiApp(
      {super.key,
      required this.session,
      required this.api,
      this.previewLoginError});

  final Session session;
  final DimiApi api;
  final String? previewLoginError;

  @override
  State<DimiApp> createState() => _DimiAppState();
}

class _DimiAppState extends State<DimiApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late bool _wasLoggedIn;
  Session get session => widget.session;
  DimiApi get api => widget.api;

  @override
  void initState() {
    super.initState();
    _wasLoggedIn = session.isLoggedIn;
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    final expired = _wasLoggedIn && !session.isLoggedIn;
    _wasLoggedIn = session.isLoggedIn;
    if (expired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !session.isLoggedIn) {
          _navigatorKey.currentState
              ?.pushNamedAndRemoveUntil(LoginScreen.routeName, (_) => false);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_sessionChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      session.clearGroupUnlockToken();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Session>.value(value: session),
        Provider<DimiApi>.value(value: api),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'DIMI · 围城',
        debugShowCheckedModeBanner: false,
        theme: buildDimiTheme(),
        // 启动判 token + onboarded：已登录未填经历先落引导页（消除死状态）
        home: !session.isLoggedIn
            ? LoginScreen(previewLoginError: widget.previewLoginError)
            : session.onboarded
                ? const MainShell()
                : const OnboardingEducationScreen(),
        // 关怀模式：全局字号 ×1.3（叠加系统字体缩放），开关切换即时生效
        builder: (context, child) => AnimatedBuilder(
          animation: session,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                  textScaler: session.careMode
                      ? DimiCareTextScaler(mq.textScaler)
                      : mq.textScaler),
              child: child!,
            );
          },
          child: child,
        ),
        // 路由表：无参静态屏走命名路由；
        // 带参屏（资料卡/好友申请/单聊）用 Navigator.push + 构造参数
        routes: {
          LoginScreen.routeName: (_) => const LoginScreen(),
          RegisterScreen.routeName: (_) => const RegisterScreen(),
          OnboardingEducationScreen.routeName: (_) =>
              const OnboardingEducationScreen(),
          MainShell.routeName: (_) => const MainShell(),
          SearchScreen.routeName: (_) => const SearchScreen(),
          FriendRequestsScreen.routeName: (_) => const FriendRequestsScreen(),
          DevicesScreen.routeName: (_) => const DevicesScreen(),
          FriendsScreen.routeName: (_) => const FriendsScreen(),
          BlacklistScreen.routeName: (_) => const BlacklistScreen(),
          FellowScreen.routeName: (_) => const FellowScreen(),
          PrivacyScreen.routeName: (_) => const PrivacyScreen(),
          InviteScreen.routeName: (_) => const InviteScreen(),
        },
      ),
    );
  }
}
