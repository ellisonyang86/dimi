/// DIMI · 围城 全局主题色板 —— 莫兰迪柔和色系（低饱和、带灰调）。
/// 替代原微信绿 #07C160；所有界面颜色统一从这里取，不再散落硬编码。
library;

import 'package:flutter/material.dart';

/// 黛绿：主色（按钮、强调、选中态）—— 莫兰迪灰调但足够深，保证辨识度
const Color kDimiPrimary = Color(0xFF536B61);

/// 主操作浅填充；主色深色只用于文字、图标及必要的状态标记。
const Color kDimiPrimaryFill = Color(0xFFDFE9E2);

/// 主色浅底：图标底衬、标签底色、导航选中指示
const Color kDimiPrimarySoft = Color(0xFFEDF3EF);
const Color kDimiNeutralSoft = Color(0xFFF0F2F1);

/// 暖米白：页面背景
const Color kDimiBg = Color(0xFFF7F8F5);
const Color kDimiHairline = Color(0xFFE9EDE8);

/// 墨灰绿：标题与正文深色
const Color kDimiText = Color(0xFF3B423D);

/// 雾杏色：次强调（老乡标签、提示性高亮）
const Color kDimiApricot = Color(0xFFC9A188);

/// 深雾杏：浅底上的文字/图标用（kDimiApricot 直接压浅底对比度不足）。
/// 调深至 #8A5F3D：白底 5.5:1、雾杏浅底 4.7:1，均过 WCAG 4.5:1 正文线
const Color kDimiApricotDeep = Color(0xFF805F4B);

/// 雾杏浅底
const Color kDimiApricotSoft = Color(0xFFF6EEE7);

/// 灰色阶：辅助文字 / 图标 / 占位。
/// Gray99 用于辅助文字；在页面、白色与浅灰输入底上保持可读对比度。
const Color kDimiGray99 = Color(0xFF6E6E6E);
const Color kDimiGrayBB = Color(0xFFBBBBBB);
const Color kDimiGrayCC = Color(0xFFCCCCCC);
const Color kDimiGray55 = Color(0xFF555555);
const Color kDimiGray66 = Color(0xFF666666);

/// 警示红：删除、拉黑等破坏性操作
const Color kDimiDanger = Color(0xFF994E46);
const Color kDimiDangerSoft = Color(0xFFF8E9E6);

/// 灰调绿：成功态（支付成功、审核通过等正向反馈）
const Color kDimiSuccess = Color(0xFF5B8A72);

/// 灰调绿浅底
const Color kDimiSuccessSoft = Color(0xFFE9F0EB);

/// 灰调杏橙：警告态（防爬提示、内容风险提醒等）
const Color kDimiWarning = Color(0xFFB98A52);

/// 灰调杏橙浅底
const Color kDimiWarningSoft = Color(0xFFF5EDE1);

/// 深警示杏橙：小字/图标压 kDimiWarningSoft 浅底或白底用
/// （kDimiWarning 白底仅 3.1:1、浅底 2.7:1；本值白底 5.9:1、浅底 5.1:1）
const Color kDimiWarningDeep = Color(0xFF8A5A2B);

/// 灰调蓝：信息态（系统通知、中性提示）
const Color kDimiInfo = Color(0xFF6B8299);

/// 灰调蓝浅底
const Color kDimiInfoSoft = Color(0xFFEBEFF3);

/// 未读红点
const Color kDimiBadge = kDimiDanger;

/// 聊天页专用背景（有意区别于页面背景 kDimiBg）
const Color kDimiChatBg = Color(0xFFF2F5F1);

/// 图片半透明遮罩（图集页码角标、图片删除钮等压图控件）
const Color kDimiImageMask = Color(0x99000000);

/// 4pt 网格间距
const double kDimiSpace4 = 4;
const double kDimiSpace8 = 8;
const double kDimiSpace10 = 10;
const double kDimiSpace12 = 12;
const double kDimiSpace14 = 14;
const double kDimiSpace16 = 16;

/// 圆角：卡片
const double kDimiRadiusCard = 12;

/// 圆角：聊天气泡
const double kDimiRadiusBubble = 12;

/// 圆角：输入框 / 按钮
const double kDimiRadiusInput = 10;

/// 圆角：底部弹层 / 对话框
const double kDimiRadiusSheet = 20;

