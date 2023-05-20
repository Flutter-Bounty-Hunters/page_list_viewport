import 'package:example/momentum_verification/velocity_plotter.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  PageListViewportLogs.initLoggers(Level.ALL, {
    // PageListViewportLogs.pagesList,
    PageListViewportLogs.pagesListGesturesVelocity,
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Page List Viewport Demo',
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
  static const _pageCount = 20;
  static const _naturalPageSizeInInches = Size(8.5, 11);

  late final PageListViewportController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageListViewportController.startAtPage(pageIndex: 5, vsync: this);
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
            child: _buildViewport(),
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
          child: PageListViewport(
            controller: _controller,
            pageCount: _pageCount,
            naturalPageSize: _naturalPageSizeInInches * 72 * MediaQuery.of(context).devicePixelRatio,
            pageLayoutCacheCount: 3,
            pagePaintCacheCount: 3,
            builder: (BuildContext context, int pageIndex) {
              return Stack(
                children: [
                  Positioned.fill(
                    child: _buildPage(pageIndex),
                  ),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(32),
                      color: Colors.white,
                      child: Text("Page: $pageIndex"),
                    ),
                  )
                ],
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 300,
          child: ColoredBox(
            color: Colors.black.withOpacity(0.5),
            child: VelocityPlotter(
              controller: _controller,
              max: const Offset(6000, 6000),
            ),
          ),
        )
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
                  aspectRatio: _naturalPageSizeInInches.aspectRatio,
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
    return Image.asset(
      "assets/test-image.jpeg",
      fit: BoxFit.cover,
    );
  }
}
