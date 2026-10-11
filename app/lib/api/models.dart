/// 数据模型，与《DIMI_OpenAPI.yaml》v3.1.0 components/schemas 对应。
/// 注意：real_name 由服务端按「真名渐显矩阵」判定后直接返回展示值
/// （全名/掩码/null），客户端不得二次加工 —— 模型只做透传。
library;

import 'dart:convert';

import 'config.dart';

/// 消息展示文本：系统消息 content 可能是结构化 JSON
/// （如破冰卡 {"type":"ice_breaker","banner":"…"}），解析出可读文案；
/// 非 JSON 时原样返回。聊天气泡与会话列表摘要共用。
String displayMessageText(String msgType, String content) {
  if (msgType == 'image') return '[图片]';
  if (msgType == 'voice') return '[语音]';
  if (msgType == 'video') return '[视频]';
  if (msgType == 'red_packet' || content == '[red_packet]') return '[红包]';
  if (msgType == 'system' || content.startsWith('{')) {
    try {
      final m = jsonDecode(content);
      if (m is Map) {
        final banner = m['banner'];
        if (banner is String && banner.isNotEmpty) return banner;
        final text = m['text'];
        if (text is String && text.isNotEmpty) return text;
      }
    } on Exception {
      // 非 JSON，原样展示
    }
  }
  return content;
}

int? asInt(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

String? asStr(dynamic v) => v?.toString();

/// 媒体路径补全（可空版）：null/空串返回 null，其余过 ApiConfig.resolveMediaUrl
String? resolveMediaUrlOrNull(dynamic v) {
  final s = asStr(v);
  if (s == null || s.isEmpty) return null;
  return ApiConfig.resolveMediaUrl(s);
}

bool asBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return fallback;
}

List<String> asStrList(dynamic v) =>
    v is List ? v.map((e) => e.toString()).toList() : const [];

/// 学段枚举 → 中文标签（OpenAPI Stage）
String stageLabel(String? stage) {
  switch (stage) {
    case 'PRIMARY':
      return '小学';
    case 'MIDDLE':
      return '初中';
    case 'HIGH':
      return '高中';
    case 'VOCATIONAL':
      return '中专职高';
    case 'UNIVERSITY':
      return '大学大专';
    case 'POSTGRADUATE':
      return '研究生';
    default:
      return stage ?? '';
  }
}

/// AuthToken —— /auth/register、/auth/login、/auth/refresh 的 data
class AuthToken {
  AuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    this.user,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final UserSelf? user;

  factory AuthToken.fromJson(Map<String, dynamic> j) => AuthToken(
        accessToken: asStr(j['access_token']) ?? '',
        refreshToken: asStr(j['refresh_token']) ?? '',
        expiresIn: asInt(j['expires_in']) ?? 7200,
        user: j['user'] is Map<String, dynamic>
            ? UserSelf.fromJson(j['user'] as Map<String, dynamic>)
            : null,
      );
}

/// UserSelf —— 本人视角全字段
class UserSelf {
  UserSelf({
    required this.userId,
    this.dimiNo,
    this.dimiNoChangedAt,
    this.phone,
    this.nickname,
    this.realName,
    this.gender,
    this.birthYear,
    this.avatarUrl,
    this.signature,
    this.momentCover,
    this.isMinor = false,
    this.creditScore = 100,
  });

  final int userId;
  final String? dimiNo;
  final String? dimiNoChangedAt;
  final String? phone;
  final String? nickname;
  final String? realName;
  final int? gender;
  final int? birthYear;
  final String? avatarUrl;
  final String? signature;

  /// 朋友圈相册封面（解析时已过 ApiConfig.resolveMediaUrl 补全为绝对地址）
  final String? momentCover;
  final bool isMinor;
  final int creditScore;

  factory UserSelf.fromJson(Map<String, dynamic> j) => UserSelf(
        userId: asInt(j['user_id']) ?? 0,
        dimiNo: asStr(j['dimi_no']),
        dimiNoChangedAt: asStr(j['dimi_no_changed_at']),
        phone: asStr(j['phone']),
        nickname: asStr(j['nickname']),
        realName: asStr(j['real_name']),
        gender: asInt(j['gender']),
        birthYear: asInt(j['birth_year']),
        avatarUrl: asStr(j['avatar_url']),
        signature: asStr(j['signature']),
        momentCover: resolveMediaUrlOrNull(j['moment_cover']),
        isMinor: asBool(j['is_minor']),
        creditScore: asInt(j['credit_score']) ?? 100,
      );

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'dimi_no': dimiNo,
        'dimi_no_changed_at': dimiNoChangedAt,
        'phone': phone,
        'nickname': nickname,
        'real_name': realName,
        'gender': gender,
        'birth_year': birthYear,
        'avatar_url': avatarUrl,
        'signature': signature,
        'moment_cover': momentCover,
        'is_minor': isMinor,
        'credit_score': creditScore,
      };
}

/// UserBrief —— 用户简卡，检索/推荐/申请列表通用
class UserBrief {
  UserBrief({
    required this.userId,
    this.nickname,
    this.realName,
    this.avatarUrl,
    this.relation,
    this.intersectionTier,
    this.matchTags = const [],
    this.mutualFriends = 0,
    this.reason,
  });

  final int userId;
  final String? nickname;

  /// 服务端渐显判定后的展示值（全名/掩码/null），禁止二次加工
  final String? realName;
  final String? avatarUrl;
  final String? relation;
  final String? intersectionTier;
  final List<String> matchTags;
  final int mutualFriends;

  /// 推荐理由标签（OpenAPI 约定必显）
  final String? reason;

  factory UserBrief.fromJson(Map<String, dynamic> j) => UserBrief(
        userId: asInt(j['user_id']) ?? 0,
        nickname: asStr(j['nickname']),
        realName: asStr(j['real_name']),
        avatarUrl: asStr(j['avatar_url']),
        relation: asStr(j['relation']),
        intersectionTier: asStr(j['intersection_tier']),
        matchTags: asStrList(j['match_tags']),
        mutualFriends: asInt(j['mutual_friends']) ?? 0,
        reason: asStr(j['reason']),
      );
}

