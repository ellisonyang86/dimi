/// HTTP 客户端封装：
/// - 响应包络 {code,message,data,trace_id} 解包，code=0 成功，其余抛 ApiException
/// - Authorization: Bearer 注入；40101 时用 refresh_token 刷新并重试一次
/// - 写接口自动携带 Idempotency-Key
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';

/// 用户服务协议 / 隐私政策版本号，注册勾选同意后随 agreement_version 上报
const String kAgreementVersion = 'v0.9.0-2025.09';

/// 法务文档静态页路径（host = ApiConfig.baseUrl 去掉 /v1，无 /v1 前缀）
const String kUserAgreementPath = '/legal/user-agreement.md';
const String kPrivacyPolicyPath = '/legal/privacy-policy.md';

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.traceId, this.data});
  final int code;
  final String message;
  final String? traceId;
  final dynamic data;

  /// 频控，需要滑块/人机验证
  static const int needCaptcha = 42901;

  /// 未登录 / token 失效
  static const int unauthorized = 40101;

  /// 隐私限制
  static const int privacyBlocked = 40301;

  /// 内容安全拦截（如验证语含联系方式）
  static const int contentBlocked = 45001;

  /// 资源不存在（页面/内容已删除或 id 无效），终态无需重试
  static const int notFound = 41001;

  bool get isNeedCaptcha => code == needCaptcha;

  /// 高隐私分组门禁拦截（40301 且 data.locked=true）
  bool get isGroupLocked =>
      code == privacyBlocked && data is Map && (data as Map)['locked'] == true;

  @override
  String toString() => 'ApiException($code, $message, trace=$traceId)';
}

String newIdempotencyKey() {
  final r = Random.secure();
  final rand = List<int>.generate(12, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${DateTime.now().millisecondsSinceEpoch}-$rand';
}

class ApiClient {
  ApiClient({
    required this.accessTokenProvider,
    required this.refreshTokenProvider,
    required this.onTokenRefreshed,
    required this.onAuthExpired,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// 取当前 access_token（内存态）
  final String? Function() accessTokenProvider;

  /// 取当前 refresh_token
  final String? Function() refreshTokenProvider;

  /// 刷新成功后回写新 token 对（由 Session 持久化）
  final Future<void> Function(
      String accessToken, String refreshToken, int expiresIn) onTokenRefreshed;

  /// 刷新失败（refresh_token 也失效）→ 强制登出
  final void Function() onAuthExpired;

  final http.Client _http;

  /// 单请求超时：http 包默认无超时，弱网/服务端黑洞时 Future 永不完成，
  /// UI 会卡在加载态（启动期表现为黑屏"死机"）。超时抛 TimeoutException，
  /// 由下方 `on Exception` 统一包装为 ApiException(-1)
  static const Duration _timeout = Duration(seconds: 15);

  /// 并发刷新去重（单飞）
  Future<bool>? _refreshing;

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse('${ApiConfig.baseUrl}$path');
    if (query == null || query.isEmpty) return base;
    final qp = <String, String>{};
    query.forEach((k, v) {
      if (v != null) qp[k] = v.toString();
    });
    return base.replace(queryParameters: qp);
  }

  /// 统一请求入口。返回包络中的 data 字段。
  /// headers 用于透传额外请求头（如高隐私分组的 X-Group-Unlock 凭证）。
  Future<dynamic> request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool idempotent = false,
    bool auth = true,
    bool retryOnUnauthorized = true,
    Map<String, String>? headers,
  }) async {
    final reqHeaders = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      if (headers != null) ...headers,
    };
    if (auth) {
      final token = accessTokenProvider();
      if (token != null && token.isNotEmpty) {
        reqHeaders['Authorization'] = 'Bearer $token';
      }
    }
    if (idempotent && !reqHeaders.containsKey('Idempotency-Key')) {
      reqHeaders['Idempotency-Key'] = newIdempotencyKey();
    }

    final uri = _uri(path, query);
    final encoded = body == null ? null : jsonEncode(body);
    http.Response resp;
    try {
      switch (method) {
        case 'GET':
          resp = await _http.get(uri, headers: reqHeaders).timeout(_timeout);
          break;
        case 'POST':
          resp = await _http
              .post(uri, headers: reqHeaders, body: encoded)
              .timeout(_timeout);
          break;
        case 'PUT':
          resp = await _http
              .put(uri, headers: reqHeaders, body: encoded)
              .timeout(_timeout);
          break;
        case 'DELETE':
          resp = await _http.delete(uri, headers: reqHeaders).timeout(_timeout);
          break;
        default:
          throw ArgumentError('unsupported method: $method');
      }
    } on Exception {
      throw ApiException(-1, '网络连接失败，请检查网络后重试');
    }

    Map<String, dynamic> envelope;
    try {
      envelope =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } on Exception {
      throw ApiException(50000, '服务响应格式错误（HTTP ${resp.statusCode}）');
    }

    final code = asInt(envelope['code']) ?? 50000;
    final message = asStr(envelope['message']) ?? '未知错误';
    final traceId = asStr(envelope['trace_id']);

    if (code == 0) return envelope['data'];

    if (code == ApiException.unauthorized &&
        auth &&
        retryOnUnauthorized &&
        path != '/auth/refresh') {
      if (reqHeaders['Authorization'] != 'Bearer ${accessTokenProvider()}') {
        throw ApiException(ApiException.unauthorized, '登录状态已变更，请重试');
      }
      final ok = await _refresh();
      if (ok) {
        return request(method, path,
            query: query,
            body: body,
            idempotent: idempotent,
            auth: auth,
            retryOnUnauthorized: false,
            headers: reqHeaders);
      }
      onAuthExpired();
    }

    throw ApiException(code, message, traceId: traceId, data: envelope['data']);
  }

  Future<bool> _refresh() {
    final inflight = _refreshing;
    if (inflight != null) return inflight;
    final task = _doRefresh();
    _refreshing = task;
    return task.whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final rt = refreshTokenProvider();
    if (rt == null || rt.isEmpty) return false;
    try {
      final resp = await _http
          .post(
            _uri('/auth/refresh'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'refresh_token': rt}),
          )
          .timeout(_timeout);
      final envelope = jsonDecode(utf8.decode(resp.bodyBytes));
      if (envelope is! Map<String, dynamic>) {
        throw ApiException(50000, '服务响应格式错误');
      }
      if (rt != refreshTokenProvider()) {
        throw ApiException(ApiException.unauthorized, '登录状态已变更，请重试');
      }
      if (asInt(envelope['code']) == ApiException.unauthorized) return false;
      if (asInt(envelope['code']) != 0) {
        throw ApiException(50000, '会话刷新暂时失败，请稍后重试');
      }
      final data = envelope['data'];
      if (data is! Map<String, dynamic>) throw ApiException(50000, '服务响应格式错误');
      final token = AuthToken.fromJson(data);
      await onTokenRefreshed(
          token.accessToken, token.refreshToken, token.expiresIn);
      return true;
    } on ApiException {
      rethrow;
    } on Exception {
      throw ApiException(-1, '网络连接失败，请检查网络后重试');
    }
  }

  Future<dynamic> get(String path,
          {Map<String, dynamic>? query,
          bool auth = true,
          Map<String, String>? headers}) =>
      request('GET', path, query: query, auth: auth, headers: headers);

  Future<dynamic> post(String path,
          {Object? body,
          bool idempotent = false,
          bool auth = true,
          Map<String, String>? headers}) =>
      request('POST', path,
          body: body, idempotent: idempotent, auth: auth, headers: headers);

  Future<dynamic> put(String path,
          {Object? body, bool auth = true, Map<String, String>? headers}) =>
      request('PUT', path, body: body, auth: auth, headers: headers);

  Future<dynamic> delete(String path,
          {bool auth = true, Map<String, String>? headers}) =>
      request('DELETE', path, auth: auth, headers: headers);
}

