/// 头像组件：avatarUrl 非空时用 CachedNetworkImage 加载（占位/错误均回退
/// 首字方案）；相对路径（/media/<id>.jpg）经 ApiConfig.resolveMediaUrl 补全。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/config.dart';
import '../theme.dart';

class DimiAvatar extends StatelessWidget {
  const DimiAvatar({
    super.key,
    this.name,
    this.avatarUrl,
    this.size = 46,
    this.seed,
  });

  final String? name;
  final String? avatarUrl;
  final double size;

  /// 颜色种子（一般用 userId），保证同一个人颜色稳定
  final int? seed;

  /// 莫兰迪灰调 7 色兜底调色板（低饱和绿/杏/蓝/紫/棕系）
  static const _palette = <Color>[
    Color(0xFFDFE9E2),
    Color(0xFFEEE2D8),
    Color(0xFFE1E8EF),
    Color(0xFFE9E2EC),
    Color(0xFFEBE7DC),
    Color(0xFFE0EBE5),
    Color(0xFFF0E2DE),
  ];

  @override
  Widget build(BuildContext context) {
    final url = avatarUrl;
    final borderRadius = BorderRadius.circular(kDimiRadiusAvatar);
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: CachedNetworkImage(
          imageUrl: ApiConfig.resolveMediaUrl(url),
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, __) => _placeholder(borderRadius),
          errorWidget: (_, __, ___) => _placeholder(borderRadius),
        ),
      );
    }
    return _placeholder(borderRadius);
  }

  Widget _placeholder(BorderRadius borderRadius) {
    final n = (name ?? '').trim();
    final initial = n.isEmpty ? '?' : n.characters.first;
    final idx = ((seed ?? n.hashCode) % _palette.length).abs();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _palette[idx],
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: kDimiText,
          fontSize: size * 0.4,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