/// UserCard —— 他人资料卡（不满足可见性的字段服务端整块缺省）
class UserCard {
  UserCard({
    required this.brief,
    this.signature,
    this.educations = const [],
    this.hometownDisplay,
    this.hometownRegionCode,
    this.currentCity,
    this.crossExperiences = const [],
    this.intersectionBanner,
    this.canViewMoments = false,
    this.dimiNo,
    this.momentCover,
    this.relation = 'none',
  });

  final UserBrief brief;
  final String? signature;
  final List<Education> educations;
  final String? hometownDisplay;

  /// 家乡镇级 region_code（家乡页跳转用；服务端未下发时为 null，UI 降级为不可点）
  final String? hometownRegionCode;
  final String? currentCity;
  final List<String> crossExperiences;

  /// 交集横幅分级措辞，含 V0 未验证限定句情形，直接展示
  final String? intersectionBanner;
  final bool canViewMoments;
  final String? dimiNo;

  /// 朋友圈相册封面（解析时已过 ApiConfig.resolveMediaUrl 补全为绝对地址）
  final String? momentCover;

  /// 与当前用户的关系：friend / pending_out / pending_in / blocked / none
  ///（服务端 relationBetween 判定，资料卡按钮按此渲染）
  final String relation;

  factory UserCard.fromJson(Map<String, dynamic> j) => UserCard(
        brief: UserBrief.fromJson(j),
        signature: asStr(j['signature']),
        educations: j['educations'] is List
            ? (j['educations'] as List)
                .whereType<Map<String, dynamic>>()
                .map(Education.fromJson)
                .toList()
            : const [],
        hometownDisplay: asStr(j['hometown_display']),
        hometownRegionCode: asStr(j['hometown_region_code']),
        currentCity: asStr(j['current_city']),
        crossExperiences: asStrList(j['cross_experiences']),
        intersectionBanner: asStr(j['intersection_banner']),
        canViewMoments: asBool(j['can_view_moments']),
        dimiNo: asStr(j['dimi_no']),
        momentCover: resolveMediaUrlOrNull(j['moment_cover']),
        relation: asStr(j['relation']) ?? 'none',
      );
}

/// Education —— 教育经历（含 verification_level 分层验证）
class Education {
  Education({
    this.id,
    this.stage,
    this.schoolId,
    this.schoolName,
    this.enrollYear,
    this.classNameRaw,
    this.classNameNorm,
    this.department,
    this.major,
    this.verificationLevel = 0,
    this.visibility,
  });

  final int? id;
  final String? stage;
  final int? schoolId;
  final String? schoolName;
  final int? enrollYear;
  final String? classNameRaw;
  final String? classNameNorm;
  final String? department;
  final String? major;

  /// V0 自述 / V1 同窗互证 / V2 证据验证 / V3 组织背书
  final int verificationLevel;
  final String? visibility;

  factory Education.fromJson(Map<String, dynamic> j) => Education(
        id: asInt(j['id']),
        stage: asStr(j['stage']),
        schoolId: asInt(j['school_id']),
        schoolName: asStr(j['school_name']),
        enrollYear: asInt(j['enroll_year']),
        classNameRaw: asStr(j['class_name_raw']),
        classNameNorm: asStr(j['class_name_norm']),
        department: asStr(j['department']),
        major: asStr(j['major']),
        verificationLevel: asInt(j['verification_level']) ?? 0,
        visibility: asStr(j['visibility']),
      );

  /// 「城关镇第二小学 · 1996级 · 六年2班」展示行
  String get displayLine {
    final parts = <String>[
      if (schoolName != null) schoolName!,
      if (enrollYear != null) '$enrollYear级',
      if (classNameRaw != null && classNameRaw!.isNotEmpty) classNameRaw!,
      if (department != null && department!.isNotEmpty) department!,
      if (major != null && major!.isNotEmpty) major!,
    ];
    return parts.join(' · ');
  }
}

/// School —— 学校联想搜索结果
class School {
  School({
    required this.schoolId,
    required this.name,
    this.formerNames = const [],
    this.regionCode,
    this.stage,
  });

  final int schoolId;
  final String name;
  final List<String> formerNames;
  final String? regionCode;
  final String? stage;

  factory School.fromJson(Map<String, dynamic> j) => School(
        schoolId: asInt(j['school_id']) ?? 0,
        name: asStr(j['name']) ?? '',
        formerNames: asStrList(j['former_names']),
        regionCode: asStr(j['region_code']),
        stage: asStr(j['stage']),
      );
}

/// DiscoverResult —— 检索/推荐统一结果（总数模糊化 + page 分页；
/// 服务端 next_cursor 为 String(page+1) 或 null，模型只透传不解析）
class DiscoverResult {
  DiscoverResult({
    this.totalMasked,
    this.items = const [],
    this.nextCursor,
  });

  /// 防爬：总数模糊化，如 "10+"
  final String? totalMasked;
  final List<UserBrief> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory DiscoverResult.fromJson(Map<String, dynamic> j) => DiscoverResult(
        totalMasked: asStr(j['total_masked']),
        items: j['items'] is List
            ? (j['items'] as List)
                .whereType<Map<String, dynamic>>()
                .map(UserBrief.fromJson)
                .toList()
            : const [],
        nextCursor: asStr(j['next_cursor']),
      );
}

/// FriendRequest —— 好友申请（含交集快照）
class FriendRequest {
  FriendRequest({
    required this.id,
    this.fromUser,
    this.toUserId,
    this.verifyMsg,
    this.attachRealName = true,
    this.attachEducation = false,
    this.intersectionSnapshot,
    this.status = 'pending',
    this.expireAt,
  });

  final int id;
  final UserBrief? fromUser;
  final int? toUserId;
  final String? verifyMsg;
  final bool attachRealName;
  final bool attachEducation;

