/// 人物条目：头像 + 昵称/真名/交集标签 + 推荐理由 + 右侧操作按钮。
/// 检索结果、推荐好友、申请列表共用（对齐原型 .person 样式）。
/// matchTags 与 reason 语义去重：reason 文本已包含某 tag 时该 tag 不再渲染为 chip
///（如 reason「同班同学」已含 tag「同班」，避免同一信息两处显示）。
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'dimi_avatar.dart';
import 'masked_name.dart';
import '../theme.dart';

class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.user,
    this.onTap,
    this.onLongPress,
    this.actionLabel,
    this.onAction,
    this.subtitle,
    this.trailing,
  });

  final UserBrief user;
  final VoidCallback? onTap;

  /// 长按（如推荐卡片「不感兴趣」）
  final VoidCallback? onLongPress;

  /// 右侧按钮文案（如「加好友」）；null 则不展示按钮
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 副标题覆盖；缺省展示 user.reason（推荐理由，契约约定必显）
  final String? subtitle;

  /// 最右侧挂件（如 ⋯ 菜单按钮）；与 actionLabel 可并存，位于其右
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle ?? user.reason ?? '';
    var label = actionLabel;
    var action = onAction;
    if (label == '加好友') {
      if (user.relation == 'friend' || user.relation == 'pending_in') {
        label = user.relation == 'friend' ? '查看' : '查看申请';
        action = onTap;
      } else if (user.relation == 'pending_out') {
        label = '申请中';
        action = null;
      }
    }
    // matchTags 与 reason 去重：副标题文本已包含某 tag 时该 tag 不渲染为 chip
    //（reason 为服务端下发的完整表述，chip 是其浓缩标签，两者同现即冗余）；
    // 无副标题时保留全部 tag
    final tags = sub.isEmpty
        ? user.matchTags
        : user.matchTags
            .where((t) => t.isNotEmpty && !sub.contains(t))
            .toList();
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            DimiAvatar(
              name: user.nickname,
              avatarUrl: user.avatarUrl,
              seed: user.userId,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.nickname ?? '未命名',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: kDimiText,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (user.realName != null &&
                          user.realName!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(child: MaskedName(user.realName)),
                      ],
                    ],
                  ),
                  if (tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: tags.map(_matchTag).toList(),
                      ),
                    ),
                  if (sub.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        sub,
                        style: const TextStyle(
                          fontSize: 14,
                          color: kDimiGray99,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (label != null) ...[
              const SizedBox(width: 8),
              // 扁平 tonal：列表行级按钮不用实心重色块
              FilledButton(
                onPressed: action,
                style: FilledButton.styleFrom(
                  backgroundColor: kDimiPrimarySoft,
                  foregroundColor: kDimiPrimary,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  // 触控目标不小于 48dp（适老化规范），去掉 shrinkWrap
                  minimumSize: const Size(0, 48),
                ),
                child: Text(label, style: const TextStyle(fontSize: 15)),
              ),
            ],
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }

  Widget _matchTag(String tag) {
    final isFellow =
        tag.contains('老乡') || tag.contains('同镇') || tag.contains('同乡');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isFellow ? kDimiApricotSoft : kDimiPrimarySoft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 14,
          color: isFellow ? kDimiApricotDeep : kDimiPrimary,
        ),
      ),
    );
  }
}