/// 联调专用免验证 token：服务端 DIMI_SMS_DEV=true 时接受。
/// 仅限开发联调！正式构建必须将 [allowDevCaptchaBypass] 置为 false，
/// 改由滑块验证（slider_captcha.dart）拿到真实 captcha_token 后传入。
const String kDevCaptchaBypassToken = 'dev_bypass';

/// 是否允许在未传 captchaToken 时回退 dev_bypass（仅限联调，上线前置 false）
bool allowDevCaptchaBypass = kDebugMode;

/// 业务接口集合（对齐《DIMI_OpenAPI.yaml》v3.1.0，V0.9 切片内约 25 个接口）
class DimiApi {
  DimiApi(this._c);

  final ApiClient _c;

  Map<String, dynamic> _map(dynamic data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};

  List<dynamic> _list(dynamic data, [String key = 'items']) {
    final m = _map(data);
    return m[key] is List ? m[key] as List : const [];
  }

  // ============ Captcha（滑块人机验证）============

  /// 拉取滑块挑战（免鉴权）。token 一次性、5 分钟有效。
  Future<SliderChallenge> sliderCaptcha() async => SliderChallenge.fromJson(
      _map(await _c.get('/captcha/slider', auth: false)));

  /// 提交滑块偏移 x 换取 captcha_token；失败抛 40001（调用方应刷新挑战重试）
  Future<String> verifySlider(String captchaId, int x) async {
    final m = _map(await _c.post('/captcha/verify',
        auth: false, body: {'captcha_id': captchaId, 'x': x}));
    return asStr(m['captcha_token']) ?? '';
  }

  // ============ Auth ============

  /// 发送短信验证码。
  /// captchaToken：滑块验证通过后传入真实 token；缺省且 [allowDevCaptchaBypass]
  /// 为 true 时回退 dev_bypass（仅限联调）。
  /// 返回开发模式下服务端回显的验证码（生产模式恒为 null）。
  Future<String?> sendSms(String phone,
      {String scene = 'login', String? captchaToken}) async {
    final token =
        captchaToken ?? (allowDevCaptchaBypass ? kDevCaptchaBypassToken : null);
    final data = await _c.post('/auth/sms/send', auth: false, body: {
      'phone': phone,
      if (token != null) 'captcha_token': token,
      'scene': scene,
    });
    if (data is Map<String, dynamic>) return asStr(data['sms_code']);
    return null;
  }

  Future<AuthToken> register({
    required String phone,
    required String smsCode,
    required String nickname,
    int? birthYear,
    String? inviteChannel,
    String? agreementVersion,
  }) async {
    final data = await _c.post('/auth/register', auth: false, body: {
      'phone': phone,
      'sms_code': smsCode,
      'nickname': nickname,
      if (birthYear != null) 'birth_year': birthYear,
      if (inviteChannel != null && inviteChannel.isNotEmpty)
        'invite_channel': inviteChannel,
      if (agreementVersion != null) 'agreement_version': agreementVersion,
    });
    return AuthToken.fromJson(_map(data));
  }

  Future<AuthToken> loginBySms({
    required String phone,
    required String smsCode,
    String? captchaToken,
  }) async {
    final data = await _c.post('/auth/login', auth: false, body: {
      'grant_type': 'sms',
      'phone': phone,
      'sms_code': smsCode,
      if (captchaToken != null) 'captcha_token': captchaToken,
    });
    return AuthToken.fromJson(_map(data));
  }

  /// 密码登录（grant_type=password）
  Future<AuthToken> loginByPassword({
    required String phone,
    required String password,
    String? captchaToken,
  }) async {
    final data = await _c.post('/auth/login', auth: false, body: {
      'grant_type': 'password',
      'phone': phone,
      'password': password,
      if (captchaToken != null) 'captcha_token': captchaToken,
    });
    return AuthToken.fromJson(_map(data));
  }