  /// 申请当刻冻结的交集证据（§22.2）
  final String? intersectionSnapshot;
  final String status;
  final String? expireAt;

  bool get isPending => status == 'pending';

  factory FriendRequest.fromJson(Map<String, dynamic> j) => FriendRequest(
        id: asInt(j['id']) ?? 0,
        fromUser: j['from_user'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['from_user'] as Map<String, dynamic>)
            : null,
        toUserId: asInt(j['to_user_id']),
        verifyMsg: asStr(j['verify_msg']),
        attachRealName: asBool(j['attach_real_name'], true),
        attachEducation: asBool(j['attach_education']),
        intersectionSnapshot: asStr(j['intersection_snapshot']),
        status: asStr(j['status']) ?? 'pending',
        expireAt: asStr(j['expire_at']),
      );
}

/// Conversation —— 会话
class Conversation {
  Conversation({
    required this.convId,
    this.convType = 'single',
    this.title = '',
    this.avatarUrl,
    this.lastMsgSummary,
    this.lastMsgTime,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.memberCount,
    this.groupKind,
    this.intersectionBanner,
    this.peerId,
  });

  final int convId;
  final String convType;
  final String title;
  final String? avatarUrl;
  final String? lastMsgSummary;
  final String? lastMsgTime;
  final int unreadCount;
  final bool isPinned;
  final bool isMuted;

  /// 群会话成员数（conv_type='group' 时由服务端下发）
  final int? memberCount;

  /// 群种类：'class'=班级群 / 'hometown'=老乡群 / null=未知（群资料页据此分 API 与文案）
  final String? groupKind;

  bool get isGroup => convType == 'group';

  /// 单聊顶部交集标签条
  final String? intersectionBanner;

  /// 单聊对端 user_id（契约未显式给出，联调时以后端返回为准）
  final int? peerId;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        convId: asInt(j['conv_id']) ?? 0,
        convType: asStr(j['conv_type']) ?? 'single',
        title: asStr(j['title']) ?? '',
        avatarUrl: asStr(j['avatar_url']),
        lastMsgSummary: asStr(j['last_msg_summary']),
        lastMsgTime: asStr(j['last_msg_time']),
        unreadCount: asInt(j['unread_count']) ?? 0,
        isPinned: asBool(j['is_pinned']),
        isMuted: asBool(j['is_muted']),
        memberCount: asInt(j['member_count']),
        groupKind: asStr(j['group_kind']),
        intersectionBanner: asStr(j['intersection_banner']),
        peerId: asInt(j['peer_user_id'] ?? j['peer_id']),
      );
}

/// Message —— 单聊消息
class Message {
  Message({
    required this.msgId,
    this.convId,
    this.sender,
    this.msgType = 'text',
    this.content = '',
    this.status = 'delivered',
    this.clientMsgId,
    this.createdAt,
  });

  final int msgId;
  final int? convId;
  final UserBrief? sender;
  final String msgType;
  final String content;
  final String status;
  final String? clientMsgId;
  final String? createdAt;

  bool get isSystem => msgType == 'system';

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        msgId: asInt(j['msg_id']) ?? 0,
        convId: asInt(j['conv_id']),
        sender: j['sender'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['sender'] as Map<String, dynamic>)
            : null,
        msgType: asStr(j['msg_type']) ?? 'text',
        content: asStr(j['content']) ?? '',
        status: asStr(j['status']) ?? 'delivered',
        clientMsgId: asStr(j['client_msg_id']),
        createdAt: asStr(j['created_at']),
      );
}

/// PrivacySettings —— 隐私设置全量
class PrivacySettings {
  PrivacySettings({
    this.friendVerifyRequired = true,
    this.nameMode = 'balanced',
    Map<String, bool>? addMeVia,
    this.hometownVisibility = 'friends',
    this.currentCityVisible = true,
    this.strangerMoments10 = false,
    this.readReceipt = false,
    this.typingVisible = true,
    this.friendMomentsRange = 'all',
    this.groupTempChat = false,
    this.notifyWhenSearched = false,
    this.personalizedRecommend = true,
    this.femaleProtect = false,
  }) : addMeVia = addMeVia ??
            {
              'dimi_no': true,
              'phone': true,
              'school_search': true,
              'hometown_search': true,
              'group': true,
              'business_card': true,
              'contact_match': true,
            };

  bool friendVerifyRequired;

  /// 真名可见三档：open / balanced / strict
  String nameMode;

  /// 添加我的方式开关
  Map<String, bool> addMeVia;
  String hometownVisibility;
  bool currentCityVisible;
  bool strangerMoments10;
  bool readReceipt;

  /// 输入状态可见（设置页 UI 未暴露，仅透传防全量回传丢字段）
  bool typingVisible;

  /// 好友可见朋友圈范围（如 all / three_days / half_year，取值由服务端约定；
  /// UI 未暴露，仅透传防丢）
  String friendMomentsRange;

  bool groupTempChat;
  bool notifyWhenSearched;

  /// 算法备案要求的个性化推荐总开关
  bool personalizedRecommend;

  /// 女生保护（服务端默认：女性或未成年人开启；UI 未暴露，仅透传防丢）
  bool femaleProtect;

  factory PrivacySettings.fromJson(Map<String, dynamic> j) {
    final via = <String, bool>{};
    if (j['add_me_via'] is Map) {
      (j['add_me_via'] as Map)
          .forEach((k, v) => via[k.toString()] = asBool(v, true));
    }
    return PrivacySettings(
      friendVerifyRequired: asBool(j['friend_verify_required'], true),
      nameMode: asStr(j['name_mode']) ?? 'balanced',
      addMeVia: via.isEmpty ? null : via,
      hometownVisibility: asStr(j['hometown_visibility']) ?? 'friends',
      currentCityVisible: asBool(j['current_city_visible'], true),
      strangerMoments10: asBool(j['stranger_moments_10']),
      readReceipt: asBool(j['read_receipt']),
      typingVisible: asBool(j['typing_visible'], true),
      friendMomentsRange: asStr(j['friend_moments_range']) ?? 'all',
      groupTempChat: asBool(j['group_temp_chat']),
      notifyWhenSearched: asBool(j['notify_when_searched']),
      personalizedRecommend: asBool(j['personalized_recommend'], true),
      femaleProtect: asBool(j['female_protect']),
    );
  }

