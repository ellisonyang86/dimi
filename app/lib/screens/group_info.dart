/// 通用群资料页（从聊天页顶栏进入），班级群/老乡群共用：
/// 群名 / 群公告（群主可编辑，≤200 字）/ 成员网格（群主标记）/ 退出群。
/// groupKind=='hometown' 走 hometown-group* API（雾杏色系 + cottage 图标），
/// 否则走 class-group* API（黛绿 + school 图标）。
/// 公告与最新成员数取自 /class-groups/mine 或 /hometown-groups/mine（成员视角必含该单元），
/// 成员列表取 /{class,hometown}-groups/{conv_id}/members（含 masked_name 渐显，透传不加工）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common/dimi_dialog.dart';
import '../widgets/common/dimi_error_view.dart';
import '../widgets/dimi_avatar.dart';

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({
    super.key,
    required this.convId,
    required this.title,
    this.memberCount,
    this.groupKind = 'class',
  });

  final int convId;
  final String title;
  final int? memberCount;

  /// 'class'=班级群 / 'hometown'=老乡群；null 或未知值按班级群兜底
  final String? groupKind;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _loading = true;
  String? _error;
  List<ClassGroupMember> _members = [];
  int? _ownerId;
  String _announcement = '';
  String? _title;
  int? _memberCount;
  bool _leaving = false;

  bool get _isHometown => widget.groupKind == 'hometown';

  /// 群类型名（「班级群」/「老乡群」），文案与兜底标题共用
  String get _kindName => _isHometown ? '老乡群' : '班级群';

  /// 类型点缀色：老乡群雾杏，班级群黛绿
  Color get _accent => _isHometown ? kDimiApricotDeep : kDimiPrimary;

  IconData get _kindIcon =>
      _isHometown ? Icons.cottage_outlined : Icons.school_outlined;

  bool get _isOwner {
    final me = context.read<Session>().currentUser;
    return me != null && _ownerId != null && _ownerId == me.userId;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<DimiApi>();
    try {
      final res = _isHometown
          ? await api.hometownGroupMembers(widget.convId)
          : await api.classGroupMembers(widget.convId);
      // 公告/最新成员数：members 接口不含，从 /{class,hometown}-groups/mine 按 convId 找回（失败静默）
      var announcement = '';
      String? title;
      int? memberCount;
      try {
        if (_isHometown) {
          final units = await api.myHometownGroups();
          for (final u in units) {
            final g = u.group;
            if (g != null && g.convId == widget.convId) {
              announcement = g.announcement;
              title = g.title;
              memberCount = g.memberCount;
              break;
            }
          }
        } else {
          final units = await api.myClassGroups();
          for (final u in units) {
            final g = u.group;
            if (g != null && g.convId == widget.convId) {
              announcement = g.announcement;
              title = g.title;
              memberCount = g.memberCount;
              break;
            }
          }
        }
      } on ApiException {
        // 公告加载失败不阻塞成员列表
      }
      if (!mounted) return;
      setState(() {
        _members = res.items;
        _ownerId = res.ownerId;
        _announcement = announcement;
        _title = title;
        _memberCount = memberCount;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editAnnouncement() async {
    final ctrl = TextEditingController(text: _announcement);
    final text = await showDimiDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('群公告'),
        content: TextField(
          controller: ctrl,
          maxLength: 200,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(hintText: '填写群公告，不超过 200 字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null || !mounted) return;
    try {
      final api = context.read<DimiApi>();
      if (_isHometown) {
        await api.updateHometownGroupAnnouncement(widget.convId, text);
      } else {
        await api.updateClassGroupAnnouncement(widget.convId, text);
      }
      if (!mounted) return;
      setState(() => _announcement = text);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _leave() async {
    final yes = await showDimiDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出$_kindName？'),
        content: Text(_isHometown
            ? '退出后不再接收该群消息，之后可从老乡单元重新加入。'
            : '退出后不再接收该群消息，之后可从班级单元重新加入。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kDimiDangerSoft,
                  foregroundColor: kDimiDanger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _leaving = true);
    try {
      final api = context.read<DimiApi>();
      if (_isHometown) {
        await api.leaveHometownGroup(widget.convId);
      } else {
        await api.leaveClassGroup(widget.convId);
      }
      if (!mounted) return;
      // 退出后回到首页（群资料页与聊天页一并出栈）
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _leaving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('群资料')),
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
      return DimiErrorView(message: _error!, onRetry: _load);
    }
    final title = (_title != null && _title!.isNotEmpty)
        ? _title!
        : (widget.title.isEmpty ? _kindName : widget.title);
    final count = _memberCount ?? widget.memberCount ?? _members.length;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      children: [
        // 群名卡
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: DimiAvatar(name: title, seed: widget.convId),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('共 $count 人',
                style: const TextStyle(fontSize: 14, color: kDimiGray99)),
            trailing: Icon(_kindIcon, size: 20, color: _accent),
          ),
        ),
        const SizedBox(height: 10),
        // 群公告卡（群主可编辑）
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            title: const Text('群公告',
                style: TextStyle(fontSize: 15, color: kDimiGray99)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _announcement.isEmpty ? '暂无公告' : _announcement,
                style: const TextStyle(fontSize: 16, color: kDimiText),
              ),
            ),
            trailing: _isOwner
                ? Icon(Icons.edit_outlined, size: 18, color: _accent)
                : null,
            onTap: _isOwner ? _editAnnouncement : null,
          ),
        ),
        const SizedBox(height: 10),
        // 成员网格卡
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('群成员 ${_members.length}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 5,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.62,
                  // 大群一次性全量构建开销大：仅渲染前 50 位并提示总数
                  children: _members.take(50).map(_memberCell).toList(),
                ),
                if (_members.length > 50)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('仅展示前 50 位，共 ${_members.length} 人',
                        style:
                            const TextStyle(fontSize: 14, color: kDimiGray99)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        // 退出群
        Center(
          child: OutlinedButton(
            onPressed: _leaving ? null : _leave,
            style: OutlinedButton.styleFrom(
              backgroundColor: kDimiDangerSoft,
              foregroundColor: kDimiDanger,
              side: BorderSide.none,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
            ),
            child: Text(_leaving ? '正在退出…' : '退出$_kindName'),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _memberCell(ClassGroupMember m) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DimiAvatar(
          name: m.displayName,
          avatarUrl: m.brief.avatarUrl,
          seed: m.brief.userId,
          size: 48,
        ),
        const SizedBox(height: 4),
        Text(
          m.displayName,
          style: const TextStyle(fontSize: 14, color: kDimiText),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          m.isOwner ? '群主' : '',
          style: TextStyle(fontSize: 14, color: _accent),
        ),
      ],
    );
  }
}
