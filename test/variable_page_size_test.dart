import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  group('PageListViewport > variable page size >', () {
    testWidgets('hit tests the pages', (tester) async {
      // Holds the page indices that were tapped.
      final tappedPages = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: _TestAppPage(
            onPageTapped: (pageIndex) => tappedPages.add(pageIndex),
          ),
        ),
      );

      // Tap on the first page.
      await tester.tap(find.text('0'));
      await tester.pump();

      // Jump to the eleventh page.
      final controller = _findPageController(tester);
      controller.jumpToPage(11);
      await tester.pumpAndSettle();

      // Tap on the the eleventh page.
      await tester.tap(find.text('11'));
      await tester.pump();

      // Jump to the fiftieth page.
      controller.jumpToPage(50);
      await tester.pumpAndSettle();

      // Tap on the the fiftieth page.
      await tester.tap(find.text('50'));
      await tester.pump();

      // Ensure the taps were reported for the correct pages.
      expect(tappedPages, [0, 11, 50]);
    });
  });
}

PageListViewportWithVariableSizeController _findPageController(WidgetTester tester) {
  final state = tester.state<_TestAppPageState>(find.byType(_TestAppPage));
  return state.controller;
}

/// A widget that displays a [PageListViewportWithVariablePageSize], intercalating
/// between vertical and horizontal aspect ratios for each page.
///
/// Each page has a centered circle, which scales its size based on the incoming constraints,
/// and the natural size of the page.
class _TestAppPage extends StatefulWidget {
  const _TestAppPage({this.onPageTapped});

  final void Function(int pageIndex)? onPageTapped;

  @override
  State<_TestAppPage> createState() => _TestAppPageState();
}

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
    controller = PageListViewportWithVariableSizeController(vsync: this);
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
              return GestureDetector(
                onTap: () => widget.onPageTapped?.call(pageIndex),
                child: _buildPage(pageIndex),
              );
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
                    style: const TextStyle(fontSize: 24),
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
