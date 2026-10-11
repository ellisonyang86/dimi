import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../theme.dart';
import '../person_tile.dart';

/// 找同学、找老乡共用的筛选容器，表单随整页滚动。
class DimiFinderPanel extends StatelessWidget {
  const DimiFinderPanel({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children)),
      );
}

class DimiFinderAnchor extends StatelessWidget {
  const DimiFinderAnchor(
      {super.key,
      required this.icon,
      required this.label,
      required this.value,
      this.onTap});
  final IconData icon;
  final String label, value;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: kDimiPrimarySoft,
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: kDimiPrimary)),
        title: Text(label,
            style: const TextStyle(fontSize: 15, color: kDimiGray99)),
        subtitle: Text(value,
            style: const TextStyle(
                fontSize: 18, color: kDimiText, fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right, size: 20, color: kDimiGray99),
        onTap: onTap,
      );
}

class DimiPeopleResults extends StatelessWidget {
  const DimiPeopleResults(
      {super.key,
      required this.items,
      required this.onOpen,
      required this.onAdd});
  final List<UserBrief> items;
  final ValueChanged<UserBrief> onOpen, onAdd;
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 56),
                PersonTile(
                    user: items[i],
                    onTap: () => onOpen(items[i]),
                    actionLabel: '加好友',
                    onAction: () => onAdd(items[i])),
              ],
            ])),
      );
}
