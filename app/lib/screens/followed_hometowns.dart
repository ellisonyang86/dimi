/// 我关注的家乡页列表：发现页入口 → 本页 → 各家乡页。
/// 数据源为服务端 GET /v1/hometown-pages/followed/mine（跨设备同步）；
/// 接口失败时回落本机 SharedPreferences 暂存集合（关注/取关时双向同步写入）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../theme.dart';
import '../widgets/common/dimi_empty_state.dart';
import 'hometown_page.dart';

/// SharedPreferences 键：JSON map，{region_code: {"name": 全路径, "at": epoch毫秒}}
const kFollowedHometownsKey = 'followed_hometown_pages_v1';

/// 已关注家乡条目（本机暂存）
class FollowedHometown {
  FollowedHometown({required this.regionCode, required this.name});

  final String regionCode;

  /// 镇名全路径（关注时快照，仅作列表展示，进页后以服务端数据为准）
  final String name;
}

/// 关注集合的本机读写（服务端关注列表端点待补，见文件头注释）
class FollowedHometownsStore {
  static Future<Map<String, dynamic>> _readMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kFollowedHometownsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }

  static Future<void> _writeMap(Map<String, dynamic> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kFollowedHometownsKey, jsonEncode(map));
  }

  /// 关注成功后写入/更新（name 为当时的全路径快照）
  static Future<void> follow(String regionCode, String name) async {
    final map = await _readMap();
    map[regionCode] = {
      'name': name,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    await _writeMap(map);
  }

  /// 取消关注成功后移除
  static Future<void> unfollow(String regionCode) async {
    final map = await _readMap();
    if (map.remove(regionCode) != null) await _writeMap(map);
  }

  /// 全量列表（按关注时间倒序）
  static Future<List<FollowedHometown>> load() async {
    final map = await _readMap();
    final entries = map.entries.toList()
      ..sort((a, b) => ((b.value['at'] as num?) ?? 0)
          .compareTo((a.value['at'] as num?) ?? 0));
    return entries
        .map((e) => FollowedHometown(
              regionCode: e.key,
              name: (e.value['name'] as String?) ?? '家乡页',
            ))
        .toList();
  }
}

/// 「我关注的家乡」列表页
class FollowedHometownsScreen extends StatefulWidget {
  const FollowedHometownsScreen({super.key});

  @override
  State<FollowedHometownsScreen> createState() =>
      _FollowedHometownsScreenState();
}

class _FollowedHometownsScreenState extends State<FollowedHometownsScreen> {
  List<FollowedHometown>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 优先走服务端关注列表（跨设备同步）；失败回落本机暂存集合
    try {
      final rows = await context.read<DimiApi>().followedHometownPages();
      if (!mounted) return;
      setState(() => _items = rows
          .map((r) => FollowedHometown(
                regionCode: r['region_code']?.toString() ?? '',
                name: r['region_path'] is List
                    ? (r['region_path'] as List).join('')
                    : '家乡页',
              ))
          .toList());
      return;
    } on ApiException {
      // 网络或服务端异常：回落本机暂存
    }
    final items = await FollowedHometownsStore.load();
    if (!mounted) return;
    setState(() => _items = items);
  }

  /// 进家乡页；返回后重载列表（可能在页内取消了关注）
  Future<void> _open(FollowedHometown item) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HometownPageScreen(regionCode: item.regionCode),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('我关注的家乡')),
      body: items == null
          ? const Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: kDimiPrimary),
            )
          : items.isEmpty
              ? const DimiEmptyState(
                  icon: Icons.home_work_outlined,
                  title: '还没有关注的家乡',
                  message: '在家乡页点「+ 关注」，这里就能看到',
                )
              : ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _followedCard(items[i]),
                    ],
                    // 数据来源说明（服务端同步，本机暂存为离线兜底）
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
                      child: Text(
                        '关注列表随账号同步，离线时显示本机缓存',
                        style: TextStyle(fontSize: 14, color: kDimiGray66),
                      ),
                    ),
                  ],
                ),
    );
  }

  /// 关注条目卡：雾杏图标徽标 + 镇名全路径 + 箭头，整卡可点进家乡页
  Widget _followedCard(FollowedHometown item) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: kDimiApricotSoft,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.cottage_outlined,
                    color: kDimiApricotDeep, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.chevron_right, color: kDimiGrayCC),
            ],
          ),
        ),
      ),
    );
  }
}
