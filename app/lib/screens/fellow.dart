/// 找老乡：家乡锚点（精确到镇）+ 粒度可调的同乡检索（契约 /discover/fellows）。
/// 未设置家乡时先走四级联动选择（省→市→区县→镇），保存后进入检索。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/common/dimi_empty_state.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/common/dimi_skeleton.dart';
import '../widgets/common/dimi_finder.dart';
import '../widgets/common/dimi_button.dart';
import '../widgets/slider_captcha.dart';
import '../theme.dart';
import 'friend_apply.dart';
import 'profile_card.dart';

class FellowScreen extends StatefulWidget {
  const FellowScreen({super.key});

  static const routeName = '/fellow';

  @override
  State<FellowScreen> createState() => _FellowScreenState();
}

class _FellowScreenState extends State<FellowScreen> {
  bool _loading = true;
  String? _error;
  HometownEntry? _hometown;

  // 级联选择状态
  List<Region> _provinces = [];
  List<Region> _cities = [];
  List<Region> _districts = [];
  List<Region> _towns = [];
  Region? _province, _city, _district, _town;
  bool _picking = false;
  bool _saving = false;

  // 检索状态
  int _level = 4; // 2 市 / 3 区县 / 4 镇
  final _nameCtrl = TextEditingController();
  bool _searching = false;
  bool _searched = false;
  List<UserBrief> _items = [];
  String? _searchError;
  bool _hasMore = false, _needCaptcha = false;
  int _page = 0, _regionRequest = 0;
  String? _captchaToken;

