import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  group("Page list viewport scrolling >", () {
    group("clamping >", () {
      testWidgets("ballistic motion stops at its natural location", (widgetTester) async {
        final controller = PageListViewportController(vsync: widgetTester);
        await _pumpPageListViewport(
          widgetTester,
          controller: controller,
          scrollSettlingBehavior: ScrollSettlingBehavior.natural,
        );

        await widgetTester.fling(find.byType(MaterialApp), const Offset(0, -500), 2900);
        await widgetTester.pumpAndSettle();

        // Ensure that the final resting place wasn't adjusted at all.
        //
        // If dynamics ever change such that this test needs to be updated, make sure
        // that the new final resting place is a value that wouldn't be accepted by
        // whole-pixel or half-pixel clamps, i.e., create a value with a fraction that's
        // in [0.1, 0.4],[0.6, 0.9].
        const expectedRestingPlace = Offset(0, -1721.3);
        final distanceToExpectedRestingPlace = (controller.origin - expectedRestingPlace).distance;
        expect(
          distanceToExpectedRestingPlace,
          lessThan(0.1),
          reason:
              "Expected resting place: $expectedRestingPlace, actual resting place: ${controller.origin}, difference: $distanceToExpectedRestingPlace",
        );
      });

      testWidgets("ballistic motion stops at whole pixel value", (widgetTester) async {
        final controller = PageListViewportController(vsync: widgetTester);
        await _pumpPageListViewport(
          widgetTester,
          controller: controller,
          scrollSettlingBehavior: ScrollSettlingBehavior.wholePixel,
        );

        await widgetTester.fling(find.byType(MaterialApp), const Offset(0, -500), 2900);
        await widgetTester.pumpAndSettle();

        // Ensure that we clamped at a whole pixel value.
        //
        // If dynamics ever change such that this test needs to be updated, make sure
        // that the new final resting place is somewhere between [0.1, 0.9] so that
        // the clamping behavior shifts the fraction to a whole pixel value.
        const expectedRestingPlace = Offset(0, -1721.0);
        final distanceToExpectedRestingPlace = (controller.origin - expectedRestingPlace).distance;
        expect(
          distanceToExpectedRestingPlace,
          lessThan(0.1),
          reason:
              "Expected resting place: $expectedRestingPlace, actual resting place: ${controller.origin}, difference: $distanceToExpectedRestingPlace",
        );
      });

      testWidgets("ballistic motion stops at half pixel value", (widgetTester) async {
        final controller = PageListViewportController(vsync: widgetTester);
        await _pumpPageListViewport(
          widgetTester,
          controller: controller,
          scrollSettlingBehavior: ScrollSettlingBehavior.halfPixel,
        );

        await widgetTester.fling(find.byType(MaterialApp), const Offset(0, -500), 2900);
        await widgetTester.pumpAndSettle();

        // Ensure that we clamped halfway between two pixels.
        //
        // If dynamics ever change such that this test needs to be updated, make sure
        // that the new final resting place is somewhere between [0.3, 0.7] (but not 0.5)
        // so that the clamping behavior clamps to `0.5`.
        const expectedRestingPlace = Offset(0, -1721.5);
        final distanceToExpectedRestingPlace = (controller.origin - expectedRestingPlace).distance;
        expect(
          distanceToExpectedRestingPlace,
          lessThan(0.1),
          reason:
              "Expected resting place: $expectedRestingPlace, actual resting place: ${controller.origin}, difference: $distanceToExpectedRestingPlace",
        );
      });

      group("ScrollSettlingBehavior >", () {
        test("natural ballistics", () {
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-1.0, -1.0)), const Offset(-1.0, -1.0));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.9, -0.9)), const Offset(-0.9, -0.9));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.8, -0.8)), const Offset(-0.8, -0.8));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.7, -0.7)), const Offset(-0.7, -0.7));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.6, -0.6)), const Offset(-0.6, -0.6));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.5, -0.5)), const Offset(-0.5, -0.5));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.4, -0.4)), const Offset(-0.4, -0.4));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.3, -0.3)), const Offset(-0.3, -0.3));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.2, -0.2)), const Offset(-0.2, -0.2));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(-0.1, -0.1)), const Offset(-0.1, -0.1));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0, 0)), const Offset(0, 0));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.1, 0.1)), const Offset(0.1, 0.1));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.2, 0.2)), const Offset(0.2, 0.2));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.3, 0.3)), const Offset(0.3, 0.3));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.4, 0.4)), const Offset(0.4, 0.4));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.5, 0.5)), const Offset(0.5, 0.5));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.6, 0.6)), const Offset(0.6, 0.6));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.7, 0.7)), const Offset(0.7, 0.7));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.8, 0.8)), const Offset(0.8, 0.8));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(0.9, 0.9)), const Offset(0.9, 0.9));
          expect(ScrollSettlingBehavior.natural.correctFinalOffset(const Offset(1.0, 1.0)), const Offset(1.0, 1.0));
        });

        test("whole pixel clamping", () {
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-1.0, -1.0)),
            const Offset(-1.0, -1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.9, -0.9)),
            const Offset(-1.0, -1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.8, -0.8)),
            const Offset(-1.0, -1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.7, -0.7)),
            const Offset(-1.0, -1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.6, -0.6)),
            const Offset(-1.0, -1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.5, -0.5)),
            const Offset(-1.0, -1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.4, -0.4)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.3, -0.3)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.2, -0.2)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(-0.1, -0.1)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0, 0)),
            const Offset(0, 0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.1, 0.1)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.2, 0.2)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.3, 0.3)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.4, 0.4)),
            const Offset(0.0, 0.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.5, 0.5)),
            const Offset(1.0, 1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.6, 0.6)),
            const Offset(1.0, 1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.7, 0.7)),
            const Offset(1.0, 1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.8, 0.8)),
            const Offset(1.0, 1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(0.9, 0.9)),
            const Offset(1.0, 1.0),
          );
          expect(
            ScrollSettlingBehavior.wholePixel.correctFinalOffset(const Offset(1.0, 1.0)),
            const Offset(1.0, 1.0),
          );
        });

        test("half pixel clamping", () {
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-1.0, -1.0)), const Offset(-1.0, -1.0));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.9, -0.9)), const Offset(-1.0, -1.0));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.8, -0.8)), const Offset(-1.0, -1.0));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.7, -0.7)), const Offset(-0.5, -0.5));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.6, -0.6)), const Offset(-0.5, -0.5));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.5, -0.5)), const Offset(-0.5, -0.5));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.4, -0.4)), const Offset(-0.5, -0.5));
          expect(
              ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.3, -0.3)), const Offset(-0.5, -0.5));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.2, -0.2)), const Offset(0.0, 0.0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(-0.1, -0.1)), const Offset(0.0, 0.0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0, 0)), const Offset(0, 0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.1, 0.1)), const Offset(0.0, 0.0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.2, 0.2)), const Offset(0.0, 0.0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.3, 0.3)), const Offset(0.5, 0.5));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.4, 0.4)), const Offset(0.5, 0.5));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.5, 0.5)), const Offset(0.5, 0.5));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.6, 0.6)), const Offset(0.5, 0.5));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.7, 0.7)), const Offset(0.5, 0.5));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.8, 0.8)), const Offset(1.0, 1.0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(0.9, 0.9)), const Offset(1.0, 1.0));
          expect(ScrollSettlingBehavior.halfPixel.correctFinalOffset(const Offset(1.0, 1.0)), const Offset(1.0, 1.0));
        });
      });
    });
  });
}

Future<void> _pumpPageListViewport(
  WidgetTester widgetTester, {
  PageListViewportController? controller,
  ScrollSettlingBehavior scrollSettlingBehavior = ScrollSettlingBehavior.natural,
}) async {
  controller ??= PageListViewportController(vsync: widgetTester);

  await widgetTester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PageListViewportGestures(
          controller: controller,
          scrollSettleBehavior: scrollSettlingBehavior,
          lockPanAxis: true,
          child: PageListViewport(
            controller: controller,
            pageCount: 100,
            naturalPageSize: const Size(8.5, 11) * 72 * widgetTester.view.devicePixelRatio,
            builder: (BuildContext context, int pageIndex) {
              return Center(
                child: Container(
                  padding: const EdgeInsets.all(32),
                  color: Colors.white,
                  child: Text("Page: $pageIndex"),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}
