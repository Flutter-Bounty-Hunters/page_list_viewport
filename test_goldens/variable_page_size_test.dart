import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_goldens/flutter_test_goldens.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  group('PageListViewport > variable page size >', () {
    testGoldenScene('renders the desired page at first layout', (WidgetTester tester) async {
      await Gallery(
        'Starts at the desided page',
        fileName: 'variable_page_size_initial_page',
        layout: const FlexSceneLayout.row(),
      )
          .itemFromWidget(
            description: 'Starts at page 11 (vertically centered)',
            widget: const _TestAppPage(
              initialPage: 11,
            ),
            constraints: BoxConstraints.tight(const Size(800, 800)),
          )
          .itemFromWidget(
            description: 'Starts at page 20',
            widget: const _TestAppPage(
              initialPage: 20,
            ),
            constraints: BoxConstraints.tight(const Size(800, 800)),
          )
          .run(tester);
    });

    testGoldenScene('jumps to page', (WidgetTester tester) async {
      await Timeline(
        'Jumps to page',
        fileName: 'variable_page_size_jumps_to_page',
        layout: const FlexSceneLayout.row(),
        windowSize: const Size(800, 800),
      ) //
          .setupWithWidget(const _TestAppPage(initialPage: 6))
          .takePhoto('Starts at page 6')
          .modifyScene(
            (tester, context) async {
              final controller = _findPageController(tester);
              controller.jumpToPage(49);
              await tester.pump();
            },
          )
          .takePhoto('Jumps to page 49 (vertically centered)')
          .run(tester);
    });

    testGoldenScene('animates to page', (WidgetTester tester) async {
      await Timeline(
        'Animates to page',
        fileName: 'variable_page_size_animates_to_page',
        layout: const FlexSceneLayout.row(),
        windowSize: const Size(800, 800),
      ) //
          .setupWithWidget(const _TestAppPage(initialPage: 6))
          .takePhoto('Starts at page 6')
          .modifyScene(
            (tester, context) async {
              final controller = _findPageController(tester);
              controller.animateToPage(49, const Duration(milliseconds: 300));
              // Pump to allow the animation to start.
              await tester.pump();
            },
          )
          .takePhotos(3, const Duration(milliseconds: 100), 'Animates to page 49 (vertically centered) - frame')
          .run(tester);
    });

    testGoldenScene('performs zoom in and out', (WidgetTester tester) async {
      late TestGesture firstFingerGesture;
      late TestGesture secondFingerGesture;

      await Timeline(
        'Performs zoom in and out',
        fileName: 'variable_page_size_performs_zoom_in_and_out',
        layout: const FlexSceneLayout.row(),
        windowSize: const Size(800, 800),
      ) //
          .setupWithWidget(const _TestAppPage(initialPage: 5))
          .takePhoto('Baseline scale')
          .modifyScene(
            (tester, context) async {
              // Start two finger gestures at the same time.
              firstFingerGesture = await tester.startGesture(const Offset(350, 400));
              secondFingerGesture = await tester.startGesture(const Offset(450, 400));

              // Move fingers apart to zoom in.
              await firstFingerGesture.moveBy(const Offset(-50, 0));
              await secondFingerGesture.moveBy(const Offset(50, 0));
              await tester.pump();
            },
          )
          .takePhoto('Zooms in')
          .modifyScene(
            (tester, context) async {
              // Move fingers back together to zoom out, closer together than the original position,
              // to ensure that the viewport forces the page to fill the viewport's width.
              await firstFingerGesture.moveBy(const Offset(90, 0));
              await secondFingerGesture.moveBy(const Offset(-90, 0));
              await tester.pump();
            },
          )
          .takePhoto('Zooms out')
          .modifyScene((tester, context) async {
            // Releases the fingers.
            await firstFingerGesture.up();
            await secondFingerGesture.up();
          })
          .run(tester);
    });
  });
}

PageListViewportWithVariableSizeController _findPageController(WidgetTester tester) {
  final state = tester.state<_TestAppPageState>(find.byType(_TestAppPage));
  return state.controller;
}

class _TestAppPage extends StatefulWidget {
  const _TestAppPage({
    this.initialPage,
  });

  final int? initialPage;

  @override
  State<_TestAppPage> createState() => _TestAppPageState();
}

/// A widget that displays a [PageListViewportWithVariablePageSize], intercalating
/// between vertical and horizontal aspect ratios for each page.
///
/// Each page has a centered circle, which scales its size based on the incoming constraints,
/// and the natural size of the page.
class _TestAppPageState extends State<_TestAppPage> with TickerProviderStateMixin {
  static const _pageCount = 200;

  static const _pageSizes = [
    Size(8.5, 11), // Letter
    Size(11, 8.5), // Letter (inverse)
  ];

  late final PageListViewportWithVariableSizeController controller;

  @override
  void initState() {
    super.initState();
    controller = widget.initialPage != null
        ? PageListViewportWithVariableSizeController.startAtPage(
            pageIndex: widget.initialPage!,
            vsync: this,
          )
        : PageListViewportWithVariableSizeController(vsync: this);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildViewport(),
    );
  }

  Widget _buildViewport() {
    return Stack(
      children: [
        PageListViewportGestures(
          controller: controller,
          lockPanAxis: true,
          child: PageListViewport.variedPages(
            controller: controller,
            pageCount: _pageCount,
            onGetNaturalPageSize: (pageIndex) =>
                _pageSizes[pageIndex % _pageSizes.length] * 72 * MediaQuery.of(context).devicePixelRatio,
            pageLayoutCacheCount: 3,
            pagePaintCacheCount: 3,
            builder: (BuildContext context, int pageIndex) {
              return _buildPage(pageIndex);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPage(int pageIndex) {
    final pageSize = Size(
      _pageSizes[pageIndex % _pageSizes.length].width * 72,
      _pageSizes[pageIndex % _pageSizes.length].height * 72,
    );

    return Container(
      color: Colors.white,
      child: Container(
        color: Colors.primaries[pageIndex % Colors.primaries.length],
        width: pageSize.width,
        height: pageSize.height,
        child: Center(
          child: LayoutBuilder(builder: (context, constraints) {
            return Container(
              width: 300 * (constraints.maxWidth / pageSize.width),
              height: 300 * (constraints.maxHeight / pageSize.height),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: FittedBox(
                  child: Text(
                    '$pageIndex',
                    style: const TextStyle(
                      fontSize: 24,
                      fontFamily: TestFonts.openSans,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
