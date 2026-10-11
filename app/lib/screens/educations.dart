/// 我的教育经历管理：列表（学段/学校/届/班级 + V0-V3 徽标）+ 每条编辑/删除
/// （PUT/DELETE /users/me/educations/{id}）+ 新增（内嵌选校表单）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/common/dimi_section.dart';
import '../widgets/verify_badge.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';

class EducationsScreen extends StatefulWidget {
  const EducationsScreen({super.key});

  @override
  State<EducationsScreen> createState() => _EducationsScreenState();
}

class _EducationsScreenState extends State<EducationsScreen> {
  List<Education> _items = [];
  bool _loading = true;
  String? _error;

  static const _visibilities = {
    'public': '公开',
    'friends': '仅好友',
    'fellows_only': '仅同窗同乡',
    'private': '私密',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<DimiApi>().myEducations();
      if (!mounted) return;
      setState(() => _items = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 编辑：班级 / 院系 / 专业 / 可见性（服务端仅支持这些字段）
  Future<void> _edit(Education e) async {
    final classCtrl = TextEditingController(text: e.classNameRaw ?? '');
    final deptCtrl = TextEditingController(text: e.department ?? '');
    final majorCtrl = TextEditingController(text: e.major ?? '');
    String visibility = e.visibility ?? 'public';
    final ok = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('编辑 · ${e.schoolName ?? ''}',
              style: const TextStyle(fontSize: 18)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: classCtrl,
                  decoration: const InputDecoration(labelText: '班级'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: deptCtrl,
                  decoration: const InputDecoration(labelText: '院系（选填）'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: majorCtrl,
                  decoration: const InputDecoration(labelText: '专业（选填）'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: visibility,
                  decoration: const InputDecoration(labelText: '可见范围'),
                  items: _visibilities.entries
                      .map((en) => DropdownMenuItem(
                          value: en.key, child: Text(en.value)))
                      .toList(),
                  onChanged: (v) => setDlg(() => visibility = v ?? visibility),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final className = classCtrl.text.trim();
    final department = deptCtrl.text.trim();
    final major = majorCtrl.text.trim();
    classCtrl.dispose();
    deptCtrl.dispose();
    majorCtrl.dispose();
    if (ok != true || !mounted || e.id == null) return;
    try {
      await context.read<DimiApi>().updateEducation(
            e.id!,
            className: className,
            department: department,
            major: major,
            visibility: visibility,
          );
      if (!mounted) return;
      _toast('已保存');
      _load();
    } on ApiException catch (err) {
      if (!mounted) return;
      _toast(err.message);
    }
  }

  Future<void> _delete(Education e) async {
    final ok = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这段经历？'),
        content: Text(e.displayLine),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kDimiDangerSoft, foregroundColor: kDimiDanger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted || e.id == null) return;
    try {
      await context.read<DimiApi>().deleteEducation(e.id!);
      if (!mounted) return;
      _toast('已删除');
      _load();
    } on ApiException catch (err) {
      if (!mounted) return;
      _toast(err.message);
    }
  }

  /// 新增经历：内嵌选校表单（联想搜索 → 届 → 班级）
  Future<void> _add() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _AddEducationSheet(),
    );
    if (saved == true && mounted) {
      _toast('经历已保存');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('我的教育经历')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: kDimiPrimaryFill,
        // 浅色底配深色字，与全局主操作一致。
        foregroundColor: kDimiPrimary,
        icon: const Icon(Icons.add),
        label: const Text('新增经历'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kDimiPrimary))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: kDimiGray66)),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Text('还没有教育经历，点右下角新增',
                          style: TextStyle(color: kDimiGray66)),
                    )
                  // 微信式分组排版：整块白底 + 组内发丝分隔线，不再每条一张卡
                  : ListView(
                      padding: const EdgeInsets.only(top: 7, bottom: 80),
                      children: [
                        DimiSection(
                          dividerIndent: kDimiSectionDividerIndentTile,
                          children: [
                            for (final e in _items)
                              ListTile(
                                leading: const Icon(Icons.school_outlined,
                                    color: kDimiPrimary),
                                title: Text(e.displayLine,
                                    style: const TextStyle(fontSize: 16)),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    children: [
                                      Text(stageLabel(e.stage),
                                          style: const TextStyle(fontSize: 14)),
                                      const SizedBox(width: 8),
                                      VerifyBadge(e.verificationLevel),
                                    ],
                                  ),
                                ),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'edit') _edit(e);
                                    if (v == 'delete') _delete(e);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'edit', child: Text('编辑')),
                                    PopupMenuItem(
                                        value: 'delete', child: Text('删除')),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
    );
  }
}

/// 新增经历底部弹层：学校联想（400ms 防抖）→ 届 → 班级
class _AddEducationSheet extends StatefulWidget {
  const _AddEducationSheet();

  @override
  State<_AddEducationSheet> createState() => _AddEducationSheetState();
}

class _AddEducationSheetState extends State<_AddEducationSheet> {
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
      if (!mounted || _schoolCtrl.text.trim() != keyword) return;
      setState(() => _candidates = list);
    } on ApiException {
      // 联想失败静默
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
      await context.read<DimiApi>().addEducation(
            stage: school.stage ?? 'PRIMARY',
            schoolId: school.schoolId,
            enrollYear: _enrollYear!,
            className: _classCtrl.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('新增教育经历',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          TextField(
            controller: _schoolCtrl,
            onChanged: _onKeywordChanged,
            decoration: InputDecoration(
              labelText: '学校',
              hintText: '输入校名关键词联想',
              isDense: true,
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
          if (selected != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kDimiPrimarySoft,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${selected.name}（${stageLabel(selected.stage)}）',
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _selected = null),
                    child:
                        const Icon(Icons.close, size: 18, color: kDimiGray99),
                  ),
                ],
              ),
            )
          else if (_candidates.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                border: Border.all(color: kDimiHairline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _candidates.length,
                itemBuilder: (_, i) {
                  final s = _candidates[i];
                  return ListTile(
                    dense: true,
                    title: Text(s.name, style: const TextStyle(fontSize: 16)),
                    trailing: Text(stageLabel(s.stage),
                        style:
                            const TextStyle(fontSize: 14, color: kDimiGray99)),
                    onTap: () => setState(() {
                      _selected = s;
                      _candidates = [];
                      _schoolCtrl.text = s.name;
                    }),
                  );
                },
              ),
            ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            initialValue: _enrollYear,
            decoration:
                const InputDecoration(labelText: '入学年份（届）', isDense: true),
            items: _yearOptions
                .map((y) => DropdownMenuItem(value: y, child: Text('$y 级')))
                .toList(),
            onChanged: (v) => setState(() => _enrollYear = v),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _classCtrl,
            decoration: const InputDecoration(
              labelText: '班级（选填）',
              hintText: '如：六年2班',
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: kDimiPrimaryFill),
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    );
  }
}
