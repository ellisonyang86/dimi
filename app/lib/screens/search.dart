/// 找同学检索（原型屏②）：
/// 锚点强制（学校 + 届）+ 班级/姓名可选筛选 → /discover/classmates。
/// 顶部分段切换「找同学 / 精确找人」（DIMI号/手机号 → /discover/search-user）。
/// 防爬：翻页到第 4 页（或服务端返回 42901 need_captcha）时弹滑块验证码，
/// 拿到 captcha_token 后带 token 重试原请求。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/common/dimi_finder.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/slider_captcha.dart';
import 'exact_search.dart';
import 'friend_apply.dart';
import 'profile_card.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialEducation});

  static const routeName = '/search';

  /// 从「我的班级单元卡」进入时预填锚点
  final Education? initialEducation;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _classCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  School? _school;
  int? _enrollYear;

  /// 当前锚点对应的本人经历 id（点亮名字用）；匹配不到时隐藏点亮入口
  int? _educationId;
  bool _resolvingEdu = false;

  bool _loading = false;
  List<UserBrief> _items = [];
  bool _hasMore = false;
  int _page = 0; // 已加载页数（page 语义分页，下一页 = _page + 1）
  bool _needCaptcha = false;
  bool _searched = false;
  bool _moreFilters = false;
  String? _searchError;

  /// 0 找同学 / 1 精确找人
  int _tab = 0;

  /// 滑块验证通过后暂存的一次性 captcha_token，随下一次请求发出即清空
  String? _captchaToken;

  /// 翻页超过 3 页触发人机验证（与服务端 42901 对齐）
  static const int _captchaPageThreshold = 3;

  List<int> get _yearOptions {
    final now = DateTime.now().year;
    return List<int>.generate(now - 1949, (i) => now - i);
  }

  @override
  void initState() {
    super.initState();
    final e = widget.initialEducation;
    if (e != null) {
      _school = School(
        schoolId: e.schoolId ?? 0,
        name: e.schoolName ?? '',
        stage: e.stage,
      );
      _enrollYear = e.enrollYear;
      _educationId = e.id;
      _classCtrl.text = e.classNameRaw ?? '';
      if (_school != null && _school!.schoolId > 0 && _enrollYear != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _doSearch());
      }
    }
  }

  @override
  void dispose() {
    _classCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _doSearch() async {
    if (_loading) return;
    FocusScope.of(context).unfocus();
    final school = _school;
    final year = _enrollYear;
    if (school == null || school.schoolId <= 0) {
      _toast('请先选择学校');
      return;
    }
    if (year == null) {
      _toast('请选择入学年份');
      return;
    }
    setState(() {
      _items = [];
      _searchError = null;
      _hasMore = false;
      _page = 0;
      _needCaptcha = false;
      _searched = true;
    });
    await _loadPage();
    _resolveEducationId();
  }

  /// 锚点只有 school_id+enroll_year 时，用本人经历列表反查 education_id
  Future<void> _resolveEducationId() async {
    if (_educationId != null || _resolvingEdu) return;
    final school = _school;
    final year = _enrollYear;
    if (school == null || year == null) return;
    _resolvingEdu = true;
    try {
      final list = await context.read<DimiApi>().myEducations();
      for (final e in list) {
        if (e.schoolId == school.schoolId && e.enrollYear == year) {
          if (mounted &&
              _school?.schoolId == school.schoolId &&
              _enrollYear == year) {
            setState(() => _educationId = e.id);
          }
          return;
        }
      }
    } on ApiException {
      // 反查失败则保持入口隐藏
    } finally {
      _resolvingEdu = false;
    }
  }

  Future<void> _lightUp() async {
    final eduId = _educationId;
    if (eduId == null) return;
    final ctrl = TextEditingController();
    final name = await showDimiDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('点亮名字'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            hintText: '输入 TA 的姓名（不超过 32 字）',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
            child: const Text('点亮'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final res = await context
          .read<DimiApi>()
          .lightUpName(educationId: eduId, name: name);
      if (!mounted) return;
      final count = asInt(res['registered_count']) ?? 0;
      _toast(res['rally_ready'] == true
          ? '已点亮，同班已有 $count 人归队；已达 3 人，可发起召集令'
          : '已点亮，同班已有 $count 人归队');
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  Widget _lightUpEntry() {
    return Card(
      child: InkWell(
        onTap: _lightUp,
        borderRadius: BorderRadius.circular(10),
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.lightbulb_outline, color: kDimiApricotDeep),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '没找到 TA？点亮名字，TA 注册时会被唤醒',
                  style: TextStyle(fontSize: 15, color: kDimiGray55),
                ),
              ),
              Icon(Icons.chevron_right, color: kDimiGray99),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadPage() async {
    final school = _school;
    final year = _enrollYear;
    if (school == null || year == null || _loading) return;

    // 本地页深限制：翻到第 4 页即要求人机验证（防爬，对齐原型提示）
    if (_page >= _captchaPageThreshold && _captchaToken == null) {
      setState(() => _needCaptcha = true);
      return;
    }

    setState(() {
      _loading = true;
      _searchError = null;
    });
    // 一次性 token：随本次请求发出即清空
    final captchaToken = _captchaToken;
    _captchaToken = null;
    try {
      final result = await context.read<DimiApi>().classmates(
            schoolId: school.schoolId,
            enrollYear: year,
            classNorm: _classCtrl.text.trim(),
            name: _nameCtrl.text.trim(),
            page: _page + 1,
            captchaToken: captchaToken,
          );
      if (!mounted) return;
      setState(() {
        _page++;
        final known = _items.map((u) => u.userId).toSet();
        _items = [..._items, ...result.items.where((u) => known.add(u.userId))];
        _hasMore = result.hasMore;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNeedCaptcha) {
        setState(() => _needCaptcha = true);
      } else {
        setState(() => _searchError = e.message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 弹滑块验证，拿到 captcha_token 后重置分页并重试检索
  Future<void> _runCaptcha() async {
    final token = await showSliderCaptcha(context);
    if (token == null || !mounted) return;
    setState(() {
      _needCaptcha = false;
      _captchaToken = token;
    });
    await _loadPage();
  }

  Future<void> _pickSchool() async {
    final picked = await showModalBottomSheet<School>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _SchoolPickerSheet(),
    );
    if (picked != null && mounted) {
      setState(() {
        _school = picked;
        _educationId = null;
        _resetResults();
      });
    }
  }

  void _resetResults() {
    _items = [];
    _searched = false;
    _hasMore = false;
    _page = 0;
    _needCaptcha = false;
    _captchaToken = null;
    _searchError = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('找同学'), actions: [
        TextButton(
            onPressed: () => setState(() => _tab = _tab == 0 ? 1 : 0),
            child: Text(_tab == 0 ? '精确找人' : '找同学')),
      ]),
      body: _tab == 1
          ? const ExactSearchView()
          : RefreshIndicator(
              onRefresh: _doSearch,
              child: ListView(
                padding: const EdgeInsets.all(16),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  DimiFinderPanel(children: [
                    DimiFinderAnchor(
                        icon: Icons.school_outlined,
                        label: '学校',
                        value: _school?.name ?? '选择你的学校',
                        onTap: _loading ? null : _pickSchool),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                        key: ValueKey(_enrollYear),
                        initialValue: _enrollYear,
                        menuMaxHeight: 320,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '入学年份'),
                        items: _yearOptions
                            .map((year) => DropdownMenuItem(
                                value: year, child: Text('$year 年入学')))
                            .toList(),
                        onChanged: _loading
                            ? null
                            : (year) => setState(() {
                                  _enrollYear = year;
                                  _educationId = null;
                                  _resetResults();
                                })),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _moreFilters = !_moreFilters),
                            icon: Icon(
                                _moreFilters ? Icons.expand_less : Icons.tune,
                                size: 18),
                            label: Text(_moreFilters
                                ? '收起筛选'
                                : (_classCtrl.text.isNotEmpty ||
                                        _nameCtrl.text.isNotEmpty
                                    ? '班级、姓名 · 已筛选'
                                    : '班级、姓名（选填）')))),
                    if (_moreFilters) ...[
                      TextField(
                          controller: _classCtrl,
                          enabled: !_loading,
                          decoration: const InputDecoration(
                              labelText: '班级', hintText: '如 六年2班'),
                          onChanged: (_) => setState(_resetResults),
                          onSubmitted: (_) => _doSearch()),
                      const SizedBox(height: 12),
                      TextField(
                          controller: _nameCtrl,
                          enabled: !_loading,
                          decoration: const InputDecoration(labelText: '姓名'),
                          onChanged: (_) => setState(_resetResults),
                          onSubmitted: (_) => _doSearch()),
                      const SizedBox(height: 16),
                    ],
                    DimiButton(
                        label: '找同学',
                        icon: Icons.search,
                        expanded: true,
                        loading: _loading && _items.isEmpty,
                        onPressed: _loading ? null : _doSearch),
                  ]),
                  const SizedBox(height: 24),
                  if (_items.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text('已找到 ${_items.length} 位同学',
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w600))),
                  _buildBody(),
                ],
              ),
            ),
    );
  }

  /// 防爬提示条：kDimiWarningSoft 底 + 警示色图标（替代原 ⚠ 纯文字）
  Widget _privacyHintBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kDimiWarningSoft,
        borderRadius: BorderRadius.circular(kDimiRadiusInput),
      ),
      child: const Row(
        children: [
          Icon(Icons.privacy_tip_outlined, size: 18, color: kDimiWarningDeep),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '为保护同学隐私，继续翻页需要完成一次验证',
              style: TextStyle(fontSize: 14, color: kDimiText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) return const DimiListSkeleton(itemCount: 3);
    if (!_searched) {
      return const DimiEmptyState(
          icon: Icons.school_outlined,
          title: '找回老同学',
          message: '选好学校和入学年份，就可以开始');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_searchError != null)
        DimiErrorView(message: _searchError!, onRetry: _loadPage),
      if (_items.isEmpty && _searchError == null && !_needCaptcha)
        DimiEmptyState(
            icon: Icons.person_search_outlined,
            title: '暂未找到同学',
            message: '试试减少班级或姓名筛选',
            actionLabel: '减少筛选条件',
            onAction: () {
              _nameCtrl.clear();
              _classCtrl.clear();
              _doSearch();
            }),
      if (_items.isNotEmpty)
        DimiPeopleResults(
            items: _items,
            onOpen: (u) => ProfileCardScreen.open(context, u.userId),
            onAdd: (u) => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => FriendApplyScreen(target: u)))),
      if (_needCaptcha)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              _privacyHintBar(),
              const SizedBox(height: 12),
              DimiButton(label: '完成验证，继续查看', onPressed: _runCaptcha),
            ]))
      else if (_hasMore && _searchError == null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: DimiButton(
                label: '加载更多',
                variant: DimiButtonVariant.secondary,
                loading: _loading,
                onPressed: _loadPage)),
      if (_educationId != null && !_loading && _searchError == null)
        Padding(
            padding: const EdgeInsets.only(top: 16), child: _lightUpEntry()),
    ]);
  }
}