/// 圆角：头像
const double kDimiRadiusAvatar = 8;

/// 全局主题（MaterialApp 与隐私同意前置页共用）
ThemeData buildDimiTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kDimiPrimary,
    primary: kDimiPrimary,
    onPrimary: Colors.white,
    secondary: kDimiApricotDeep,
    surface: Colors.white,
    onSurface: kDimiText,
    error: kDimiDanger,
    brightness: Brightness.light,
  );

  /// 按钮统一：最小 64×48（中老年友好触达区）、圆角 10、字号 17
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kDimiRadiusInput),
  );
  const buttonMinSize = Size(64, 48);
  const buttonTextStyle = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kDimiBg,
    iconTheme: const IconThemeData(color: kDimiPrimary, size: 24),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      disabledElevation: 0,
      backgroundColor: kDimiPrimaryFill,
      foregroundColor: kDimiPrimary,
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDimiRadiusCard),
        side: const BorderSide(color: kDimiHairline),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: kDimiBg,
      foregroundColor: kDimiText,
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    textTheme: const TextTheme(
      displaySmall: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: kDimiText,
          height: 1.5),
      titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: kDimiText,
          height: 1.5),
      titleMedium: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: kDimiText,
          height: 1.5),
      bodyLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w400,
          color: kDimiText,
          height: 1.5),
      bodyMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: kDimiText,
          height: 1.5),
      bodySmall: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: kDimiText,
          height: 1.5),
    ),
    // 扁平化卡片：白底与页面底色分层，无描边、无投影。
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDimiRadiusCard),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kDimiPrimaryFill,
        foregroundColor: kDimiPrimary,
        disabledBackgroundColor: kDimiNeutralSoft,
        // 禁用态字色默认 onSurface@38% 过浅（<3:1），统一调深
        disabledForegroundColor: kDimiGray66,
        minimumSize: buttonMinSize,
        shape: buttonShape,
        textStyle: buttonTextStyle,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: kDimiPrimarySoft,
        foregroundColor: kDimiPrimary,
        disabledForegroundColor: kDimiGray66,
        minimumSize: buttonMinSize,
        side: BorderSide.none,
        shape: buttonShape,
        textStyle: buttonTextStyle,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: kDimiPrimary,
        disabledForegroundColor: kDimiGray66,
        minimumSize: buttonMinSize,
        shape: buttonShape,
        textStyle: buttonTextStyle,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDimiRadiusSheet),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDimiRadiusInput),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kDimiNeutralSoft,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kDimiRadiusInput),
          borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kDimiRadiusInput),
          borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kDimiRadiusInput),
        borderSide: const BorderSide(color: kDimiPrimary),
      ),
      // 占位提示统一 Gray99（米白/白底 ≥4.5:1），不再用默认浅灰
      hintStyle: const TextStyle(fontSize: 16, color: kDimiGray99),
      errorStyle: const TextStyle(color: kDimiDanger, fontSize: 14),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: kDimiPrimary,
      unselectedLabelColor: kDimiGray66,
      indicatorColor: kDimiPrimary,
      labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 17),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        // 扁平化选中态：主色浅底 + 主色字，不用深绿实底（压抑且易与字色撞色）
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? kDimiPrimary
              : kDimiGray66,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? kDimiPrimaryFill
              : kDimiNeutralSoft,
        ),
        side: WidgetStateProperty.all(BorderSide.none),
        shape: WidgetStateProperty.all(buttonShape),
      ),
    ),
    // 底部导航：去 M3 药丸指示器，对齐微信纯图标变色方案
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? kDimiPrimary
              : kDimiGray99,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 14,
          color: states.contains(WidgetState.selected)
              ? kDimiPrimary
              : kDimiGray99,
        ),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(kDimiRadiusSheet))),
    ),
    dividerTheme: const DividerThemeData(color: kDimiHairline, thickness: 1),
  );
}

/// Preserve Android's nonlinear system scaling when care mode is enabled.
class DimiCareTextScaler extends TextScaler {
  const DimiCareTextScaler(this.systemScaler);
  final TextScaler systemScaler;
  @override
  double scale(double fontSize) => systemScaler.scale(fontSize) * 1.3;
  @override
  double get textScaleFactor => scale(14) / 14;
}