  /// 设置/修改登录密码（POST /auth/password，需登录）：
  /// new_password 8–64 位 + 发到本账号手机号的短信验证码（scene=set_password）
  Future<void> setPassword({
    required String newPassword,
    required String smsCode,
  }) =>
      _c.post('/auth/password', body: {
        'new_password': newPassword,
        'sms_code': smsCode,
      });

  Future<void> logout() => _c.post('/auth/logout');

  /// 登录设备列表（含 current 标记）
  Future<List<DeviceSession>> devices() async {
    final data = await _c.get('/auth/devices');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(DeviceSession.fromJson)
        .toList();
  }

  /// 下线指定设备（不能下线本机）
  Future<void> revokeDevice(int deviceId) =>
      _c.delete('/auth/devices/$deviceId');

  /// 联系方式分项可见范围（phone/wechat/email → self/friends/verified_friends/strong_tier）
  Future<Map<String, String>> contactsVisibility() async {
    final m = _map(await _c.get('/users/me/contacts-visibility'));
    final cv = _map(m['contacts_visibility']);
    return cv.map((k, v) => MapEntry(k, v?.toString() ?? 'self'));
  }

  Future<void> updateContactsVisibility(Map<String, String> visibility) =>
      _c.put('/users/me/contacts-visibility', body: visibility);

  // ============ Users ============

  Future<UserSelf> me() async =>
      UserSelf.fromJson(_map(await _c.get('/users/me')));

  Future<UserCard> userCard(int userId, {String? unlockToken}) async =>
      UserCard.fromJson(_map(await _c.get('/users/$userId',
          headers: _unlockHeaders(unlockToken))));

  /// 修改本人资料（只传要改的字段）。
  /// 头像：先 uploadImage(scene='avatar') 拿到 url，再以 avatarUrl 传入
  /// （/media/ 前缀，服务端校验；旧 avatar_media_id 为 deprecated 兼容别名）。
  /// 朋友圈封面同理：uploadImage(scene='moment') → momentCover 传入。
  Future<void> updateMe({
    String? nickname,
    String? avatarUrl,
    int? gender,
    int? birthYear,
    bool clearBirthYear = false,
    String? signature,
    String? momentCover,
  }) =>
      _c.put('/users/me', body: {
        if (nickname != null) 'nickname': nickname,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        if (gender != null) 'gender': gender,
        if (birthYear != null || clearBirthYear) 'birth_year': birthYear,
        if (signature != null) 'signature': signature,
        if (momentCover != null) 'moment_cover': momentCover,
      });

  Future<UserSelf> updateDimiNo(String value) async => UserSelf.fromJson(
      _map(await _c.put('/users/me/dimi-no', body: {'dimi_no': value})));

  /// 谁看过我的联系方式（近 30 天，审计回看，§20.7 双向透明）
  Future<List<ContactViewer>> contactViewers() async {
    final data = await _c.get('/users/me/contact-viewers');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(ContactViewer.fromJson)
        .toList();
  }

  // ============ Educations ============

  Future<List<Education>> myEducations() async {
    final data = await _c.get('/users/me/educations');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(Education.fromJson)
        .toList();
  }

  Future<EducationCreateResult> addEducation({
    required String stage,
    required int schoolId,
    required int enrollYear,
    String? className,
    String? department,
    String? major,
  }) async {
    final data = await _c.post('/users/me/educations', idempotent: true, body: {
      'stage': stage,
      'school_id': schoolId,
      'enroll_year': enrollYear,
      if (className != null && className.isNotEmpty) 'class_name': className,
      if (department != null && department.isNotEmpty) 'department': department,
      if (major != null && major.isNotEmpty) 'major': major,
    });
    return EducationCreateResult.fromJson(_map(data));
  }

  /// 修改教育经历（班级/可见性/院系/专业，只传要改的字段）
  Future<void> updateEducation(
    int educationId, {
    String? className,
    String? visibility,
    String? department,
    String? major,
  }) =>
      _c.put('/users/me/educations/$educationId', body: {
        if (className != null) 'class_name': className,
        if (visibility != null) 'visibility': visibility,
        if (department != null) 'department': department,
        if (major != null) 'major': major,
      });

  Future<void> deleteEducation(int educationId) =>
      _c.delete('/users/me/educations/$educationId');

  Future<List<School>> searchSchools(String keyword,
      {String? regionCode}) async {
    final data = await _c.get('/schools/search', query: {
      'keyword': keyword,
      if (regionCode != null) 'region_code': regionCode,
    });
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(School.fromJson)
        .toList();
  }

  Future<void> applySchool({
    required String name,
    required String regionCode,
  }) =>
      _c.post('/schools/apply', idempotent: true, body: {
        'name': name,
        'region_code': regionCode,
      });

  // ============ Hometown ============

  /// 行政区划四级联动：parentCode 为空取省级列表
  Future<List<Region>> regions({String? parentCode}) async {
    final data = await _c.get('/regions', auth: false, query: {
      if (parentCode != null) 'parent_code': parentCode,
    });
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(Region.fromJson)
        .toList();
  }

  /// 我的家乡/现居地（含名称路径）
  Future<List<HometownEntry>> myHometowns() async {
    final data = await _c.get('/users/me/hometown');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(HometownEntry.fromJson)
        .toList();
  }

  /// 设置家乡（type=1，须精确到镇）或现居地（type=2，到城市）
  Future<void> setMyHometown({
    required int type,
    required String regionCode,
    String visibility = 'public',
  }) =>
      _c.put('/users/me/hometown', body: {
        'type': type,
        'region_code': regionCode,
        'visibility': visibility,
      });

  // ============ Discover ============
  // 分页为 page/size 语义：next_cursor 为 String(page+1) 或 null，
  // 客户端内部自增页码传入，不做游标透传。

