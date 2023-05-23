import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  group("Panning simulation", () {
    testWidgets("reports zero velocity when it completes", (widgetTester) async {
      final controller = PageListViewportController(vsync: widgetTester);
      await _pumpPageListViewport(widgetTester, controller: controller);

      Offset? latestVelocity;
      controller.addListener(() {
        latestVelocity = controller.velocity;
      });

      // Fling up, to scroll down, and run a panning simulation.
      await widgetTester.fling(find.byType(Scaffold), const Offset(0, -500), 4000);
      await widgetTester.pumpAndSettle();

      // Ensure that the final reported velocity is zero.
      expect(latestVelocity, isNotNull);
      expect(latestVelocity, Offset.zero);
    });
  });
}

Future<void> _pumpPageListViewport(
  WidgetTester tester, {
  PageListViewportController? controller,
  int pageCount = 10,
  Size? naturalPageSize,
  PageBuilder? pageBuilder,
}) async {
  controller ??= PageListViewportController(vsync: tester);
  naturalPageSize ??= const Size(8.5, 11) * 72;
  pageBuilder ??= _defaultPageBuilder;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PageListViewportGestures(
          controller: controller,
          child: PageListViewport(
            controller: controller,
            pageCount: pageCount,
            naturalPageSize: naturalPageSize,
            builder: pageBuilder,
          ),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

Widget _defaultPageBuilder(BuildContext context, int pageIndex) {
  return const ColoredBox(
    color: Colors.white,
  );
}
