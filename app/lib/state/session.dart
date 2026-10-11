/// 登录会话状态：token 对 + 当前用户。
/// token 优先存 flutter_secure_storage（Android 启用 EncryptedSharedPreferences），
/// 插件不可用（如单元测试无平台通道）时回退 shared_preferences；
/// 用户 JSON 缓存等非敏感数据仍留 shared_preferences。
library;

import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';

class Session extends ChangeNotifier {
  static const _kAccessToken = 'dimi.access_token';
  static const _kRefreshToken = 'dimi.refresh_token';
  static const _kTokenExpireAt = 'dimi.token_expire_at';
  static const _kCurrentUser = 'dimi.current_user';
  static const _kOnboarded = 'dimi.onboarded';
  static const _kCareMode = 'dimi.care_mode';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? _accessToken;
  String? _refreshToken;
  UserSelf? _currentUser;
  bool _onboarded = false;
  bool _restored = false;

  /// 关怀模式（适老化）：全局字号放大 1.3 倍，设备级偏好，登出不清除
  bool _careMode = false;

  /// 高隐私分组解锁凭证：仅内存态，不落盘（App 重启即回到锁定）
  String? _groupUnlockToken;
  Timer? _groupUnlockTimer;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  UserSelf? get currentUser => _currentUser;
  bool get onboarded => _onboarded;
  bool get restored => _restored;
  bool get careMode => _careMode;
  bool get isLoggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  String? get groupUnlockToken => _groupUnlockToken;

  void setGroupUnlockToken(String token,
      {Duration lifetime = const Duration(minutes: 5)}) {
    _groupUnlockTimer?.cancel();
    _groupUnlockToken = token;
    _groupUnlockTimer = Timer(lifetime, clearGroupUnlockToken);
    notifyListeners();
  }

  void clearGroupUnlockToken() {
    _groupUnlockTimer?.cancel();
    _groupUnlockTimer = null;
    if (_groupUnlockToken == null) return;
    _groupUnlockToken = null;
    notifyListeners();
  }

  /// 读 token：优先安全存储；读不到时尝试迁移 shared_preferences 里的旧值
  Future<String?> _readToken(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } on MissingPluginException {
      // 平台通道不可用（单元测试等），走回退
    } on Exception {
      // 安全存储读写失败，走回退
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(key);
    if (legacy != null) {
      try {
        await _secure.write(key: key, value: legacy);
        await prefs.remove(key);
      } on MissingPluginException {
        // 迁移失败则保留旧值
      } on Exception {
        // 迁移失败则保留旧值
      }
    }
    return legacy;
  }

  Future<void> _writeToken(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await _secure.write(key: key, value: value);
      await prefs.remove(key);
    } on MissingPluginException {
      await prefs.setString(key, value);
    } on Exception {
      await prefs.setString(key, value);
    }
  }

  Future<void> _deleteToken(String key) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await _secure.delete(key: key);
    } on MissingPluginException {
      // 回退路径下本就不在安全存储里
    } on Exception {
      // 回退路径下本就不在安全存储里
    }
    await prefs.remove(key);
  }

  /// App 启动时从本地恢复会话
  Future<void> restore() async {
    _accessToken = await _readToken(_kAccessToken);
    _refreshToken = await _readToken(_kRefreshToken);
    final prefs = await SharedPreferences.getInstance();
    _careMode = prefs.getBool(_kCareMode) ?? false;
    final userJson = prefs.getString(_kCurrentUser);
    if (userJson != null) {
      try {
        final m = jsonDecode(userJson);
        if (m is Map<String, dynamic>) _currentUser = UserSelf.fromJson(m);
      } on Exception {
        _currentUser = null;
      }
    }
    _onboarded = _currentUser == null
        ? false
        : (prefs.getBool('$_kOnboarded.${_currentUser!.userId}') ??
            prefs.getBool(_kOnboarded) ??
            false);
    _restored = true;
    notifyListeners();
  }

  /// 登录/注册成功后写入 token 与用户信息
  Future<void> login(AuthToken token) async {
    _accessToken = token.accessToken;
    _refreshToken = token.refreshToken;
    _currentUser = token.user;
    _groupUnlockTimer?.cancel();
    _groupUnlockToken = null;
    await _writeToken(_kAccessToken, token.accessToken);
    await _writeToken(_kRefreshToken, token.refreshToken);
    final prefs = await SharedPreferences.getInstance();
    _onboarded = prefs.getBool('$_kOnboarded.${token.user?.userId}') ?? false;
    await prefs.setInt(
      _kTokenExpireAt,
      DateTime.now().millisecondsSinceEpoch + token.expiresIn * 1000,
    );
    if (token.user != null) {
      await prefs.setString(_kCurrentUser, jsonEncode(token.user!.toJson()));
    } else {
      await prefs.remove(_kCurrentUser);
    }
    notifyListeners();
  }

  /// 401 刷新成功后回写新 token 对（由 ApiClient 回调）
  Future<void> updateTokens(
      String accessToken, String refreshToken, int expiresIn) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    await _writeToken(_kAccessToken, accessToken);
    await _writeToken(_kRefreshToken, refreshToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kTokenExpireAt,
      DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    );
    notifyListeners();
  }

  /// 拉取最新本人资料后更新缓存
  Future<void> updateCurrentUser(UserSelf user) async {
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrentUser, jsonEncode(user.toJson()));
    notifyListeners();
  }

  Future<void> markOnboarded() async {
    _onboarded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboarded, true);
    await prefs.setBool('$_kOnboarded.${_currentUser?.userId}', true);
    notifyListeners();
  }

  /// 关怀模式开关：即时生效（main.dart 监听重建 MediaQuery.textScaler）
  Future<void> setCareMode(bool value) async {
    _careMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCareMode, value);
    notifyListeners();
  }

  /// 退出登录 / token 失效强制登出
  Future<void> clear() async {
    _groupUnlockTimer?.cancel();
    _accessToken = null;
    _refreshToken = null;
    _currentUser = null;
    _onboarded = false;
    _groupUnlockToken = null;
    await _deleteToken(_kAccessToken);
    await _deleteToken(_kRefreshToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTokenExpireAt);
    await prefs.remove(_kCurrentUser);
    await prefs.remove(_kOnboarded);
    notifyListeners();
  }

  @override
  void dispose() {
    _groupUnlockTimer?.cancel();
    super.dispose();
  }
}
