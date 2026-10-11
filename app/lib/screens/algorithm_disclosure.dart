/// 推荐算法基本原理公示（《互联网信息服务算法推荐管理规定》合规要求，
/// 对齐 V3.1 A4）：静态说明页，从「关于 DIMI」与隐私设置两处进入。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class AlgorithmDisclosureScreen extends StatelessWidget {
  const AlgorithmDisclosureScreen({super.key});

  static const _sections = [
    (
      '推荐的基本原理',
      'DIMI·围城的「可能认识的人」等推荐仅基于公开规则计算：'
          '教育经历交集（同校/同届/同班）、家乡交集（同乡/同镇）与共同好友。'
          '交集越明确，排序越靠前；规则对全体用户一致，可解释、可复核。',
    ),
    (
      '不包含的因素',
      '推荐结果不含任何付费因子，商业合作不影响排序；'
          '不采集浏览轨迹做个性化追踪画像，不向第三方出售或共享画像数据。',
    ),
    (
      '你的选择权',
      '如不希望使用个性化推荐，可在「我 → 隐私设置 → 个性化推荐」一键关闭。'
          '关闭后停止展示推荐好友，仍可主动检索同学和老乡，'
          '且不影响找人、聊天等核心功能。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('推荐算法基本原理公示')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            const Text(
              '依据《互联网信息服务算法推荐管理规定》第十六条，'
              '现将本应用推荐算法的基本原理公示如下：',
              style: TextStyle(fontSize: 15, color: kDimiGray99, height: 1.7),
            ),
            const SizedBox(height: 8),
            for (final (title, body) in _sections) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: kDimiText,
                  ),
                ),
              ),
              Text(
                body,
                style: const TextStyle(
                    fontSize: 16, color: kDimiText, height: 1.8),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