  Map<String, dynamic> toJson() => {
        'friend_verify_required': friendVerifyRequired,
        'name_mode': nameMode,
        'add_me_via': addMeVia,
        'hometown_visibility': hometownVisibility,
        'current_city_visible': currentCityVisible,
        'stranger_moments_10': strangerMoments10,
        'read_receipt': readReceipt,
        'typing_visible': typingVisible,
        'friend_moments_range': friendMomentsRange,
        'group_temp_chat': groupTempChat,
        'notify_when_searched': notifyWhenSearched,
        'personalized_recommend': personalizedRecommend,
        'female_protect': femaleProtect,
      };
}

/// POST /users/me/educations 的返回：经历 + 该班已注册同学数（冷启动钩子）
class EducationCreateResult {
  EducationCreateResult({this.education, this.registeredCount = 0});

  final Education? education;
  final int registeredCount;

  factory EducationCreateResult.fromJson(Map<String, dynamic> j) =>
      EducationCreateResult(
        education: j['education'] is Map<String, dynamic>
            ? Education.fromJson(j['education'] as Map<String, dynamic>)
            : null,
        registeredCount: asInt(j['registered_count']) ?? 0,
      );
}

/// 行政区划（省 1 / 市 2 / 区县 3 / 乡镇 4）
class Region {
  Region({required this.code, required this.name, required this.level});

  final String code;
  final String name;
  final int level;

  factory Region.fromJson(Map<String, dynamic> j) => Region(
        code: asStr(j['code']) ?? '',
        name: asStr(j['name']) ?? '',
        level: asInt(j['level']) ?? 0,
      );
}

/// 我的家乡/现居地条目（GET /users/me/hometown）
class HometownEntry {
  HometownEntry({
    required this.type,
    required this.regionCode,
    this.regionName,
    this.path = const [],
    this.visibility = 'public',
  });

  /// 1 家乡 / 2 现居地
  final int type;
  final String regionCode;
  final String? regionName;
  final List<String> path;
  final String visibility;

  String get displayPath =>
      path.isEmpty ? (regionName ?? regionCode) : path.join(' · ');

  factory HometownEntry.fromJson(Map<String, dynamic> j) => HometownEntry(
        type: asInt(j['type']) ?? 1,
        regionCode: asStr(j['region_code']) ?? '',
        regionName: asStr(j['region_name']),
        path: j['path'] is List
            ? (j['path'] as List).whereType<String>().toList()
            : const [],
        visibility: asStr(j['visibility']) ?? 'public',
      );
}

/// 好友条目：UserBrief + 备注/标签/星标（GET /friends）
class FriendEntry {
  FriendEntry({
    required this.brief,
    this.remarkName,
    this.tags = const [],
    this.isStarred = false,
    this.groupId,
  });

  final UserBrief brief;
  final String? remarkName;
  final List<String> tags;
  final bool isStarred;

  /// 所在分组 id（本人视角）；null 为未分组
  final int? groupId;

  int get userId => brief.userId;

  /// 好友署名优先级：备注 > 真名 > 昵称（§20.6）
  String get displayName =>
      remarkName ?? brief.realName ?? brief.nickname ?? '未命名';

  factory FriendEntry.fromJson(Map<String, dynamic> j) => FriendEntry(
        brief: UserBrief.fromJson(j),
        remarkName: asStr(j['remark_name']),
        tags: j['tags'] is List
            ? (j['tags'] as List).whereType<String>().toList()
            : const [],
        isStarred: j['is_starred'] == true,
        groupId: asInt(j['group_id']),
      );
}

/// 好友列表分页结果；未解锁时高隐私组好友不出现在 items，由 lockedCount 报告数量
class FriendsPage {
  FriendsPage({
    this.items = const [],
    this.nextCursor,
    this.unlocked = true,
    this.lockedCount = 0,
  });

  final List<FriendEntry> items;
  final String? nextCursor;
  final bool unlocked;
  final int lockedCount;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;
}

/// 联系人分组（GET /contact-groups）；高隐私组未解锁时 memberCount 为 null
class ContactGroup {
  ContactGroup({
    required this.groupId,
    required this.name,
    this.privacyLevel = 'normal',
    this.memberCount,
  });

  final int groupId;
  final String name;
  final String privacyLevel;
  final int? memberCount;

  bool get isHigh => privacyLevel == 'high';

  factory ContactGroup.fromJson(Map<String, dynamic> j) => ContactGroup(
        groupId: asInt(j['group_id']) ?? 0,
        name: asStr(j['name']) ?? '',
        privacyLevel: asStr(j['privacy_level']) ?? 'normal',
        memberCount: asInt(j['member_count']),
      );
}

/// 登录设备条目（GET /auth/devices）
class DeviceSession {
  DeviceSession({
    required this.deviceId,
    required this.deviceInfo,
    this.current = false,
    this.loginAt,
  });

  final int deviceId;
  final String deviceInfo;
  final bool current;
  final String? loginAt;

  factory DeviceSession.fromJson(Map<String, dynamic> j) => DeviceSession(
        deviceId: asInt(j['device_id']) ?? 0,
        deviceInfo: asStr(j['device_info']) ?? '未知设备',
        current: j['current'] == true,
        loginAt: asStr(j['login_at']),
      );
}

/// 滑块验证码挑战（GET /captcha/slider，免鉴权）
class SliderChallenge {
  SliderChallenge({
    required this.captchaId,
    this.width = 280,
    this.height = 160,
    this.notchY = 60,
    this.bgSeed = '',
    this.expiresIn = 300,
  });