  DimiApi get _api => context.read<DimiApi>();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _api.myHometowns();
      if (!mounted) return;
      _hometown = list.where((e) => e.type == 1).firstOrNull;
      if (_hometown == null) await _startPicking();
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startPicking() async {
    if (!mounted) return;
    setState(() => _picking = true);
    if (_provinces.isEmpty) {
      try {
        _provinces = await _api.regions();
        if (mounted) setState(() {});
      } on ApiException catch (e) {
        if (!mounted) return;
        if (_hometown != null) {
          // 「更换」入口：回退到检索页，可再次点击重试
          setState(() => _picking = false);
        } else {
          // 首次设置入口：落到错误页，避免 _buildSearch 空指针
          setState(() => _error = e.message);
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _selectRegion(int level, Region? r) async {
    final request = ++_regionRequest;
    setState(() {
      switch (level) {
        case 1:
          _province = r;
          _city = _district = _town = null;
          _cities = _districts = _towns = [];
        case 2:
          _city = r;
          _district = _town = null;
          _districts = _towns = [];
        case 3:
          _district = r;
          _town = null;
          _towns = [];
        case 4:
          _town = r;
      }
    });
    if (r == null || r.level >= 4) return;
    try {
      final children = await _api.regions(parentCode: r.code);
      if (!mounted || request != _regionRequest) return;
      setState(() {
        switch (r.level) {
          case 1:
            _cities = children;
          case 2:
            _districts = children;
          case 3:
            _towns = children;
        }
      });
    } on ApiException catch (e) {
      // 加载下一级失败：保留下级旧数据（为空），仅提示可重新选择重试
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _saveHometown() async {
    if (_town == null || _saving) return;
    setState(() => _saving = true);
    try {
      await _api.setMyHometown(type: 1, regionCode: _town!.code);
      if (!mounted) return;
      _picking = false;
      _resetResults();
      await _bootstrap();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('家乡已设置')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _resetResults() {
    _items = [];
    _searched = false;
    _hasMore = false;
    _needCaptcha = false;
    _page = 0;
    _searchError = null;
    _captchaToken = null;
  }

  Future<void> _search({bool more = false}) async {
    final anchor = _hometown;
    if (anchor == null || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      if (!more) _resetResults();
      _searching = true;
      _searched = true;
      _searchError = null;
    });
    final token = _captchaToken;
    _captchaToken = null;
    try {
      final res = await _api.fellows(
          regionCode: anchor.regionCode,
          level: _level,
          name: _nameCtrl.text.trim(),
          page: _page + 1,
          captchaToken: token);
      if (!mounted) return;
      setState(() {
        final known = _items.map((u) => u.userId).toSet();
        _items = [..._items, ...res.items.where((u) => known.add(u.userId))];
        _hasMore = res.hasMore;
        _page++;
        _needCaptcha = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          if (e.isNeedCaptcha) {
            _needCaptcha = true;
          } else {
            _searchError = e.message;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _verify() async {
    final token = await showSliderCaptcha(context);
    if (token == null || !mounted) return;
    _captchaToken = token;
    await _search(more: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('找老乡'), actions: [
        if (_picking && _hometown != null)
          TextButton(
              onPressed:
                  _saving ? null : () => setState(() => _picking = false),
              child: const Text('取消')),
      ]),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: DimiListSkeleton(itemCount: 5),
            )
          : _error != null
              ? DimiErrorView(message: _error!, onRetry: _bootstrap)
              : _picking
                  ? _buildPicker()
                  : _buildSearch(),
    );
  }

  /// 四级联动当前进度：1 省 / 2 市 / 3 区县 / 4 乡镇
  int get _pickStep {
    var step = 1;
    if (_province != null) step = 2;
    if (_city != null) step = 3;
    if (_district != null) step = 4;
    return step;
  }

  /// 步骤指示 chip：已完成（主色浅底+对勾）/ 当前步（主色描边）/ 未到（灰）
  Widget _stepChip(int step, String label) {
    final done = step < _pickStep || (step == 4 && _town != null);
    final current = step == _pickStep && !done;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: done || current ? kDimiPrimaryFill : kDimiNeutralSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (done) ...[
            const Icon(Icons.check, size: 14, color: kDimiPrimary),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: done || current ? kDimiPrimary : kDimiGray99,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdown(String label, List<Region> items, Region? value,
      void Function(Region?) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<Region>(
        key: ValueKey('$label-${value?.code}-${items.length}'),
        isExpanded: true,
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: items
            .map((r) => DropdownMenuItem(value: r, child: Text(r.name)))
            .toList(),
        onChanged: _saving ? null : onChanged,
      ),
    );
  }

  Widget _buildPicker() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('先设置你的家乡',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('家乡需精确到乡镇/街道，仅用于帮你找到同乡',
                    style: TextStyle(fontSize: 14, color: kDimiGray99)),
                const SizedBox(height: 12),
                // 四级联动步骤指示：①省 ②市 ③区县 ④乡镇
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _stepChip(1, '① 省'),
                    _stepChip(2, '② 市'),
                    _stepChip(3, '③ 区县'),
                    _stepChip(4, '④ 乡镇'),
                  ],
                ),
                const SizedBox(height: 14),
                _dropdown(
                    '省份', _provinces, _province, (r) => _selectRegion(1, r)),
                if (_cities.isNotEmpty)
                  _dropdown('城市', _cities, _city, (r) => _selectRegion(2, r)),
                if (_districts.isNotEmpty)
                  _dropdown(
                      '区县', _districts, _district, (r) => _selectRegion(3, r)),
                if (_towns.isNotEmpty)
                  _dropdown('乡镇/街道', _towns, _town, (r) => _selectRegion(4, r)),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _town == null || _saving ? null : _saveHometown,
                    child: Text(_saving ? '保存中…' : '保存家乡'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearch() {
    final anchor = _hometown!;
    return RefreshIndicator(
        onRefresh: _search,
        child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            DimiFinderPanel(children: [
              DimiFinderAnchor(
                  icon: Icons.cottage_outlined,
                  label: '我的家乡',
                  value: anchor.displayPath,
                  onTap: _searching ? null : _startPicking),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 4, label: Text('同镇')),
                    ButtonSegment(value: 3, label: Text('同区县')),
                    ButtonSegment(value: 2, label: Text('同市'))
                  ],
                  selected: {_level},
                  onSelectionChanged: _searching
                      ? null
                      : (s) => setState(() {
                            _level = s.first;
                            _resetResults();
                          })),
              const SizedBox(height: 16),
              TextField(
                  controller: _nameCtrl,
                  enabled: !_searching,
                  decoration:
                      const InputDecoration(labelText: '姓名', hintText: '选填'),
                  onChanged: (_) => setState(_resetResults),
                  onSubmitted: (_) => _search()),
              const SizedBox(height: 16),
              DimiButton(
                  label: '找老乡',
                  icon: Icons.search,
                  expanded: true,
                  loading: _searching && _items.isEmpty,
                  onPressed: _searching ? null : _search),
            ]),
            const SizedBox(height: 24),
            if (_searching && _items.isEmpty)
              const DimiListSkeleton(itemCount: 3)
            else if (!_searched)
              const DimiEmptyState(
                  icon: Icons.cottage_outlined,
                  title: '遇见家乡人',
                  message: '选择同镇、同区县或同市，找找身边的老乡'),
            if (_searchError != null)
              DimiErrorView(
                  message: _searchError!, onRetry: () => _search(more: true)),
            if (_searched &&
                !_searching &&
                _items.isEmpty &&
                _searchError == null &&
                !_needCaptcha)
              DimiEmptyState(
                  icon: Icons.cottage_outlined,
                  title: '暂未找到老乡',
                  message: '试试扩大范围，或减少姓名筛选',
                  actionLabel: '扩大范围',
                  onAction: () {
                    setState(() {
                      _level = _level > 2 ? _level - 1 : 2;
                      _nameCtrl.clear();
                    });
                    _search();
                  }),
            if (_items.isNotEmpty) ...[
              Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('已找到 ${_items.length} 位老乡',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600))),
              DimiPeopleResults(
                  items: _items,
                  onOpen: (u) => ProfileCardScreen.open(context, u.userId),
                  onAdd: (u) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => FriendApplyScreen(target: u)))),
            ],
            if (_needCaptcha)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: DimiButton(label: '完成验证，继续查看', onPressed: _verify))
            else if (_hasMore && _searchError == null)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: DimiButton(
                      label: '加载更多',
                      variant: DimiButtonVariant.secondary,
                      loading: _searching,
                      onPressed: () => _search(more: true))),
          ],
        ));
  }
}
