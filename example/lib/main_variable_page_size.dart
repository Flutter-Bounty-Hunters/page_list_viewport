import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  PageListViewportLogs.initLoggers(Level.ALL, {});

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Page List Viewport Variable Size Demo',
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
  });

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with TickerProviderStateMixin {
  static const _pageCount = 200;

  static const _pageSizes = [
    Size(8.5, 11), // Letter
    Size(11, 8.5), // Letter (inverse)
  ];

  late final PageListViewportWithVariableSizeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageListViewportWithVariableSizeController.startAtPage(pageIndex: 5, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 125,
            child: _buildThumbnailList(),
          ),
          Expanded(
            child: Center(
              child: SizedBox(
                height: _pageSizes[0].height * 72 * MediaQuery.of(context).devicePixelRatio,
                width: _pageSizes[0].width * 72 * MediaQuery.of(context).devicePixelRatio,
                child: _buildViewport(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewport() {
    return Stack(
      children: [
        PageListViewportGestures(
          controller: _controller,
          lockPanAxis: true,
          child: PageListViewport.variedPageSized(
            controller: _controller,
            pageCount: _pageCount,
            onGetNaturalPageSize: (pageIndex) =>
                _pageSizes[pageIndex % _pageSizes.length] * 72 * MediaQuery.of(context).devicePixelRatio,
            pageLayoutCacheCount: 3,
            pagePaintCacheCount: 3,
            builder: (BuildContext context, int pageIndex) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => print('tapped at pageIndex: $pageIndex'),
                      child: _buildPage(pageIndex),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildThumbnailList() {
    return RepaintBoundary(
      child: ColoredBox(
        color: Colors.grey.shade800,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _pageCount,
          itemBuilder: (context, index) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: GestureDetector(
                onTap: () {
                  _controller.animateToPage(index, const Duration(milliseconds: 250));
                },
                child: AspectRatio(
                  aspectRatio: _pageSizes[index % _pageSizes.length].aspectRatio,
                  child: _buildPage(index),
                ),
              ),
            );
          },
        ),
      ),
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
                    'Page $pageIndex',
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
