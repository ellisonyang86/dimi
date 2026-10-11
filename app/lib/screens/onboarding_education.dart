/// 经历填写引导（注册后第一屏）：
/// 学校联想搜索（/schools/search，400ms 防抖）→ 届 → 班级 →
/// 保存 /users/me/educations；找不到学校走 /schools/apply 共建申请。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import 'home.dart';

class OnboardingEducationScreen extends StatefulWidget {
  const OnboardingEducationScreen({super.key});

  static const routeName = '/onboarding';

  @override
  State<OnboardingEducationScreen> createState() =>
      _OnboardingEducationScreenState();
}

class _OnboardingEducationScreenState extends State<OnboardingEducationScreen> {
  final _schoolCtrl = TextEditingController();
  final _classCtrl = TextEditingController();
  Timer? _debounce;
  List<School> _candidates = [];
  School? _selected;
  int? _enrollYear;
  bool _searching = false;
  bool _saving = false;

  List<int> get _yearOptions {
    final now = DateTime.now().year;
    return List<int>.generate(now - 1949, (i) => now - i);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _schoolCtrl.dispose();
    _classCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _onKeywordChanged(String keyword) {
    _debounce?.cancel();
    if (keyword.trim().length < 2) {
      setState(() {
        _candidates = [];
        _selected = null;
      });
      return;
    }
    _debounce =
        Timer(const Duration(milliseconds: 400), () => _search(keyword.trim()));
  }

  Future<void> _search(String keyword) async {
    setState(() => _searching = true);
    try {
      final list = await context.read<DimiApi>().searchSchools(keyword);
      if (!mounted) return;
      // 防抖期间输入可能已变化，若当前输入与本次请求关键词不一致则丢弃
      if (_schoolCtrl.text.trim() != keyword) return;
      setState(() => _candidates = list);
    } on ApiException {
      // 联想失败静默处理，不阻塞手动输入
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _save() async {
    final school = _selected;
    if (school == null) {
      _toast('请先搜索并选择学校');
      return;
    }
    if (_enrollYear == null) {
      _toast('请选择入学年份（届）');
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await context.read<DimiApi>().addEducation(
            stage: school.stage ?? 'PRIMARY',
            schoolId: school.schoolId,
            enrollYear: _enrollYear!,
            className: _classCtrl.text.trim(),
          );
      if (!mounted) return;
      await context.read<Session>().markOnboarded();
      if (!mounted) return;
      if (result.registeredCount > 0) {
        _toast('已保存，该班已有 ${result.registeredCount} 位同学注册');
      } else {
        _toast('经历已保存');
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const MainShell()),
        (route) => false,
      );
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 地区三级联动选择：省 → 市 → 区县（/regions 逐级拉取），返回选中的 Region
  Future<Region?> _pickRegion() {
    return showModalBottomSheet<Region>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(kDimiRadiusSheet)),
      ),
      builder: (_) => const _RegionPickerSheet(),
    );
  }

  Future<void> _applySchool() async {
    final nameCtrl = TextEditingController(text: _schoolCtrl.text.trim());
    Region? region; // 所选区县；留空则由运营补全
    final ok = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('申请共建新学校'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '学校全称'),
              ),
              const SizedBox(height: 8),
              // 所在地区：点击弹出省市区三级联动选择（不知道可跳过，由运营补全）
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final r = await _pickRegion();
                  if (r != null) setSheet(() => region = r);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '所在地区'),
                  child: Text(
                    region?.name ?? '请选择省 / 市 / 区县（不知道可跳过）',
                    style: TextStyle(
                      fontSize: 17,
                      color: region == null ? kDimiGray99 : kDimiText,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '提交后我们会尽快审核，通过后即可选择该学校。',
                style: TextStyle(fontSize: 14, color: kDimiGray99),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('提交申请'),
            ),
          ],
        ),
      ),
    );
    final name = nameCtrl.text.trim();
    final regionCode = region?.code ?? '000000';
    nameCtrl.dispose();
    if (ok != true || !mounted) return;
    if (name.isEmpty) {
      _toast('请填写学校全称');
      return;
    }
    try {
      await context.read<DimiApi>().applySchool(
            name: name,
            regionCode: regionCode,
          );
      if (!mounted) return;
      _toast('申请已提交，审核通过后会通知你');
    } on ApiException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<void> _skip() async {
    try {
      await context.read<Session>().markOnboarded();
    } on Exception {
      // 标记失败不阻断进入主页
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const MainShell()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(
        title: const Text('填写你的第一段经历'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _skip,
            child: const Text('先逛逛'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '从印象最深的那所学校开始——填了学校，才能帮你找到老同学。',
              style: TextStyle(fontSize: 15, color: kDimiGray66, height: 1.6),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _schoolCtrl,
                    onChanged: _onKeywordChanged,
                    decoration: InputDecoration(
                      labelText: '学校',
                      hintText: '输入校名关键词，如「城关二小」',
                      prefixIcon: const Icon(Icons.school_outlined),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                    ),
                  ),
                  if (selected != null)
                    Container(
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: kDimiPrimarySoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle,
                              color: kDimiPrimary, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${selected.name}（${stageLabel(selected.stage)}）',
                              style: const TextStyle(fontSize: 17),
                            ),
                          ),
                          // IconButton 自带 48dp 触达区，替代小热区 GestureDetector
                          IconButton(
                            onPressed: () => setState(() => _selected = null),
                            icon: const Icon(Icons.close,
                                size: 18, color: kDimiGray99),
                          ),
                        ],
                      ),
                    )
                  else if (_candidates.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      constraints: const BoxConstraints(maxHeight: 220),
                      decoration: BoxDecoration(
                        border: Border.all(color: kDimiGrayCC),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _candidates.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 12, endIndent: 12),
                        itemBuilder: (_, i) {
                          final s = _candidates[i];
                          return ListTile(
                            dense: true,
                            title: Text(s.name,
                                style: const TextStyle(fontSize: 17)),
                            subtitle: s.formerNames.isNotEmpty
                                ? Text('曾用名：${s.formerNames.join('、')}',
                                    style: const TextStyle(fontSize: 14))
                                : null,
                            trailing: Text(stageLabel(s.stage),
                                style: const TextStyle(
                                    fontSize: 14, color: kDimiGray99)),
                            onTap: () {
                              setState(() {
                                _selected = s;
                                _candidates = [];
                                _schoolCtrl.text = s.name;
                              });
                            },
                          );
                        },
                      ),
                    )
                  else if (_schoolCtrl.text.trim().length >= 2 && !_searching)
                    // TextButton 自带 48dp 触达区，替代小热区 GestureDetector
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _applySchool,
                        child: const Text('找不到学校？申请共建新学校 →'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _enrollYear,
                    decoration: const InputDecoration(
                      labelText: '入学年份（届）',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                    items: _yearOptions
                        .map((y) =>
                            DropdownMenuItem(value: y, child: Text('$y 级')))
                        .toList(),
                    onChanged: (v) => setState(() => _enrollYear = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _classCtrl,
                    decoration: const InputDecoration(
                      labelText: '班级（选填，但强烈建议）',
                      hintText: '如：六年2班',
                      prefixIcon: Icon(Icons.groups_outlined),
                    ),
                  ),
                  const SizedBox(height: 20),
                  DimiButton(
                    label: '保存并进入围城',
                    onPressed: (_selected != null && _enrollYear != null)
                        ? _save
                        : null,
                    loading: _saving,
                    expanded: true,
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              '你填写的经历默认「仅同窗同乡可见」，可在「我 → 隐私」随时调整。',
              style: TextStyle(fontSize: 14, color: kDimiGray99, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 地区三级联动选择弹层：省 → 市 → 区县（/regions 逐级拉取，参考 fellow.dart 的级联逻辑）。
/// 选中区县（level 3）即返回；加载用骨架屏、失败可重试。
class _RegionPickerSheet extends StatefulWidget {
  const _RegionPickerSheet();

  @override
  State<_RegionPickerSheet> createState() => _RegionPickerSheetState();
}

class _RegionPickerSheetState extends State<_RegionPickerSheet> {
  /// 已选路径（省 / 市）
  final _path = <Region>[];
  List<Region> _options = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取当前层级候选：路径为空取省级，否则取末级的下一级
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context
          .read<DimiApi>()
          .regions(parentCode: _path.isEmpty ? null : _path.last.code);
      if (!mounted) return;
      setState(() => _options = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onTap(Region r) async {
    // 区县级（level 3）为最终可选粒度，直接返回
    if (r.level >= 3) {
      Navigator.of(context).pop(r);
      return;
    }
    _path.add(r);
    await _load();
    // 下一级为空（如无区县的直筒子市）：直接选定当前级返回
    if (mounted && _error == null && _options.isEmpty) {
      Navigator.of(context).pop(r);
    }
  }

  void _onBack() {
    if (_path.isEmpty) return;
    setState(() => _path.removeLast());
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 420,
      child: Column(
        children: [
          // 标题栏：非顶层时可返回上一级，标题展示已选路径
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                if (_path.isNotEmpty)
                  IconButton(
                    onPressed: _onBack,
                    icon: const Icon(Icons.arrow_back),
                  )
                else
                  const SizedBox(width: 48),
                Expanded(
                  child: Text(
                    _path.isEmpty
                        ? '选择所在地区'
                        : _path.map((r) => r.name).join(' / '),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: DimiListSkeleton(itemCount: 6),
                  )
                : _error != null
                    ? DimiErrorView(message: _error!, onRetry: _load)
                    : ListView.separated(
                        itemCount: _options.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 16, endIndent: 16),
                        itemBuilder: (_, i) {
                          final r = _options[i];
                          return ListTile(
                            title: Text(r.name),
                            trailing: r.level < 3
                                ? const Icon(Icons.chevron_right,
                                    color: kDimiGrayBB)
                                : null,
                            onTap: () => _onTap(r),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
