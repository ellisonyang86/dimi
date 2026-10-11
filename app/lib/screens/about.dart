/// 「关于 DIMI」：版本信息 + 法务文档入口（用户服务协议 / 隐私政策 /
/// 推荐算法公示）+ 证照信息 + 版权行。入口在 MeTab。
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/config.dart';
import '../theme.dart';
import '../widgets/common/dimi_brand_logo.dart';
import 'algorithm_disclosure.dart';
import 'legal_doc.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDimiBg,
      appBar: AppBar(title: const Text('关于 DIMI')),
      body: ListView(
        children: [
          const SizedBox(height: 36),
          const Center(child: DimiBrandLogo(size: 72)),
          const SizedBox(height: 10),
          const Text(
            'DIMI · 围城',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: kDimiText,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '版本 1.0.0',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: kDimiGray99),
          ),
          const SizedBox(height: 28),
          _entry(
            context,
            title: '用户服务协议',
            onTap: () => _openLegal(
              context,
              title: '用户服务协议',
              urlPath: kUserAgreementPath,
            ),
          ),
          _entry(
            context,
            title: '隐私政策',
            onTap: () => _openLegal(
              context,
              title: '隐私政策',
              urlPath: kPrivacyPolicyPath,
            ),
          ),
          _entry(
            context,
            title: '推荐算法基本原理公示',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const AlgorithmDisclosureScreen(),
            )),
          ),
          const SizedBox(height: 36),
          // App/ICP 备案号：发布构建经 --dart-define=ICP_NUMBER 注入，空则不展示
          if (ApiConfig.icpNumber.isNotEmpty) ...[
            const Text(
              'ICP 备案号：${ApiConfig.icpNumber}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: kDimiGray99),
            ),
            const SizedBox(height: 6),
          ],
          const Text(
            '© 2026 DIMI·围城团队 版权所有',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: kDimiGray99),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _openLegal(BuildContext context,
      {required String title, required String urlPath}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LegalDocScreen(title: title, urlPath: urlPath),
    ));
  }

  Widget _entry(BuildContext context,
      {required String title, required VoidCallback onTap}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        trailing: const Icon(Icons.chevron_right, color: kDimiGrayCC),
        onTap: onTap,
      ),
    );
  }
}
