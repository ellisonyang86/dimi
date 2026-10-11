/// 隐私设置（原型屏⑧）：
/// 真名三档（开放/平衡/严格）+ 添加方式开关 + 个性化推荐总开关。
/// 变更即 PUT /privacy/settings（服务端约定收窄 5 分钟内全端生效）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';
import '../widgets/common/dimi_section.dart';
import 'algorithm_disclosure.dart';
import 'contact_viewers.dart';
import 'data_export.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  static const routeName = '/privacy';

  /// 是否已设置隐私密码的本地标记（服务端不提供查询接口，设置成功后写入）
  static const _kHasPrivacyPassword = 'dimi.has_privacy_password';

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  PrivacySettings? _settings;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// 联系方式分项可见范围（独立加载/保存，与上方总设置互不影响）
  Map<String, String> _contactsVisibility = const {
    'phone': 'self',
    'wechat': 'self',
    'email': 'self',
  };
  bool _savingContacts = false;
  bool _hasPrivacyPassword = false;

  static const _contactLevels = {
    'self': '仅自己',
    'friends': '好友可见',
    'verified_friends': '已验证好友',
    'strong_tier': '强交集',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _loadContactsVisibility();
    _loadHasPrivacyPassword();
  }

  Future<void> _loadHasPrivacyPassword() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _hasPrivacyPassword =
        prefs.getBool(PrivacyScreen._kHasPrivacyPassword) ?? false);
  }

  /// 设置/修改高隐私分组密码：已设置过须先验旧密码
  Future<void> _editPrivacyPassword() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final hasOld = _hasPrivacyPassword;
    final result = await showDimiDialog<({String? oldPw, String pw})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(hasOld ? '修改隐私密码' : '设置隐私密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasOld) ...[
              TextField(
                controller: oldCtrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(hintText: '原隐私密码'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: newCtrl,
              obscureText: true,
              autofocus: !hasOld,
              maxLength: 64,
              decoration: const InputDecoration(
                hintText: '新隐私密码（6–64 位）',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx)
                .pop((oldPw: hasOld ? oldCtrl.text : null, pw: newCtrl.text)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    oldCtrl.dispose();
    newCtrl.dispose();
    if (result == null || !mounted) return;
    if (result.pw.length < 6) {
      _toast('隐私密码须 6–64 位');
      return;
    }
    try {
      await context
          .read<DimiApi>()
          .setPrivacyPassword(result.pw, oldPassword: result.oldPw);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PrivacyScreen._kHasPrivacyPassword, true);
      if (!mounted) return;
      setState(() => _hasPrivacyPassword = true);
      _toast(hasOld ? '隐私密码已修改' : '隐私密码已设置');
    } on ApiException catch (e) {
      if (!mounted) return;
      // 服务端判定已有密码（本地标记缺失）时补记标记
      if (e.message.contains('原隐私密码')) {
        setState(() => _hasPrivacyPassword = true);
      }
      _toast(e.message);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await context.read<DimiApi>().privacySettings();
      if (!mounted) return;
      setState(() => _settings = s);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final s = _settings;
    if (s == null || _saving) return;
    setState(() => _saving = true);
    try {
      await context.read<DimiApi>().updatePrivacySettings(s);
    } on ApiException catch (e) {
      _toast('保存失败：${e.message}');
      _load(); // 回滚为服务端最新值
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _update(VoidCallback mutate) {
    setState(mutate);
    _save();
  }

  Future<void> _loadContactsVisibility() async {
    try {
      final cv = await context.read<DimiApi>().contactsVisibility();
      if (!mounted) return;
      setState(() => _contactsVisibility = cv);
    } on ApiException {
      // 加载失败保持默认「仅自己」展示，不阻塞页面
    }
  }

  Future<void> _saveContactsVisibility() async {
    if (_savingContacts) return;
    setState(() => _savingContacts = true);
    try {
      await context
          .read<DimiApi>()
          .updateContactsVisibility(_contactsVisibility);
    } on ApiException catch (e) {
      _toast('保存失败：${e.message}');
      _loadContactsVisibility(); // 回滚为服务端最新值
    } finally {
      if (mounted) setState(() => _savingContacts = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(
        title: const Text('隐私'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: kDimiPrimary),
              ),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: kDimiPrimary),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: kDimiGray99)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final s = _settings!;
    // 微信式分组排版：白底整块 + 组内发丝分隔线 + 组间米白留白
    return ListView(
      children: [
        DimiSection(
          dividerIndent: 16,
          children: [
            _switchRow(
              '加我为朋友时需要验证',
              s.friendVerifyRequired,
              (v) => _update(() => s.friendVerifyRequired = v),
            ),
          ],
        ),
        _sectionTitle('真实姓名可见模式'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'open', label: Text('开放')),
              ButtonSegment(value: 'balanced', label: Text('平衡(默认)')),
              ButtonSegment(value: 'strict', label: Text('严格')),
            ],
            selected: {s.nameMode},
            onSelectionChanged:
                _saving ? null : (sel) => _update(() => s.nameMode = sel.first),
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? kDimiPrimary
                      : kDimiGray55),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            '平衡模式：同班/同届/同镇年龄相近者见全名，弱交集见掩码(李*娟)，无交集仅昵称。具体展示由服务端渐显矩阵判定。',
            style: TextStyle(fontSize: 14, color: kDimiGray99, height: 1.6),
          ),
        ),
        _sectionTitle('添加我的方式'),
        DimiSection(
          dividerIndent: 16,
          children: [
            _switchRow(
              'DIMI号 / 手机号',
              s.addMeVia['dimi_no'] ?? true,
              (v) => _update(() {
                s.addMeVia['dimi_no'] = v;
                s.addMeVia['phone'] = v;
              }),
            ),
            _switchRow(
              '通过学校检索到我',
              s.addMeVia['school_search'] ?? true,
              (v) => _update(() => s.addMeVia['school_search'] = v),
            ),
            _switchRow(
              '通过家乡检索到我',
              s.addMeVia['hometown_search'] ?? true,
              (v) => _update(() => s.addMeVia['hometown_search'] = v),
            ),
            _switchRow(
              '群聊中添加我',
              s.addMeVia['group'] ?? true,
              (v) => _update(() => s.addMeVia['group'] = v),
            ),
          ],
        ),
        _sectionTitle('联系方式可见范围'),
        DimiSection(
          dividerIndent: 16,
          children: [
            _contactRow('手机号', 'phone'),
            _contactRow('微信号', 'wechat'),
            _contactRow('邮箱', 'email'),
          ],
        ),
        // §20.7 双向透明：谁看过我的联系方式（近 30 天）
        DimiSection(
          children: [
            DimiSectionItem(
              icon: Icons.visibility_outlined,
              title: '谁看过我',
              subtitle: '近 30 天查看过你联系方式的人',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const ContactViewersScreen(),
              )),
            ),
          ],
        ),
        DimiSection(
          dividerIndent: 16,
          children: [
            _switchRow(
              '允许陌生人查看10条朋友圈',
              s.strangerMoments10,
              (v) => _update(() => s.strangerMoments10 = v),
            ),
            _switchRow(
              '已读回执',
              s.readReceipt,
              (v) => _update(() => s.readReceipt = v),
            ),
            _switchRow(
              '允许群内临时会话',
              s.groupTempChat,
              (v) => _update(() => s.groupTempChat = v),
            ),
            _switchRow(
              '被检索到时提醒我',
              s.notifyWhenSearched,
              (v) => _update(() => s.notifyWhenSearched = v),
            ),
          ],
        ),
        DimiSection(
          dividerIndent: 16,
          children: [
            _switchRow(
              '个性化推荐',
              s.personalizedRecommend,
              (v) => _update(() => s.personalizedRecommend = v),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const AlgorithmDisclosureScreen(),
            )),
            child: const Text(
              '查看《推荐算法基本原理公示》',
              style: TextStyle(
                fontSize: 14,
                color: kDimiPrimary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 6, 16, 20),
          child: Text(
            '依据《互联网信息服务算法推荐管理规定》提供总开关；关闭后仅按规则排序，不使用个性化特征。',
            style: TextStyle(fontSize: 14, color: kDimiGray99, height: 1.6),
          ),
        ),
        DimiSection(children: [
          DimiSectionItem(
              icon: Icons.download_outlined,
              title: '个人信息导出',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const DataExportScreen()))),
        ]),
        _sectionTitle('高隐私分组密码'),
        DimiSection(
          children: [
            ListTile(
              title: const Text('隐私密码', style: TextStyle(fontSize: 17)),
              subtitle: const Text(
                '保护高隐私分组内容，解锁后 5 分钟自动锁定',
                style: TextStyle(fontSize: 14),
              ),
              trailing: TextButton(
                onPressed: _editPrivacyPassword,
                child: Text(_hasPrivacyPassword ? '修改密码' : '设置密码'),
              ),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 6, 16, 20),
          child: Text(
            '隐私密码独立于登录密码，用于解锁高隐私分组；连续 5 次错误将锁定 30 分钟。',
            style: TextStyle(fontSize: 14, color: kDimiGray99, height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child:
          Text(text, style: const TextStyle(fontSize: 15, color: kDimiGray99)),
    );
  }

  Widget _switchRow(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      value: value,
      onChanged: _saving ? null : onChanged,
      activeThumbColor: kDimiPrimary,
    );
  }

  Widget _contactRow(String title, String field) {
    return ListTile(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      trailing: DropdownButton<String>(
        value: _contactsVisibility[field] ?? 'self',
        underline: const SizedBox.shrink(),
        style: const TextStyle(fontSize: 15, color: kDimiGray55),
        items: _contactLevels.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: _savingContacts
            ? null
            : (v) {
                if (v == null) return;
                setState(() => _contactsVisibility = {
                      ..._contactsVisibility,
                      field: v,
                    });
                _saveContactsVisibility();
              },
      ),
    );
  }
}