  Future<DiscoverResult> classmates({
    required int schoolId,
    required int enrollYear,
    String? classNorm,
    String? name,
    int? page,
    int? size,
    String? captchaToken,
  }) async {
    final data = await _c.get('/discover/classmates', query: {
      'school_id': schoolId,
      'enroll_year': enrollYear,
      if (classNorm != null && classNorm.isNotEmpty) 'class_norm': classNorm,
      if (name != null && name.isNotEmpty) 'name': name,
      if (page != null && page > 0) 'page': page,
      if (size != null && size > 0) 'size': size,
      if (captchaToken != null && captchaToken.isNotEmpty)
        'captcha_token': captchaToken,
    });
    return DiscoverResult.fromJson(_map(data));
  }

  Future<DiscoverResult> myClassmates(
    int educationId, {
    String scope = 'class',
    int? page,
    int? size,
  }) async {
    final data = await _c.get('/discover/classmates/mine', query: {
      'education_id': educationId,
      'scope': scope,
      if (page != null && page > 0) 'page': page,
      if (size != null && size > 0) 'size': size,
    });
    return DiscoverResult.fromJson(_map(data));
  }

  Future<DiscoverResult> recommendations({
    String scene = 'home',
    int? page,
    int? size,
  }) async {
    final data = await _c.get('/discover/recommendations', query: {
      'scene': scene,
      if (page != null && page > 0) 'page': page,
      if (size != null && size > 0) 'size': size,
    });
    return DiscoverResult.fromJson(_map(data));
  }

  /// 找老乡检索：锚点 regionCode（市/区县/镇），level 控制匹配粒度
  Future<DiscoverResult> fellows({
    required String regionCode,
    int level = 4,
    String? name,
    int? gender,
    String? ageRange,
    int? page,
    String? captchaToken,
  }) async {
    final data = await _c.get('/discover/fellows', query: {
      'region_code': regionCode,
      'level': level,
      if (name != null && name.isNotEmpty) 'name': name,
      if (gender != null) 'gender': gender,
      if (ageRange != null && ageRange.isNotEmpty) 'age_range': ageRange,
      if (page != null) 'page': page,
      if (captchaToken != null) 'captcha_token': captchaToken,
    });
    return DiscoverResult.fromJson(_map(data));
  }

  /// 精确找人：DIMI号或手机号（二选一，0 或 1 条结果）
  Future<DiscoverResult> searchUserExact({
    String? dimiNo,
    String? phone,
    String? captchaToken,
  }) async {
    final data = await _c.get('/discover/search-user', query: {
      if (dimiNo != null && dimiNo.isNotEmpty) 'dimi_no': dimiNo,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (captchaToken != null && captchaToken.isNotEmpty)
        'captcha_token': captchaToken,
    });
    return DiscoverResult.fromJson(_map(data));
  }

  /// 推荐负反馈：不感兴趣 / 减少此类
  Future<void> discoverFeedback({
    required int targetUserId,
    String action = 'not_interested',
  }) =>
      _c.post('/discover/feedback', body: {
        'target_user_id': targetUserId,
        'action': action,
      });

  /// 班级点名册：已注册人数 + 占位（点亮）名单
  Future<Map<String, dynamic>> classRoster(int educationId) async {
    final data = await _c
        .get('/discover/placeholders', query: {'education_id': educationId});
    return _map(data);
  }

  /// 点亮未注册同学名字（预占位）。返回 rally_ready / rally_card_url。
  Future<Map<String, dynamic>> lightUpName({
    required int educationId,
    required String name,
  }) async {
    final data =
        await _c.post('/discover/placeholders', idempotent: true, body: {
      'education_id': educationId,
      'name': name,
    });
    return _map(data);
  }

  // ============ Friends ============

  Future<void> sendFriendRequest({
    required int toUserId,
    required String verifyMsg,
    bool attachRealName = true,
    bool attachEducation = false,
    String source = 'classmate_search',
  }) =>
      _c.post('/friends/requests', idempotent: true, body: {
        'to_user_id': toUserId,
        'verify_msg': verifyMsg,
        'attach_real_name': attachRealName,
        'attach_education': attachEducation,
        'source': source,
      });

  Future<List<FriendRequest>> friendRequests({String box = 'inbox'}) async {
    final items = <FriendRequest>[];
    String? cursor;
    do {
      final data = await _c
          .get('/friends/requests', query: {'box': box, 'cursor': cursor});
      items.addAll(_list(data)
          .whereType<Map<String, dynamic>>()
          .map(FriendRequest.fromJson));
      final next = asStr(_map(data)['next_cursor']);
      if (next == cursor) break;
      cursor = next;
    } while (cursor != null && cursor.isNotEmpty);
    return items;
  }

  /// 通过申请，返回 conversation_id
  Future<int> acceptFriendRequest(int requestId) async {
    final data = await _c.post('/friends/requests/$requestId/accept');
    return asInt(_map(data)['conversation_id']) ?? 0;
  }

  Future<void> rejectFriendRequest(int requestId) =>
      _c.post('/friends/requests/$requestId/reject');

  /// 好友列表（含备注/标签/星标）
  Future<FriendsPage> friends({String? cursor, String? unlockToken}) async {
    final data = await _c.get('/friends',
        query: {
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        },
        headers: _unlockHeaders(unlockToken));
    final m = _map(data);
    return FriendsPage(
      items: m['items'] is List
          ? (m['items'] as List)
              .whereType<Map<String, dynamic>>()
              .map(FriendEntry.fromJson)
              .toList()
          : const [],
      nextCursor: asStr(m['next_cursor']),
      unlocked: m['unlocked'] == true,
      lockedCount: asInt(m['locked_count']) ?? 0,
    );
  }

  /// 备注/标签/星标（契约 PUT /friends/{friend_id}，只传要改的字段）
  Future<void> updateFriend(
    int friendId, {
    String? remarkName,
    bool clearRemark = false,
    List<String>? tags,
    bool? isStarred,
  }) =>
      _c.put('/friends/$friendId', body: {
        if (remarkName != null) 'remark_name': remarkName,
        if (clearRemark) 'remark_name': null,
        if (tags != null) 'tags': tags,
        if (isStarred != null) 'is_starred': isStarred,
      });

