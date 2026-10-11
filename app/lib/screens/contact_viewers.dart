/// 谁看过我的联系方式（§20.7 双向透明）：GET /users/me/contact-viewers，
/// 近 30 天访问者列表（UserBrief + 访问时间）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../widgets/moment_card.dart' show formatMomentTime;
import '../widgets/person_tile.dart';
import 'profile_card.dart';
import '../theme.dart';

class ContactViewersScreen extends StatefulWidget {
  const ContactViewersScreen({super.key});

  @override
  State<ContactViewersScreen> createState() => _ContactViewersScreenState();
}

class _ContactViewersScreenState extends State<ContactViewersScreen> {
  List<ContactViewer> _items = [];
  bool _loading = true;
  String? _error;

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
    try {
      final list = await context.read<DimiApi>().contactViewers();
      if (!mounted) return;
      setState(() => _items = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('谁看过我')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kDimiPrimary))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: kDimiGray99)),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Text('近 30 天还没有人查看过你的联系方式',
                          style: TextStyle(color: kDimiGray99)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final v = _items[i];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: PersonTile(
                              user: v.user,
                              subtitle: '查看时间：${formatMomentTime(v.viewedAt)}',
                              onTap: () => ProfileCardScreen.open(
                                  context, v.user.userId),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