/// 学校联想搜索底部弹层（/schools/search，400ms 防抖）
class _SchoolPickerSheet extends StatefulWidget {
  const _SchoolPickerSheet();

  @override
  State<_SchoolPickerSheet> createState() => _SchoolPickerSheetState();
}

class _SchoolPickerSheetState extends State<_SchoolPickerSheet> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<School> _candidates = [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String keyword) {
    _debounce?.cancel();
    if (keyword.trim().length < 2) {
      setState(() => _candidates = []);
      return;
    }
    _debounce =
        Timer(const Duration(milliseconds: 400), () => _search(keyword.trim()));
  }

  Future<void> _search(String keyword) async {
    setState(() => _searching = true);
    try {
      final list = await context.read<DimiApi>().searchSchools(keyword);
      if (!mounted || _ctrl.text.trim() != keyword) return;
      setState(() => _candidates = list);
    } on ApiException {
      // 联想失败静默
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: '输入校名关键词，如「城关二小」',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
              ),
            ),
            Expanded(
              child: _candidates.isEmpty
                  ? const Center(
                      child: Text('输入至少 2 个字开始联想',
                          style: TextStyle(color: kDimiGray99)),
                    )
                  : ListView.separated(
                      itemCount: _candidates.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (_, i) {
                        final s = _candidates[i];
                        return ListTile(
                          title: Text(s.name),
                          subtitle: s.formerNames.isNotEmpty
                              ? Text('曾用名：${s.formerNames.join('、')}',
                                  style: const TextStyle(fontSize: 14))
                              : null,
                          trailing: Text(stageLabel(s.stage),
                              style: const TextStyle(
                                  fontSize: 14, color: kDimiGray99)),
                          onTap: () => Navigator.of(context).pop(s),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