  final String captchaId;
  final int width;
  final int height;

  /// 缺口中心纵坐标（缺口横坐标由服务端持有，客户端只提交拖动偏移 x）
  final int notchY;
  final String bgSeed;
  final int expiresIn;

  factory SliderChallenge.fromJson(Map<String, dynamic> j) => SliderChallenge(
        captchaId: asStr(j['captcha_id']) ?? '',
        width: asInt(j['width']) ?? 280,
        height: asInt(j['height']) ?? 160,
        notchY: asInt(j['notch_y']) ?? 60,
        bgSeed: asStr(j['bg_seed']) ?? '',
        expiresIn: asInt(j['expires_in']) ?? 300,
      );
}

/// 谁看过我的联系方式（GET /users/me/contact-viewers）：UserBrief + 访问时间
class ContactViewer {
  ContactViewer({required this.user, this.viewedAt});

  final UserBrief user;
  final String? viewedAt;

  factory ContactViewer.fromJson(Map<String, dynamic> j) => ContactViewer(
        user: UserBrief.fromJson(j),
        viewedAt: asStr(j['viewed_at']),
      );
}

/// 朋友圈评论（feed 预览无 id，详情含 id/reply_to_user_id）
class MomentComment {
  MomentComment({
    this.canDelete = false,
    this.id,
    this.fromUser,
    this.replyToUserId,
    this.replyToUser,
    required this.content,
    this.createdAt,
  });

  final int? id;
  final bool canDelete;
  final UserBrief? fromUser;
  final int? replyToUserId;

  /// 回复对象的脱敏档案（服务端在可见范围内解析，解析不到为 null）
  final UserBrief? replyToUser;
  final String content;
  final String? createdAt;

  String get displayName => fromUser?.realName ?? fromUser?.nickname ?? '未命名';

  /// 被回复人显示名（无回复关系或不可解析为 null）
  String? get replyToName => replyToUser == null
      ? null
      : (replyToUser!.realName ?? replyToUser!.nickname);

  factory MomentComment.fromJson(Map<String, dynamic> j) => MomentComment(
        canDelete: asBool(j['can_delete']),
        id: asInt(j['id']),
        fromUser: j['from_user'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['from_user'] as Map<String, dynamic>)
            : null,
        replyToUserId: asInt(j['reply_to_user_id']),
        replyToUser: j['reply_to_user'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['reply_to_user'] as Map<String, dynamic>)
            : null,
        content: asStr(j['content']) ?? '',
        createdAt: asStr(j['created_at']),
      );
}