  /// 单向删除好友（§8.4）
  Future<void> deleteFriend(int friendId) => _c.delete('/friends/$friendId');

  /// 拉黑 / 移出黑名单（§8.1 双向断联）
  Future<void> blockFriend(int friendId) => _c.post('/friends/$friendId/block');
  Future<void> unblockFriend(int friendId) =>
      _c.delete('/friends/$friendId/block');

  /// 黑名单列表（管理闭环）
  Future<List<UserBrief>> blockedUsers() async {
    final data = await _c.get('/friends/blocks');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(UserBrief.fromJson)
        .toList();
  }

  // ============ Messages ============
  // V0.9 用 REST 轮询实现单聊；正式版替换为腾讯云 IM SDK（见 V0.9 计划书 §5.3）

  Future<List<Conversation>> conversations() async {
    final data = await _c.get('/conversations');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(Conversation.fromJson)
        .toList();
  }

  /// 打开（或复用）与指定用户的单聊会话，资料卡「发消息」用
  Future<Conversation> createConversation(int toUserId) async {
    final data = await _c.post('/conversations', body: {
      'to_user_id': toUserId,
    });
    return Conversation.fromJson(_map(data));
  }

  /// 拉取消息：默认倒序分页（cursor）；传 sinceMsgId 时为增量模式
  /// （msg_id 更大的消息，正序，≤50 条，next_cursor 恒 null）。
  /// 返回 (items, nextCursor)。
  Future<({List<Message> items, String? nextCursor})> messages(
    int convId, {
    String? cursor,
    int? sinceMsgId,
    int limit = 20,
  }) async {
    final data = await _c.get('/conversations/$convId/messages', query: {
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (sinceMsgId != null) 'since_msg_id': sinceMsgId,
      'limit': limit,
    });
    final m = _map(data);
    final items = (m['items'] is List ? m['items'] as List : const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(Message.fromJson)
        .toList();
    return (items: items, nextCursor: asStr(m['next_cursor']));
  }

  /// 发送消息（client_msg_id 幂等防重），返回服务端 msg_id。
  /// msgType：text（默认）/ image（content 为媒体 URL）
  Future<int> sendMessage({
    required int convId,
    required String content,
    required String clientMsgId,
    String msgType = 'text',
  }) async {
    final data = await _c.post(
      '/conversations/$convId/messages',
      idempotent: true,
      body: {
        'client_msg_id': clientMsgId,
        'msg_type': msgType,
        'content': content,
      },
    );
    return asInt(_map(data)['msg_id']) ?? 0;
  }

  Future<void> markRead(int convId, int lastReadMsgId) =>
      _c.post('/conversations/$convId/read', body: {
        'last_read_msg_id': lastReadMsgId,
      });

  /// 撤回消息（发送后 2 分钟内）
  Future<void> recallMessage(int msgId) => _c.post('/messages/$msgId/recall');

  /// 清除本人可见历史并移出会话列表；不影响对方或群成员关系。
  Future<void> deleteConversation(int convId) =>
      _c.delete('/conversations/$convId');

  /// 会话设置：置顶/免打扰
  Future<void> updateConversationSettings(int convId,
          {bool? isPinned, bool? isMuted}) =>
      _c.put('/conversations/$convId/settings', body: {
        if (isPinned != null) 'is_pinned': isPinned,
        if (isMuted != null) 'is_muted': isMuted,
      });

  // ============ Class Groups（班级群聊）============
  // 班级单元（school_id+enroll_year+class_name_norm）一一对应一个群会话；
  // 群成员不要求互为好友，消息链路复用上方会话接口。

  /// 我的班级单元 + 对应班级群（群未建时 group 为 null）
  Future<List<ClassGroupUnit>> myClassGroups() async {
    final data = await _c.get('/class-groups/mine');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(ClassGroupUnit.fromJson)
        .toList();
  }

  /// 加入（或创建）班级群：class_name 传原文，服务端规范化；
  /// 无该单元教育经历 → 40301
  Future<ClassGroupInfo> joinClassGroup({
    required int schoolId,
    required int enrollYear,
    required String className,
  }) async {
    final data = await _c.post('/class-groups/join', idempotent: true, body: {
      'school_id': schoolId,
      'enroll_year': enrollYear,
      'class_name': className,
    });
    return ClassGroupInfo.fromJson(_map(data));
  }

  /// 群成员列表（含 is_owner 与 owner_id；非成员 40301）
  Future<({List<ClassGroupMember> items, int? ownerId})> classGroupMembers(
      int convId) async {
    final m = _map(await _c.get('/class-groups/$convId/members'));
    return (
      items: _list(m)
          .whereType<Map<String, dynamic>>()
          .map(ClassGroupMember.fromJson)
          .toList(),
      ownerId: asInt(m['owner_id']),
    );
  }

  /// 修改群公告（仅群主，≤200 字）
  Future<void> updateClassGroupAnnouncement(int convId, String announcement) =>
      _c.put('/class-groups/$convId/announcement',
          body: {'announcement': announcement});

  Future<void> leaveClassGroup(int convId) =>
      _c.post('/class-groups/$convId/leave');

  // ============ Hometown Groups（老乡群）============
  // 老乡单元 = 家乡（type=1）region_code 前 4 位（同市），与老乡圈同边界；
  // 契约镜像班级群，群信息/成员模型直接复用 ClassGroupInfo / ClassGroupMember。
  // 聊天页走通用会话（chat.dart），群资料页走通用群管理页（group_info.dart）。

  /// 我的老乡单元 + 对应老乡群（未设家乡返回空列表；群未建时 group 为 null）
  Future<List<HometownGroupUnit>> myHometownGroups() async {
    final data = await _c.get('/hometown-groups/mine');
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(HometownGroupUnit.fromJson)
        .toList();
  }

  /// 加入（或创建）老乡群：无 body，服务端按我的家乡定位单元；
  /// 未设家乡 → 40301
  Future<ClassGroupInfo> joinHometownGroup({String? regionCode}) async {
    final data = await _c.post('/hometown-groups/join',
        idempotent: true,
        body: {if (regionCode != null) 'region_code': regionCode});
    return ClassGroupInfo.fromJson(_map(data));
  }

  /// 群成员列表（含 is_owner 与 owner_id；非成员 40301）
  Future<({List<ClassGroupMember> items, int? ownerId})> hometownGroupMembers(
      int convId) async {
    final m = _map(await _c.get('/hometown-groups/$convId/members'));
    return (
      items: _list(m)
          .whereType<Map<String, dynamic>>()
          .map(ClassGroupMember.fromJson)
          .toList(),
      ownerId: asInt(m['owner_id']),
    );
  }

  /// 修改群公告（仅群主，≤200 字）
  Future<void> updateHometownGroupAnnouncement(
          int convId, String announcement) =>
      _c.put('/hometown-groups/$convId/announcement',
          body: {'announcement': announcement});

  Future<void> leaveHometownGroup(int convId) =>
      _c.post('/hometown-groups/$convId/leave');

  // ============ Hometown Pages（家乡页 M1）============
  // 对齐《家乡页与共建体系设计_V1》§10：镇级页面聚合 + 分类内容分页 +
  // 投稿/点赞/关注；写接口全部带幂等键，投稿资格（can_post）由服务端按籍贯判定。

  /// 家乡页聚合：简介/封面/关注数/我是否可关注与投稿/老乡群入口
  Future<HometownPage> hometownPage(String regionCode) async =>
      HometownPage.fromJson(_map(await _c.get('/hometown-pages/$regionCode')));

  /// 内容分页（category 过滤，cursor 分页；rolled_up 时附县页 TOP 内容）
  Future<HometownContentPage> hometownPageContents(
    String regionCode, {
    String? category,
    String? cursor,
  }) async {
    final data = await _c.get('/hometown-pages/$regionCode/contents', query: {
      if (category != null && category.isNotEmpty) 'category': category,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });
    return HometownContentPage.fromJson(_map(data));
  }

  /// 投稿：media 传 /misc/upload 返回的 url 数组（≤9 个）；
  /// 籍贯不符 40301 / 频控 42901 / 内容拦截 45001
  Future<HometownContent> createHometownContent({
    required String regionCode,
    required String category,
    required String title,
    String? body,
    List<String>? media,
  }) async {
    final data = await _c.post('/hometown-contents', idempotent: true, body: {
      'region_code': regionCode,
      'category': category,
      'title': title,
      if (body != null && body.isNotEmpty) 'body': body,
      if (media != null && media.isNotEmpty) 'media': media,
    });
    return HometownContent.fromJson(_map(data));
  }

  /// 内容详情（浏览去重计数在此触发）
  Future<HometownContent> hometownContentDetail(int contentId) async =>
      HometownContent.fromJson(
          _map(await _c.get('/hometown-contents/$contentId')));

  Future<void> deleteHometownContent(int contentId) =>
      _c.delete('/hometown-contents/$contentId');

  Future<ArticleCommentPage> hometownComments(int contentId,
          {String? cursor}) async =>
      ArticleCommentPage.fromJson(_map(await _c.get(
          '/hometown-contents/$contentId/comments',
          query: {if (cursor != null) 'cursor': cursor})));

  Future<void> commentHometown(int contentId, String content,
          {String? requestKey}) =>
      _c.post('/hometown-contents/$contentId/comments',
          idempotent: true,
          headers: {if (requestKey != null) 'Idempotency-Key': requestKey},
          body: {'content': content});

  Future<void> deleteHometownComment(int contentId, int commentId) =>
      _c.delete('/hometown-contents/$contentId/comments/$commentId');

  Future<MomentGifts> hometownGifts(int contentId) async =>
      MomentGifts.fromJson(
          _map(await _c.get('/hometown-contents/$contentId/gifts')));

  Future<void> sendHometownGift(int contentId, int amount,
          {String? requestKey}) =>
      _c.post('/hometown-contents/$contentId/gifts',
          idempotent: true,
          headers: {if (requestKey != null) 'Idempotency-Key': requestKey},
          body: {'coin_amount': amount});

  /// 点赞 / 取消点赞（幂等）；返回服务端最新 like_count/liked，供本地校准覆盖
  Future<({int likeCount, bool liked})> likeHometownContent(
      int contentId) async {
    final m = _map(
        await _c.post('/hometown-contents/$contentId/like', idempotent: true));
    return (likeCount: asInt(m['like_count']) ?? 0, liked: asBool(m['liked']));
  }

  Future<({int likeCount, bool liked})> unlikeHometownContent(
      int contentId) async {
    final m = _map(await _c.delete('/hometown-contents/$contentId/like'));
    return (likeCount: asInt(m['like_count']) ?? 0, liked: asBool(m['liked']));
  }

  /// 关注 / 取消关注家乡
  Future<void> followHometownPage(String regionCode) =>
      _c.post('/hometown-pages/$regionCode/follow');

  Future<void> unfollowHometownPage(String regionCode) =>
      _c.delete('/hometown-pages/$regionCode/follow');

  /// 我关注的家乡页列表（按关注时间倒序）
  Future<List<Map<String, dynamic>>> followedHometownPages() async {
    final data = await _c.get('/hometown-pages/followed/mine');
    return _list(data).whereType<Map<String, dynamic>>().toList();
  }

  // ============ Wallet（觅豆钱包 / 红包 / 动态打赏）============
  // P0 纯赠送体系：觅豆仅任务赠送获得，无充值无提现；写接口全部带幂等键。
  // 红包消息卡由服务端在发红包同事务内代发，客户端不得自行拼卡。

  /// 钱包总览：余额 / 累计收支 / 今日签到态 / 任务列表
  Future<WalletInfo> wallet() async =>
      WalletInfo.fromJson(_map(await _c.get('/wallet')));

  /// 收支明细（倒序 cursor 分页）。返回 (items, nextCursor)。
  Future<({List<CoinTransaction> items, String? nextCursor})>
      walletTransactions({String? cursor}) async {
    final data = await _c.get('/wallet/transactions', query: {
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    });
    final m = _map(data);
    return (
      items: _list(m)
          .whereType<Map<String, dynamic>>()
          .map(CoinTransaction.fromJson)
          .toList(),
      nextCursor: asStr(m['next_cursor']),
    );
  }

  /// 每日签到（当日重复 granted=false）
  Future<({bool granted, int amount, int balance})> checkin() async {
    final m = _map(await _c.post('/wallet/checkin'));
    return (
      granted: m['granted'] == true,
      amount: asInt(m['amount']) ?? 0,
      balance: asInt(m['balance']) ?? 0,
    );
  }

  /// 发红包：私聊固定 type=normal、count=1；群聊 luck/normal、个数≤成员数。
  /// 成功后服务端同事务代发 red_packet 消息卡，本地靠消息轮询出现。
  Future<({RedPacket packet, int balance})> sendRedPacket({
    required int convId,
    required String type,
    required int totalAmount,
    required int count,
    String? greeting,
  }) async {
    final m = _map(await _c.post('/red-packets', idempotent: true, body: {
      'conv_id': convId,
      'type': type,
      'total_amount': totalAmount,
      'count': count,
      if (greeting != null && greeting.isNotEmpty) 'greeting': greeting,
    }));
    return (
      packet: RedPacket.fromJson(m),
      balance: asInt(m['balance']) ?? 0,
    );
  }

  /// 领红包（发者不可领、每人限领一次；已领完/已过期抛 40001）
  Future<({int amount, int balance, RedPacket packet})> claimRedPacket(
      String packetId) async {
    final m = _map(await _c.post('/red-packets/$packetId/claim'));
    return (
      amount: asInt(m['amount']) ?? 0,
      balance: asInt(m['balance']) ?? 0,
      packet: RedPacket.fromJson(_map(m['packet'])),
    );
  }

  /// 红包详情（含领取列表与我的领取结果）
  Future<RedPacket> redPacket(String packetId) async =>
      RedPacket.fromJson(_map(await _c.get('/red-packets/$packetId')));

  /// 动态打赏（面额白名单 1/5/10/52/100 觅豆；不能打赏自己的动态）
  Future<({String orderId, int balance})> sendMomentGift(
      int momentId, int coinAmount,
      {String? requestKey}) async {
    final m = _map(await _c.post('/moments/$momentId/gifts',
        headers: {if (requestKey != null) 'Idempotency-Key': requestKey},
        idempotent: true,
        body: {'coin_amount': coinAmount}));
    return (
      orderId: asStr(m['order_id']) ?? '',
      balance: asInt(m['balance']) ?? 0,
    );
  }

  /// 动态打赏汇总（打赏榜，最多返回近 50 条）
  Future<MomentGifts> momentGifts(int momentId) async =>
      MomentGifts.fromJson(_map(await _c.get('/moments/$momentId/gifts')));

  /// 注销账号（短信二次验证 + 7 天冷静期）
  Future<void> deactivateAccount(String smsCode) =>
      _c.post('/auth/deactivate', body: {'sms_code': smsCode});

  /// 个人信息导出（PIPL 可携带权）
  Future<Map<String, dynamic>> exportData() async =>
      _map(await _c.post('/privacy/data-export'));

  // ============ Privacy ============

  Future<PrivacySettings> privacySettings() async =>
      PrivacySettings.fromJson(_map(await _c.get('/privacy/settings')));

  Future<void> updatePrivacySettings(PrivacySettings s) =>
      _c.put('/privacy/settings', body: s.toJson());

  // ============ Contact Groups（高隐私分组）============

  /// 高隐私内容请求头：解锁凭证非空时携带 X-Group-Unlock
  Map<String, String>? _unlockHeaders(String? unlockToken) =>
      (unlockToken == null || unlockToken.isEmpty)
          ? null
          : {'X-Group-Unlock': unlockToken};

  /// 设置/修改隐私密码（6–64 位；已设置过须带 oldPassword）
  Future<void> setPrivacyPassword(String password, {String? oldPassword}) =>
      _c.put('/privacy/password', body: {
        'password': password,
        if (oldPassword != null && oldPassword.isNotEmpty)
          'old_password': oldPassword,
      });

  /// 解锁高隐私分组：隐私密码换 5 分钟短时凭证
  Future<({String token, int expiresIn})> unlockGroups(String password) async {
    final m = _map(
        await _c.post('/privacy/groups/unlock', body: {'password': password}));
    final token = asStr(m['unlock_token']);
    final seconds = asInt(m['expires_in']) ?? 300;
    if (token == null || token.isEmpty || seconds <= 0) {
      throw ApiException(50000, '解锁凭证无效，请重试');
    }
    return (token: token, expiresIn: seconds);
  }

  /// 立即锁定（作废全部解锁凭证）
  Future<void> lockGroups() => _c.post('/privacy/groups/lock');

  /// 分组列表；未解锁时高隐私组 memberCount 为 null
  Future<({bool unlocked, List<ContactGroup> items})> contactGroups(
      {String? unlockToken}) async {
    final m = _map(
        await _c.get('/contact-groups', headers: _unlockHeaders(unlockToken)));
    return (
      unlocked: m['unlocked'] == true,
      items: _list(m)
          .whereType<Map<String, dynamic>>()
          .map(ContactGroup.fromJson)
          .toList(),
    );
  }

  /// 新建分组，返回 group_id；建高隐私组须先设置隐私密码
  Future<int> createGroup(
      {required String name, String privacyLevel = 'normal'}) async {
    final m = _map(await _c.post('/contact-groups',
        idempotent: true, body: {'name': name, 'privacy_level': privacyLevel}));
    return asInt(m['group_id']) ?? 0;
  }

  Future<void> updateGroup(int groupId,
          {String? name, String? privacyLevel, String? unlockToken}) =>
      _c.put('/contact-groups/$groupId',
          headers: _unlockHeaders(unlockToken),
          body: {
            if (name != null) 'name': name,
            if (privacyLevel != null) 'privacy_level': privacyLevel,
          });

  /// 删除分组（成员移出分组）；高隐私组须解锁
  Future<void> deleteGroup(int groupId, {String? unlockToken}) => _c
      .delete('/contact-groups/$groupId', headers: _unlockHeaders(unlockToken));

  /// 好友移入分组（groupId 为 null 移出分组）
  Future<void> moveFriendToGroup(int friendId, int? groupId,
          {String? unlockToken}) =>
      _c.put('/friends/$friendId/group',
          headers: _unlockHeaders(unlockToken), body: {'group_id': groupId});

  // ============ Misc（举报 / 申诉 / 意见反馈 / 上传）============

  /// 举报（人工复核 SLA 24h）。
  /// targetType：user / moment / article / message / group；
  /// reason：politics / porn / fraud / harassment / infringement / impersonation / other
  Future<void> report({
    required String targetType,
    required int targetId,
    required String reason,
    String? detail,
  }) =>
      _c.post('/misc/report', idempotent: true, body: {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason,
        if (detail != null && detail.isNotEmpty) 'detail': detail,
      });

  /// 账号/内容申诉。type：freeze（冻结）/ content（内容误判）/ impersonation（冒名）
  Future<void> appeal({required String type, required String content}) =>
      _c.post('/misc/appeal', idempotent: true, body: {
        'type': type,
        'content': content,
      });

  /// 意见反馈（contact 选填）
  Future<void> feedback({required String content, String? contact}) =>
      _c.post('/feedback', idempotent: true, body: {
        'content': content,
        if (contact != null && contact.isNotEmpty) 'contact': contact,
      });

  /// 通用媒体上传（≤2MB，jpg/jpeg/png/webp），返回 {media_id, url}。
  /// scene：avatar / chat_image / evidence / feedback / moment
  Future<Map<String, String>> uploadImage(
      String scene, List<int> bytes, String ext) async {
    final data = await _c.post('/misc/upload', idempotent: true, body: {
      'scene': scene,
      'content_base64': base64Encode(bytes),
      'ext': ext,
    });
    final m = _map(data);
    return {
      'media_id': asStr(m['media_id']) ?? '',
      'url': asStr(m['url']) ?? '',
    };
  }

  // ============ Moments（朋友圈）============

  /// 发布动态（可见范围发布即冻结，不可改）。
  /// contentType='image' 时 mediaIds 传 upload 返回的 url 数组（1–9 个），content 可空。
  Future<Moment> publishMoment(
      {String? content,
      String contentType = 'text',
      List<String>? mediaIds,
      String visibility = 'public'}) async {
    final data = await _c.post('/moments', idempotent: true, body: {
      'content_type': contentType,
      if (content != null && content.isNotEmpty) 'content': content,
      if (mediaIds != null && mediaIds.isNotEmpty) 'media_ids': mediaIds,
      'visibility': visibility,
    });
    return Moment.fromJson(_map(data));
  }

  /// 上传朋友圈图片（≤2MB，jpg/jpeg/png/webp），返回可访问 url
  Future<String> uploadMomentImage(List<int> bytes, String ext) async =>
      (await uploadImage('moment', bytes, ext))['url'] ?? '';

  /// 时间线（好友 + 自己，倒序分页）。返回 (items, nextCursor)。
  /// visibility 非空时按可见范围过滤（同学圈/老乡圈聚合页用）。
  Future<({List<Moment> items, String? nextCursor})> momentsFeed(
      {String? cursor, String? visibility}) async {
    final data = await _c.get('/moments/feed', query: {
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (visibility != null && visibility.isNotEmpty) 'visibility': visibility,
    });
    final m = _map(data);
    final items = _list(m)
        .whereType<Map<String, dynamic>>()
        .map(Moment.fromJson)
        .toList();
    return (items: items, nextCursor: asStr(m['next_cursor']));
  }

  /// 我的动态在 sinceMs（epoch 毫秒）之后是否有他人的点赞/评论
  Future<bool> momentsInteractionsUnread(int sinceMs) async {
    final data =
        await _c.get('/moments/interactions/unread', query: {'since': sinceMs});
    return _map(data)['has_new'] == true;
  }

  /// 动态详情（含完整评论列表）
  Future<Moment> momentDetail(int momentId) async =>
      Moment.fromJson(_map(await _c.get('/moments/$momentId')));

  /// 删除动态（仅作者）
  Future<void> deleteMoment(int momentId) => _c.delete('/moments/$momentId');

  Future<void> likeMoment(int momentId) =>
      _c.post('/moments/$momentId/likes', idempotent: true);

  Future<void> unlikeMoment(int momentId) =>
      _c.delete('/moments/$momentId/likes');

  /// 评论/回复，返回 comment_id
  Future<int> commentMoment(int momentId, String content,
      {int? replyToUserId, String? requestKey}) async {
    final m = _map(await _c
        .post('/moments/$momentId/comments', idempotent: true, headers: {
      if (requestKey != null) 'Idempotency-Key': requestKey
    }, body: {
      'content': content,
      if (replyToUserId != null) 'reply_to_user_id': replyToUserId,
    }));
    return asInt(m['comment_id']) ?? 0;
  }

  /// 某用户相册页（陌生人按对方隐私设置限最近 10 条）
  Future<List<Moment>> userMoments(int userId, {String? unlockToken}) async {
    final data = await _c.get('/users/$userId/moments',
        headers: _unlockHeaders(unlockToken));
    return _list(data)
        .whereType<Map<String, dynamic>>()
        .map(Moment.fromJson)
        .toList();
  }
}
