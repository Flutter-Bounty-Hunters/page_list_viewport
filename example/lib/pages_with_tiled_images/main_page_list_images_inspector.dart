import 'package:example/pages_with_tiled_images/logging.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

import 'image_cache.dart';
import 'page_with_tile_images.dart';

void main() {
  PageListViewportLogs.initLoggers(Level.ALL, {
    // PageListViewportLogs.pagesList,
  });

  ImageTileLogs.initLoggers(Level.FINER, {
    // ImageTileLogs.pageLayout,
    // ImageTileLogs.pagePainting,
    // ImageTileLogs.tilesCache,
    // ImageTileLogs.tilePreparer,
    // ImageTileLogs.tilePipeline,
    // ImageTileLogs.tileDisplay,
    // ImageTileLogs.memoryUsage,
  });

  WidgetsFlutterBinding.ensureInitialized();

  runApp(const PageListImagesInspectorDemo());
}

class PageListImagesInspectorDemo extends StatefulWidget {
  const PageListImagesInspectorDemo({Key? key}) : super(key: key);

  @override
  State<PageListImagesInspectorDemo> createState() => _PageListImagesInspectorDemoState();
}

class _PageListImagesInspectorDemoState extends State<PageListImagesInspectorDemo> with TickerProviderStateMixin {
  static final _naturalPageSize = const Size(8.5, 11) * 14.4;

  final _pageViewportKey = GlobalKey();
  late PageListViewportController _viewportController;

  late final TileImageCache _tileCache;

  @override
  void initState() {
    super.initState();

    _viewportController = PageListViewportController(vsync: this);

    _tileCache = TileImageCache(
      maxTileCount: 96,
      tilePainter: DocumentPageTileImagePainter(),
    );
  }

  @override
  void dispose() {
    _tileCache.dispose();
    _viewportController.dispose();
    super.dispose();
  }

  final _verticalAnimationDistance = 800;
  AnimationController? _verticalPanningAnimation;
  double? _previousFrameVerticalOffset;
  void _toggleVerticalPanningAnimation() {
    if (_verticalPanningAnimation == null) {
      // Start the animation
      _previousFrameVerticalOffset = 0;
      _verticalPanningAnimation = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )
        ..addListener(() {
          final offsetAtTime =
              _verticalAnimationDistance * Curves.easeInOut.transform(_verticalPanningAnimation!.value);
          _viewportController.origin += Offset(0, _previousFrameVerticalOffset! - offsetAtTime);
          _previousFrameVerticalOffset = offsetAtTime;
        })
        ..addStatusListener((status) {
          switch (status) {
            case AnimationStatus.dismissed:
              _verticalPanningAnimation!.forward();
              break;
            case AnimationStatus.completed:
              _verticalPanningAnimation!.reverse();
              break;
            case AnimationStatus.forward:
            case AnimationStatus.reverse:
              // TODO: Handle this case.
              break;
          }
        })
        ..forward();
    } else {
      // Stop the animation
      _verticalPanningAnimation!.dispose();
      _verticalPanningAnimation = null;
    }
  }

  final _horizontalAnimationDistance = 400;
  AnimationController? _horizontalPanningAnimation;
  double? _previousFrameHorizontalOffset;
  void _toggleHorizontalPanningAnimation() {
    if (_horizontalPanningAnimation == null) {
      // Start the animation
      _previousFrameHorizontalOffset = 0;
      _horizontalPanningAnimation = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )
        ..addListener(() {
          final offsetAtTime =
              _horizontalAnimationDistance * Curves.easeInOut.transform(_horizontalPanningAnimation!.value);
          _viewportController.origin += Offset(_previousFrameHorizontalOffset! - offsetAtTime, 0);
          _previousFrameHorizontalOffset = offsetAtTime;
        })
        ..addStatusListener((status) {
          switch (status) {
            case AnimationStatus.dismissed:
              _horizontalPanningAnimation!.forward();
              break;
            case AnimationStatus.completed:
              _horizontalPanningAnimation!.reverse();
              break;
            case AnimationStatus.forward:
            case AnimationStatus.reverse:
              // TODO: Handle this case.
              break;
          }
        })
        ..forward();
    } else {
      // Stop the animation
      _horizontalPanningAnimation!.dispose();
      _horizontalPanningAnimation = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF444444),
        body: _buildViewport(),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton(
              onPressed: _toggleHorizontalPanningAnimation,
              child: const Icon(Icons.compare_arrows),
            ),
            const SizedBox(height: 12),
            FloatingActionButton(
              onPressed: _toggleVerticalPanningAnimation,
              child: const Icon(Icons.arrow_downward_sharp),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewport() {
    return RepaintBoundary(
      child: PageListPerformanceOptimizer(
        controller: _viewportController,
        child: PageListViewportGestures(
          controller: _viewportController,
          child: PageListViewport(
            key: _pageViewportKey,
            controller: _viewportController,
            pageCount: 20,
            naturalPageSize: _naturalPageSize,
            pageLayoutCacheCount: 2,
            builder: (BuildContext context, int pageIndex) {
              return PageWithTileImages(
                tileCache: _tileCache,
                pageIndex: pageIndex,
                naturalSize: _naturalPageSize,
                levelZeroTileFilterQuality: FilterQuality.medium,
                showTileBounds: true,
              );
            },
          ),
        ),
      ),
    );
  }
}
