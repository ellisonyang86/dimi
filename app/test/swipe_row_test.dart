import 'package:dimi/theme.dart';
import 'package:dimi/widgets/common/dimi_swipe_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('左滑只展开按钮，点击执行一次；展开另一行会关闭前一行', (tester) async {
    final controller = DimiSwipeController();
    addTearDown(controller.dispose);
    var actions = 0;
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
        theme: buildDimiTheme(),
        home: Scaffold(
          body: Column(children: [
            for (var id = 0; id < 2; id++)
              DimiSwipeRow(
                  id: id,
                  controller: controller,
                  actions: [
                    DimiSwipeAction(
                        label: '删除$id',
                        icon: Icons.delete_outline,
                        onPressed: () => actions++),
                  ],
                  child: ListTile(title: Text('会话$id'), onTap: () => opened++)),
          ]),
        )));
    await tester.drag(find.text('会话0'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(controller.value, 0);
    expect(actions, 0);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.drag(find.text('会话1'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(controller.value, 1);
    expect(find.text('删除0').hitTestable(), findsNothing);
    await tester.tap(find.text('删除1'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(controller.value, isNull);
    expect(opened, 0);
    await tester.tap(find.text('会话1'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('窄屏大字下三项操作不溢出，右滑和点击行内容可收起', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DimiSwipeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: buildDimiTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
              body: DimiSwipeRow(
                  id: 1,
                  controller: controller,
                  actions: [
                    for (final label in ['取消置顶', '更多', '删除'])
                      DimiSwipeAction(
                          label: label,
                          icon: Icons.more_horiz,
                          onPressed: () {}),
                  ],
                  child: const ListTile(
                      title: Text('老同学'), subtitle: Text('最近的一条消息')))),
        )));
    await tester.drag(find.text('老同学'), const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.dragFrom(const Offset(30, 32), const Offset(240, 0));
    await tester.pumpAndSettle();
    expect(controller.value, isNull);
    await tester.drag(find.text('老同学'), const Offset(-240, 0));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 32));
    await tester.pumpAndSettle();
    expect(controller.value, isNull);
  });
}