/// 朋友圈动态（feed / 详情 / 相册页共用；互动列表已由服务端按好友关系过滤）
class ArticleCommentPage {
  ArticleCommentPage(
      {this.items = const [], this.totalCount = 0, this.nextCursor});
  final List<MomentComment> items;
  final int totalCount;
  final String? nextCursor;
  factory ArticleCommentPage.fromJson(Map<String, dynamic> j) =>
      ArticleCommentPage(
        items: (j['items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(MomentComment.fromJson)
            .toList(),
        totalCount: asInt(j['total_count']) ?? 0,
        nextCursor: asStr(j['next_cursor']),
      );
}

class Moment {
  Moment({
    required this.momentId,
    this.author,
    this.contentType = 'text',
    this.content,
    this.media = const [],
    this.locationPoi,
    this.visibility = 'public',
    this.likeCount = 0,
    this.liked = false,
    this.likes = const [],
    this.commentCount = 0,
    this.commentPreview = const [],
    this.comments = const [],
    this.createdAt,
    this.isOwn = false,
  });

  final int momentId;
  final UserBrief? author;
  final String contentType;
  final String? content;
  final List<String> media;
  final String? locationPoi;
  final String visibility;
  final List<MomentComment> commentPreview;
  final List<MomentComment> comments;
  final String? createdAt;
  final bool isOwn;

  /// 点赞名单（仅共同好友口径，服务端已过滤）：微信式「♥ 张三、李四」
  final List<UserBrief> likes;

  /// 可见评论总数（comment_preview 固定截 3 条，用此数判断是否「查看全部 N 条评论」）
  final int commentCount;

  /// 可变：点赞本地乐观更新用
  bool liked;
  int likeCount;

  String get authorName => author?.realName ?? author?.nickname ?? '未命名';

  /// 可见范围六档中文文案
  String get visibilityLabel => switch (visibility) {
        'private' => '私密',
        'partial' => '部分可见',
        'excluded' => '不给谁看',
        'classmates' => '同学圈',
        'fellows' => '老乡圈',
        _ => '公开',
      };

  factory Moment.fromJson(Map<String, dynamic> j) => Moment(
        momentId: asInt(j['moment_id']) ?? 0,
        author: j['author'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['author'] as Map<String, dynamic>)
            : null,
        contentType: asStr(j['content_type']) ?? 'text',
        content: asStr(j['content']),
        media: asStrList(j['media']).map(ApiConfig.resolveMediaUrl).toList(),
        locationPoi: asStr(j['location_poi']),
        visibility: asStr(j['visibility']) ?? 'public',
        likeCount: asInt(j['like_count']) ?? 0,
        liked: j['liked'] == true,
        likes: j['likes'] is List
            ? (j['likes'] as List)
                .whereType<Map<String, dynamic>>()
                .map(UserBrief.fromJson)
                .toList()
            : const [],
        commentCount: asInt(j['comment_count']) ?? 0,
        commentPreview: j['comment_preview'] is List
            ? (j['comment_preview'] as List)
                .whereType<Map<String, dynamic>>()
                .map(MomentComment.fromJson)
                .toList()
            : const [],
        comments: j['comments'] is List
            ? (j['comments'] as List)
                .whereType<Map<String, dynamic>>()
                .map(MomentComment.fromJson)
                .toList()
            : const [],
        createdAt: asStr(j['created_at']),
        isOwn: j['is_own'] == true,
      );
}

/// ClassGroupInfo —— 班级群（/class-groups/mine 的 group 字段；
/// join 响应同构，created 表示本次是否新建了群）
class ClassGroupInfo {
  ClassGroupInfo({
    required this.convId,
    this.title,
    this.memberCount,
    this.announcement = '',
    this.joined = false,
    this.unreadCount = 0,
    this.created = false,
  });

  final int convId;
  final String? title;

  /// 群成员数（接口缺字段时为 null，消费方判空省略展示）
  final int? memberCount;
  final String announcement;
  final bool joined;
  final int unreadCount;
  final bool created;

  factory ClassGroupInfo.fromJson(Map<String, dynamic> j) => ClassGroupInfo(
        convId: asInt(j['conv_id']) ?? 0,
        title: asStr(j['title']),
        memberCount: asInt(j['member_count']),
        announcement: asStr(j['announcement']) ?? '',
        joined: asBool(j['joined']),
        unreadCount: asInt(j['unread_count']) ?? 0,
        created: asBool(j['created']),
      );
}

/// ClassGroupUnit —— 我的班级单元 + 对应班级群（群未建时 group 为 null）
class ClassGroupUnit {
  ClassGroupUnit({
    required this.schoolId,
    this.schoolName,
    required this.enrollYear,
    this.className = '',
    this.group,
  });

  final int schoolId;
  final String? schoolName;
  final int enrollYear;

  /// 班级原文（join 时原样上报，服务端规范化）
  final String className;
  final ClassGroupInfo? group;

  factory ClassGroupUnit.fromJson(Map<String, dynamic> j) => ClassGroupUnit(
        schoolId: asInt(j['school_id']) ?? 0,
        schoolName: asStr(j['school_name']),
        enrollYear: asInt(j['enroll_year']) ?? 0,
        className: asStr(j['class_name']) ?? '',
        group: j['group'] is Map<String, dynamic>
            ? ClassGroupInfo.fromJson(j['group'] as Map<String, dynamic>)
            : null,
      );
}

/// HometownGroupUnit —— 我的老乡单元（家乡 type=1 的 region_code 前 4 位，同市）
/// + 对应老乡群（未设家乡时 /hometown-groups/mine 返回空列表；
/// 群未建时 group 为 null）。群信息复用 ClassGroupInfo。
class HometownGroupUnit {
  HometownGroupUnit({
    this.regionCode = '',
    this.regionName,
    this.group,
  });

  final String regionCode;
  final String? regionName;
  final ClassGroupInfo? group;

  factory HometownGroupUnit.fromJson(Map<String, dynamic> j) =>
      HometownGroupUnit(
        regionCode: asStr(j['region_code']) ?? '',
        regionName: asStr(j['region_name']),
        group: j['group'] is Map<String, dynamic>
            ? ClassGroupInfo.fromJson(j['group'] as Map<String, dynamic>)
            : null,
      );
}

/// ClassGroupMember —— 群成员（UserBrief 渐显展示值 + is_owner），禁止二次加工
class ClassGroupMember {
  ClassGroupMember({required this.brief, this.isOwner = false});

  final UserBrief brief;
  final bool isOwner;

  String get displayName => brief.realName ?? brief.nickname ?? '未命名';

  factory ClassGroupMember.fromJson(Map<String, dynamic> j) => ClassGroupMember(
        brief: UserBrief.fromJson(j),
        isOwner: asBool(j['is_owner']),
      );
}

// ==================== 家乡页（Hometown Pages，M1） ====================
// 对齐《DIMI围城_家乡页与共建体系设计_V1》§10 契约增量：
// 镇级页面聚合 + 分类内容分页 + 投稿/点赞/关注。

/// HometownPageGroup —— 家乡页底部「老乡群」入口（group 字段；无群时为 null）
class HometownPageGroup {
  HometownPageGroup({required this.convId, this.title, this.memberCount});

  final int convId;
  final String? title;
  final int? memberCount;

  factory HometownPageGroup.fromJson(Map<String, dynamic> j) =>
      HometownPageGroup(
        convId: asInt(j['conv_id']) ?? 0,
        title: asStr(j['title']),
        memberCount: asInt(j['member_count']),
      );
}

/// HometownPage —— GET /hometown-pages/{code} 页面聚合
class HometownPage {
  HometownPage({
    required this.regionCode,
    this.regionPath = const [],
    this.coverMedia,
    this.intro = '',
    this.followerCount = 0,
    this.contentCount = 0,
    this.isFollowing = false,
    this.canPost = false,
    this.group,
  });

  final String regionCode;

  /// 镇名全路径（省/市/区县/镇名称链）
  final List<String> regionPath;

  /// 封面图（fromJson 时已解析为完整 URL）
  final String? coverMedia;
  final String intro;

  /// 可变：关注本地乐观更新用（失败回滚）
  int followerCount;
  final int contentCount;

  /// 可变：关注本地乐观更新用
  bool isFollowing;

  /// 服务端按籍贯匹配判定：仅当地老乡可投稿
  final bool canPost;
  final HometownPageGroup? group;

  /// 镇名（路径最后一级，封面兜底与标题用）；
  /// region_path 空时兜底「家乡页」，不露 code 数字串
  String get townName => regionPath.isNotEmpty ? regionPath.last : '家乡页';

  /// 全路径展示（「河南 · 周口 · 沈丘 · 城关镇」）；
  /// region_path 空时兜底「家乡页」，不露 code 数字串
  String get displayPath => regionPath.isEmpty ? '家乡页' : regionPath.join(' · ');

  factory HometownPage.fromJson(Map<String, dynamic> j) => HometownPage(
        regionCode: asStr(j['region_code']) ?? '',
        regionPath: j['region_path'] is List
            ? (j['region_path'] as List).whereType<String>().toList()
            : const [],
        coverMedia: asStr(j['cover_media']) == null
            ? null
            : ApiConfig.resolveMediaUrl(asStr(j['cover_media'])!),
        intro: asStr(j['intro']) ?? '',
        followerCount: asInt(j['follower_count']) ?? 0,
        contentCount: asInt(j['content_count']) ?? 0,
        isFollowing: asBool(j['is_following']),
        canPost: asBool(j['can_post']),
        group: j['group'] is Map<String, dynamic>
            ? HometownPageGroup.fromJson(j['group'] as Map<String, dynamic>)
            : null,
      );
}

/// HometownContent —— 家乡页投稿内容（列表/详情/上卷县页内容共用）
class HometownContent {
  HometownContent({
    required this.contentId,
    this.category = 'scenery',
    this.title = '',
    this.body = '',
    this.media = const [],
    this.author,
    this.viewCount = 0,
    this.likeCount = 0,
    this.liked = false,
    this.createdAt,
  });

  final int contentId;

  /// scenery 风光 / product 特产 / craft 手艺 / story 故事
  final String category;
  final String title;
  final String body;

  /// 图集（fromJson 时已解析为完整 URL）
  final List<String> media;
  final UserBrief? author;
  final int viewCount;
  final String? createdAt;

  /// 可变：点赞本地乐观更新用
  bool liked;
  int likeCount;

  String get authorName => author?.realName ?? author?.nickname ?? '未命名';

  /// 分类中文标签
  String get categoryLabel => switch (category) {
        'product' => '特产',
        'craft' => '手艺',
        'story' => '故事',
        _ => '风光',
      };

  factory HometownContent.fromJson(Map<String, dynamic> j) => HometownContent(
        contentId: asInt(j['content_id']) ?? 0,
        category: asStr(j['category']) ?? 'scenery',
        title: asStr(j['title']) ?? '',
        body: asStr(j['body']) ?? '',
        media: asStrList(j['media']).map(ApiConfig.resolveMediaUrl).toList(),
        author: j['author'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['author'] as Map<String, dynamic>)
            : null,
        viewCount: asInt(j['view_count']) ?? 0,
        likeCount: asInt(j['like_count']) ?? 0,
        liked: asBool(j['liked']),
        createdAt: asStr(j['created_at']),
      );
}

/// HometownContentPage —— GET /hometown-pages/{code}/contents 分页结果；
/// rolled_up=true 时镇页内容不足，rollup_items 为县页 TOP 内容（低密度兜底）
class HometownContentPage {
  HometownContentPage({
    this.items = const [],
    this.nextCursor,
    this.rolledUp = false,
    this.rollupItems = const [],
  });

  final List<HometownContent> items;
  final String? nextCursor;
  final bool rolledUp;
  final List<HometownContent> rollupItems;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory HometownContentPage.fromJson(Map<String, dynamic> j) =>
      HometownContentPage(
        items: j['items'] is List
            ? (j['items'] as List)
                .whereType<Map<String, dynamic>>()
                .map(HometownContent.fromJson)
                .toList()
            : const [],
        nextCursor: asStr(j['next_cursor']),
        rolledUp: asBool(j['rolled_up']),
        rollupItems: j['rollup_items'] is List
            ? (j['rollup_items'] as List)
                .whereType<Map<String, dynamic>>()
                .map(HometownContent.fromJson)
                .toList()
            : const [],
      );
}

// ==================== 觅豆钱包 / 红包 / 打赏（P0 纯赠送体系） ====================
// 红线：觅豆只能任务/活跃赠送获得，无充值、无提现、无现金价值；
// 模型只做透传，UI 不得出现任何与人民币/现金相关的表述。

/// CoinTask —— 觅豆任务（GET /wallet 的 tasks 项）
class CoinTask {
  CoinTask({
    required this.code,
    this.amount = 0,
    this.period = '',
    this.remark = '',
    this.done = false,
  });

  final String code;
  final int amount;

  /// day 每日一次 / once 一次性 / per_target 每目标一次
  final String period;
  final String remark;
  final bool done;

  factory CoinTask.fromJson(Map<String, dynamic> j) => CoinTask(
        code: asStr(j['code']) ?? '',
        amount: asInt(j['amount']) ?? 0,
        period: asStr(j['period']) ?? '',
        remark: asStr(j['remark']) ?? '',
        done: asBool(j['done']),
      );
}

/// WalletInfo —— 觅豆钱包总览（GET /wallet）
class WalletInfo {
  WalletInfo({
    this.balance = 0,
    this.totalEarned = 0,
    this.totalSpent = 0,
    this.todayCheckedIn = false,
    this.tasks = const [],
  });

  final int balance;
  final int totalEarned;
  final int totalSpent;
  final bool todayCheckedIn;
  final List<CoinTask> tasks;

  factory WalletInfo.fromJson(Map<String, dynamic> j) => WalletInfo(
        balance: asInt(j['balance']) ?? 0,
        totalEarned: asInt(j['total_earned']) ?? 0,
        totalSpent: asInt(j['total_spent']) ?? 0,
        todayCheckedIn: asBool(j['today_checked_in']),
        tasks: j['tasks'] is List
            ? (j['tasks'] as List)
                .whereType<Map<String, dynamic>>()
                .map(CoinTask.fromJson)
                .toList()
            : const [],
      );
}

/// CoinTransaction —— 收支明细（GET /wallet/transactions）
class CoinTransaction {
  CoinTransaction({
    required this.id,
    this.bizType = '',
    this.direction = 'in',
    this.amount = 0,
    this.balanceAfter = 0,
    this.remark = '',
    this.createdAt,
  });

  final int id;
  final String bizType;

  /// in 收入 / out 支出
  final String direction;
  final int amount;
  final int balanceAfter;
  final String remark;
  final String? createdAt;

  bool get isIn => direction == 'in';

  factory CoinTransaction.fromJson(Map<String, dynamic> j) => CoinTransaction(
        id: asInt(j['id']) ?? 0,
        bizType: asStr(j['biz_type']) ?? '',
        direction: asStr(j['direction']) ?? 'in',
        amount: asInt(j['amount']) ?? 0,
        balanceAfter: asInt(j['balance_after']) ?? 0,
        remark: asStr(j['remark']) ?? '',
        createdAt: asStr(j['created_at']),
      );
}

/// RedPacketClaim —— 红包领取记录
class RedPacketClaim {
  RedPacketClaim({
    this.user,
    this.amount = 0,
    this.isBest = false,
    this.createdAt,
  });

  final UserBrief? user;
  final int amount;
  final bool isBest;
  final String? createdAt;

  String get displayName => user?.realName ?? user?.nickname ?? '未命名';

  factory RedPacketClaim.fromJson(Map<String, dynamic> j) => RedPacketClaim(
        user: j['user'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['user'] as Map<String, dynamic>)
            : null,
        amount: asInt(j['amount']) ?? 0,
        isBest: asBool(j['is_best']),
        createdAt: asStr(j['created_at']),
      );
}

/// 本人在该红包上的领取结果（packet.my_claim）
class RedPacketMyClaim {
  RedPacketMyClaim({this.amount = 0, this.isBest = false});

  final int amount;
  final bool isBest;

  factory RedPacketMyClaim.fromJson(Map<String, dynamic> j) => RedPacketMyClaim(
        amount: asInt(j['amount']) ?? 0,
        isBest: asBool(j['is_best']),
      );
}

/// RedPacket —— 红包（status：active 可领 / finished 已领完 / expired 已过期退回）
class RedPacket {
  RedPacket({
    required this.packetId,
    this.convId,
    this.msgId,
    this.sender,
    this.type = 'normal',
    this.totalAmount = 0,
    this.count = 0,
    this.claimedAmount = 0,
    this.claimedCount = 0,
    this.greeting,
    this.status = 'active',
    this.expireAt,
    this.createdAt,
    this.claims = const [],
    this.myClaim,
  });

  final String packetId;
  final int? convId;
  final int? msgId;
  final UserBrief? sender;

  /// normal 普通 / luck 拼手气
  final String type;
  final int totalAmount;
  final int count;
  final int claimedAmount;
  final int claimedCount;
  final String? greeting;
  final String status;
  final String? expireAt;
  final String? createdAt;
  final List<RedPacketClaim> claims;
  final RedPacketMyClaim? myClaim;

  bool get isActive => status == 'active';
  bool get isFinished => status == 'finished';
  bool get isExpired => status == 'expired';

  String get senderName => sender?.realName ?? sender?.nickname ?? '未命名';

  factory RedPacket.fromJson(Map<String, dynamic> j) => RedPacket(
        packetId: asStr(j['packet_id']) ?? '',
        convId: asInt(j['conv_id']),
        msgId: asInt(j['msg_id']),
        sender: j['sender'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['sender'] as Map<String, dynamic>)
            : null,
        type: asStr(j['type']) ?? 'normal',
        totalAmount: asInt(j['total_amount']) ?? 0,
        count: asInt(j['count']) ?? 0,
        claimedAmount: asInt(j['claimed_amount']) ?? 0,
        claimedCount: asInt(j['claimed_count']) ?? 0,
        greeting: asStr(j['greeting']),
        status: asStr(j['status']) ?? 'active',
        expireAt: asStr(j['expire_at']),
        createdAt: asStr(j['created_at']),
        claims: j['claims'] is List
            ? (j['claims'] as List)
                .whereType<Map<String, dynamic>>()
                .map(RedPacketClaim.fromJson)
                .toList()
            : const [],
        myClaim: j['my_claim'] is Map<String, dynamic>
            ? RedPacketMyClaim.fromJson(j['my_claim'] as Map<String, dynamic>)
            : null,
      );
}

/// RedPacketContent —— red_packet 消息卡 content（JSON 字符串）的解析结果；
/// 解析失败返回 null（气泡兜底显示 [红包]）
class RedPacketContent {
  RedPacketContent({
    required this.packetId,
    this.type = 'normal',
    this.totalAmount = 0,
    this.count = 0,
    this.greeting,
  });

  final String packetId;
  final String type;
  final int totalAmount;
  final int count;
  final String? greeting;

  static RedPacketContent? tryParse(String content) {
    try {
      final m = jsonDecode(content);
      if (m is Map && m['packet_id'] != null) {
        return RedPacketContent(
          packetId: m['packet_id'].toString(),
          type: asStr(m['type']) ?? 'normal',
          totalAmount: asInt(m['total_amount']) ?? 0,
          count: asInt(m['count']) ?? 0,
          greeting: asStr(m['greeting']),
        );
      }
    } on Exception {
      // 非约定 JSON，走兜底
    }
    return null;
  }
}

/// GiftEntry —— 动态打赏记录（GET /moments/{id}/gifts 的 items 项）
class GiftEntry {
  GiftEntry({this.fromUser, this.coinAmount = 0, this.createdAt});

  final UserBrief? fromUser;
  final int coinAmount;
  final String? createdAt;

  String get displayName => fromUser?.realName ?? fromUser?.nickname ?? '未命名';

  factory GiftEntry.fromJson(Map<String, dynamic> j) => GiftEntry(
        fromUser: j['from_user'] is Map<String, dynamic>
            ? UserBrief.fromJson(j['from_user'] as Map<String, dynamic>)
            : null,
        coinAmount: asInt(j['coin_amount']) ?? 0,
        createdAt: asStr(j['created_at']),
      );
}

/// MomentGifts —— 动态打赏汇总（GET /moments/{id}/gifts）
class MomentGifts {
  MomentGifts(
      {this.totalCount = 0, this.totalCoins = 0, this.items = const []});

  final int totalCount;
  final int totalCoins;
  final List<GiftEntry> items;

  factory MomentGifts.fromJson(Map<String, dynamic> j) => MomentGifts(
        totalCount: asInt(j['total_count']) ?? 0,
        totalCoins: asInt(j['total_coins']) ?? 0,
        items: j['items'] is List
            ? (j['items'] as List)
                .whereType<Map<String, dynamic>>()
                .map(GiftEntry.fromJson)
                .toList()
            : const [],
      );
}
