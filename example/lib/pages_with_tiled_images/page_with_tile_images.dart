import 'dart:math';

import 'package:example/pages_with_tiled_images/logging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

import 'image_cache.dart';
import 'tiles.dart';

class PageWithTileImages extends LeafRenderObjectWidget {
  PageWithTileImages({
    super.key,
    required this.tileCache,
    required this.pageIndex,
    required this.naturalSize,
    ImageTileStrategy? tileStrategy,
    this.levelZeroTileFilterQuality = FilterQuality.low,
    this.insertNewLayer = false,
    this.preventTileLoading = false,
    this.showTileBounds = false,
  }) : tileStrategy = tileStrategy ?? DefaultImageTileLevelStrategy();

  final TileImageCache tileCache;
  final int pageIndex;
  final Size naturalSize;

  final ImageTileStrategy tileStrategy;

  /// The texture [FilterQuality] that's used to display the Level Zero, full-page tile
  /// for each page.
  ///
  /// The Level Zero filter quality is configurable because that tile, in particular, has
  /// had reports of blurry text. The filter quality might make a difference.
  final FilterQuality levelZeroTileFilterQuality;

  /// Whether to paint this page's tiles in the parent [Layer], or insert our own child
  /// [Layer], and paint the tiles in that [Layer].
  ///
  /// It's unclear whether inserting a layer, or not inserting a layer, has any typical
  /// performance impact. It's possible that positioning tiles within our own [OffsetLayer],
  /// and then retaining that [OffsetLayer], might reduce churn in the layer tree. It's also
  /// possible that it increases churn, depending on the exact situation. We leave this
  /// toggle for developers to experiment with each approach.
  final bool insertNewLayer;

  /// Whether to forcibly prevent this page from loading tiles right now.
  ///
  /// This can be used, for example, to prevent tile loading when scrolling
  /// or panning at rapid speeds.
  final bool preventTileLoading;

  final bool showTileBounds;

  @override
  LeafRenderObjectElement createElement() {
    return PageWithImageTileLayersElement(this);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderPageWithImageTileLayers(
      element: context as PageWithImageTileLayersElement,
      tileCache: tileCache,
      pageIndex: pageIndex,
      naturalSize: naturalSize,
      tileLevelStrategy: tileStrategy,
      levelZeroTileFilterQuality: levelZeroTileFilterQuality,
      insertNewLayer: insertNewLayer,
      preventTileLoading: preventTileLoading,
      showTileBounds: showTileBounds,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderPageWithImageTileLayers renderObject) {
    renderObject //
      ..tileCache = tileCache
      ..pageIndex = pageIndex
      ..naturalSize = naturalSize
      ..tileStrategy = tileStrategy
      ..levelZeroTileFilterQuality = levelZeroTileFilterQuality
      ..insertNewLayer = insertNewLayer
      ..preventTileLoading = preventTileLoading
      ..showTileBounds = showTileBounds;
  }
}

/// The standard tile set for subdividing tiles, chosen based on what seems to work
/// the best on average.
///
/// The creation of this tileset requires non-trivial time, leading to a frame that
/// runs about 70ms. This penalty will be paid when this property is first accessed.
/// You can move that cost to the most desirable place by choosing when you access
/// the tileset.
final defaultImageTileSet = SubdividingTileSet(levels: 6, subdivisionBase: 3);

abstract class ImageTileStrategy {
  SubdividingTileSet get tileSet;

  /// Calculates the "tile level", AKA the subdivision level, to use for rendering
  /// with the given [viewportSize], [pageLayoutSize], and [tileSet].
  ///
  /// Assuming a [tileSet] with a base of `2`, the tile levels subdivide as follows:
  ///  - tile level 0 -> 1x1
  ///  - tile level 1 -> 2x2
  ///  - tile level 2 -> 4x4
  ///  - tile level 3 -> 8x8
  ///  - etc.
  int calculateTileLevel({
    required Size viewportSize,
    required Size pageLayoutSize,
    required Size pageNaturalSize,
  });

  /// Determines the final size of the tile:
  /// tile_size = natural_page_size * tile_scale
  double calculateTileScale({
    required Size viewportSize,
    required Size pageNaturalSize,
    required TileIndex tileIndex,
  });
}

class DefaultImageTileLevelStrategy implements ImageTileStrategy {
  static const _renderZoomLevels = [0.25, 0.5, 1.0, 2.0, 4.0, 7.0];

  DefaultImageTileLevelStrategy([SubdividingTileSet? tileSet]) : _tileSet = tileSet ?? defaultImageTileSet;

  final SubdividingTileSet _tileSet;
  @override
  SubdividingTileSet get tileSet => _tileSet;

  @override
  int calculateTileLevel({
    required Size viewportSize,
    required Size pageLayoutSize,
    required Size pageNaturalSize,
  }) {
    if (pageLayoutSize.width < viewportSize.width * 1.1) {
      // The current page width is roughly as wide as the viewport. In this situation,
      // we want to show a single tile for the page because we don't want to see
      // sub-page tiles loading when we're scrolling through a list of pages at default
      // zoom level. Therefore, we treat this case in a special way.
      ImageTileLogs.pagePainting
          .fine("Setting page tile level to zero because the page is roughly the width of the viewport");
      return 0;
    }

    // Given the available space, what scale/zoom are we laying out, compared to the
    // natural dimensions of the page.
    // TODO: handle portrait case
    final layoutZoomLevel = pageLayoutSize.width / pageNaturalSize.width;

    // Find the next highest render zoom level for our current layout zoom level.
    double? renderZoomLevel;
    for (int i = 0; i < _renderZoomLevels.length; i += 1) {
      if (_renderZoomLevels[i] > layoutZoomLevel) {
        renderZoomLevel = _renderZoomLevels[i];
        break;
      }
    }
    // If we didn't find a render zoom level higher than our layout zoom level, then
    // use the largest available render zoom level.
    renderZoomLevel ??= _renderZoomLevels.last;

    // FIXME: The following code is in flux as we try to figure out the most performant approach
    //        to tile subdivisions. Eventually, get this locked in and commented.

    // TODO: update this comment (and possibly the code) now that we support variable subdivision counts.
    // layoutZoomLevel is the ratio of pixel layout width to natural page width. Example,
    // layout wants to take up 1000px and natural page width is 795px, the value is 1000 / 795.
    //
    // We want to go from natural page scale to a subdivision count.
    //
    // We only ever bisect to create new tiles, which gives us the following percent per subdivision level:
    // 1.0, 0.5, 0.25, 0.125, ...
    //
    // From the bisection percent pattern, we can relate the two as follows:
    // percent = 1 / 2^zoomLevel
    //
    // Solve for zoom level:
    // 1 / percent = 2^zoomLevel
    // logBaseX(1 / percent) = zoomLevel
    final zoomLevel = _logBaseX(tileSet.subdivisionBase, layoutZoomLevel);
    // TODO: update this comment (and possibly the code) now that we support variable subdivision counts.
    // We only want to display a single tile when the user has not zoomed in. As soon as the user
    // zoom's into the page we want to go to the next level down and show 4 tiles.
    // By subtracting 0.5 the ceil will round-up to the whole number above so when we
    // drop to 0.9999r we drop a level.
    final tileLevel = (zoomLevel - 0.5).ceil().clamp(0, tileSet.levels);
    // final tileLevel = (zoomLevel + 1).ceil().clamp(0, tileSet.levels);

    ImageTileLogs.pagePainting.fine(
        "Layout zoom: $layoutZoomLevel, render zoom: $renderZoomLevel, zoom level: $zoomLevel, tile level: $tileLevel");

    return tileLevel;
  }

  @override
  double calculateTileScale({
    required Size viewportSize,
    required Size pageNaturalSize,
    required TileIndex tileIndex,
  }) {
    // Every tile size is based on the page size (an arbitrary choice we made).
    // We want every tile to be able to occupy a full viewport width before
    // becoming blurry. This means rendering a tile as wide as the viewport.
    // The scale to do this is the viewport width divided by the page width.
    final scaleNaturalPageToViewport = viewportSize.width / pageNaturalSize.width;

    if (tileIndex.level == 0) {
      // Make Level Zero tiles twice the size of other tiles. We do this because the
      // Level Zero tile zooms to a larger size than other tiles, and because we tend
      // to find that the Level Zero tile renders blurrier than other tiles for some
      // reason.
      //
      // We also force Level Zero zoom levels be an integer multiple of the natural page
      // size, because we find that this produces better results for Level Zero tiles.
      return (scaleNaturalPageToViewport * 2).ceil().toDouble();
    }

    return scaleNaturalPageToViewport;
  }
}

/// Returns the log, base X, for the given [value].
double _logBaseX(int base, double value) {
  return log(value) / log(base); // <- log(value) / log(base) implements log_base() because Dart doesn't have it.
}

class PageWithImageTileLayersElement extends LeafRenderObjectElement {
  PageWithImageTileLayersElement(super.widget);

  @override
  PageWithTileImages get widget => super.widget as PageWithTileImages;

  @override
  RenderPageWithImageTileLayers get renderObject => super.renderObject as RenderPageWithImageTileLayers;

  ViewportPageParentData? get pageParentData => _pageParentData;
  ViewportPageParentData? _pageParentData;

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio = 1.0;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _findAncestorPageParentData();
    _findDevicePixelRatio();
  }

  @override
  void unmount() {
    _pageParentData = null;
    super.unmount();
  }

  void _findAncestorPageParentData() {
    // If we are the object with the desired parent data, return our parent data.
    if (renderObject.parentData is ViewportPageParentData) {
      _pageParentData = renderObject.parentData as ViewportPageParentData;
      return;
    }

    // Our widget doesn't have the desired parent data. We must not be the root of the
    // page widget tree. Search ancestors until we find the parent data.
    ViewportPageParentData? parentData;
    visitAncestorElements((Element ancestor) {
      final renderObject = ancestor.renderObject;
      if (renderObject != null && renderObject.parentData is ViewportPageParentData) {
        parentData = renderObject.parentData as ViewportPageParentData;
        return false;
      }
      return true;
    });
    assert(parentData != null);
    _pageParentData = parentData;
  }

  void _findDevicePixelRatio() {
    _devicePixelRatio = dependOnInheritedWidgetOfExactType<MediaQuery>()?.data.devicePixelRatio ?? 1.0;
  }
}

class RenderPageWithImageTileLayers extends RenderBox with ImageTileCacheListener {
  // TODO: optimize the cache extent and/or make it configurable
  static const horizontalCacheExtent = 2000.0;
  static const verticalCacheExtent = 3000.0;

  // static const horizontalCacheExtent = 0.0;
  // static const verticalCacheExtent = 0.0;

  RenderPageWithImageTileLayers({
    required PageWithImageTileLayersElement element,
    required TileImageCache tileCache,
    required int pageIndex,
    required Size naturalSize,
    required ImageTileStrategy tileLevelStrategy,
    levelZeroTileFilterQuality = FilterQuality.low,
    insertNewLayer = false,
    preventTileLoading = false,
    showTileBounds = false,
  })  : _element = element,
        _tileCache = tileCache,
        _pageIndex = pageIndex,
        _naturalSize = naturalSize,
        _tileStrategy = tileLevelStrategy,
        _levelZeroTileFilterQuality = levelZeroTileFilterQuality,
        _insertNewLayer = insertNewLayer,
        _preventTileLoading = preventTileLoading,
        _showTileBounds = showTileBounds {
    _tileCache.addListener(this);
  }

  @override
  void dispose() {
    _tileCache.removeListener(this);
    _element = null;
    super.dispose();
  }

  PageWithImageTileLayersElement? _element;

  TileImageCache _tileCache;
  set tileCache(TileImageCache newValue) {
    if (newValue == _tileCache) {
      return;
    }

    _tileCache.removeListener(this);
    _tileCache = newValue;
    _tileCache.addListener(this);

    markNeedsLayout();
  }

  int _pageIndex;
  set pageIndex(int newValue) {
    if (newValue == _pageIndex) {
      return;
    }

    _pageIndex = newValue;

    markNeedsLayout();
  }

  Size _naturalSize;
  set naturalSize(Size newValue) {
    if (newValue == _naturalSize) {
      return;
    }

    _naturalSize = newValue;
    markNeedsLayout();
  }

  ImageTileStrategy _tileStrategy;
  set tileStrategy(ImageTileStrategy newValue) {
    if (newValue == _tileStrategy) {
      return;
    }

    _tileStrategy = newValue;
    markNeedsPaint();
  }

  bool _insertNewLayer;

  /// Whether to paint this page's tiles in the parent [Layer], or insert our own child
  /// [Layer], and paint the tiles in that [Layer].
  ///
  /// It's unclear whether inserting a layer, or not inserting a layer, has any typical
  /// performance impact. It's possible that positioning tiles within our own [OffsetLayer],
  /// and then retaining that [OffsetLayer], might reduce churn in the layer tree. It's also
  /// possible that it increases churn, depending on the exact situation. We leave this
  /// toggle for developers to experiment with each approach.
  set insertNewLayer(bool newValue) {
    if (newValue == _insertNewLayer) {
      return;
    }

    _insertNewLayer = newValue;
    markNeedsPaint();
  }

  FilterQuality _levelZeroTileFilterQuality;
  set levelZeroTileFilterQuality(FilterQuality newValue) {
    if (newValue == _levelZeroTileFilterQuality) {
      return;
    }

    _levelZeroTileFilterQuality = newValue;
    markNeedsPaint();
  }

  bool _preventTileLoading;
  set preventTileLoading(bool newValue) {
    _preventTileLoading = newValue;
  }

  bool _showTileBounds;
  set showTileBounds(bool newValue) {
    if (newValue == _showTileBounds) {
      return;
    }

    _showTileBounds = newValue;
    markNeedsPaint();
  }

  Size _viewportSize = Size.zero;

  int? _visitedTileCount;

  // The current level of page bisection, based on page zoom level.
  int _tileLevel = 0;

  // The bitmap rendering scale that applies to every tile, e.g., scaled up to fit the
  // viewport, and screen DPI applied.
  double _levelZeroTileScale = 1.0;

  // Tiles that sit at teh current zoom level, and are visible in the viewport.
  final _visibleTiles = <PageTileIndex, TileSubdivision>{};

  // Tiles that sit at the current zoom level, that aren't visible, but are near the
  // visible region.
  final _tilesInPrimaryCacheRegion = <PageTileIndex, TileSubdivision>{};

  // Tiles that sit in the visible region, but they're at a higher or lower zoom level
  // than the current zoom level.
  final _visibleNonPrimaryTiles = <PageTileIndex, TileSubdivision>{};

  @override
  void attach(PipelineOwner owner) {
    ImageTileLogs.page.info("attach()'ing TilePage render object to pipeline");
    super.attach(owner);
  }

  @override
  void detach() {
    ImageTileLogs.page.info("detach()'ing TilePage render object from pipeline");

    // We're being detached. We no longer need our tiles. Cancel outstanding requests. Mark
    // down the priority of the tiles that are already painted.
    _tileCache.cancelRequests(_tileCache.getTilesToPendingRequestsForPage(_pageIndex).values.toSet());
    for (final cachedTile in _tileCache.getCachedTilesForPage(_pageIndex)) {
      // We mark down the priority, instead of explicitly releasing the tile, because the
      // user might quickly pan back-and-forth across pages, in which case we'd like to
      // still have these tiles around, so long as we don't need to make additional space
      // in the cache for other tiles.
      cachedTile.priority = 0;
    }

    // IMPORTANT: we must detach ourselves before detaching our children.
    // This is a Flutter framework requirement.
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => true; // `true` based on API docs for TextureLayer

  @override
  void onTilePainted(ImageTileRequest request, CachedImage cachedTile) {
    if (request.pageTileIndex.pageIndex != _pageIndex) {
      return;
    }

    if (!_visibleTiles.containsKey(cachedTile.pageTileIndex)) {
      return;
    }

    // The newly painted tile is in the visible area. Repaint with the tile.
    ImageTileLogs.pagePainting.fine("Received a painted tile for page $_pageIndex: $cachedTile");
    markNeedsPaint();
  }

  @override
  void onTileEvicted(CachedImage cachedTile) {
    if (cachedTile.pageTileIndex.pageIndex != _pageIndex) {
      return;
    }
    if (!_visibleTiles.containsKey(cachedTile.pageTileIndex)) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // Don't mark needs paint during layout or paint phases.
      return;
    }

    // Re-paint without the tile that was evicted, so that we don't accidentally
    // show some other tile that gets painted to that same texture.
    markNeedsPaint();
  }

  @override
  void performLayout() {
    ImageTileLogs.pageLayout.info("---- Laying out tile page $_pageIndex ----");
    assert(constraints.hasBoundedWidth);

    // Make this render object fit the available space, while preserving the page's
    // aspect ratio.
    final desiredSize = Size(constraints.maxWidth, constraints.maxWidth / _naturalSize.aspectRatio);
    // Note: the desiredSize above should be exactly correct, but when I ran it, Flutter
    // complained that it didn't meet the constraints. I think this may be a floating point
    // precision issue. We get around it by explicitly constraining the size that we calculated.
    size = constraints.constrainSizeAndAttemptToPreserveAspectRatio(desiredSize);

    _tileLevel = _tileStrategy.calculateTileLevel(
      viewportSize: _element!.pageParentData!.viewportSize,
      pageLayoutSize: size,
      pageNaturalSize: _naturalSize,
    );
    _calculateLevelZeroTileScale();
    _findVisibleAndCacheRegionTiles();

    // Find all the tiles we need, and assign them priorities. We do this during layout
    // and during paint because sometimes a page will only run layout, or a page will
    // only run paint.
    // TODO: override markNeedsLayout and markNeedsPaint to track when this info becomes
    //       invalid, and then only run it again in paint() if we need to.
    if (!_preventTileLoading) {
      final pageParentData = _element!.pageParentData!;
      final viewportPercentRect =
          _calculateViewportRectInPagePercents(pageParentData.offset, pageParentData.viewportSize);

      _updateTilePriorities(viewportPercentRect);
      _requestNewTilesAndCancelOldRequests(viewportPercentRect);
    }
  }

  void _calculateLevelZeroTileScale() {
    _viewportSize = _element!.pageParentData!.viewportSize;
    final pageSizeToViewportSizeMultiplier = _viewportSize.width / _naturalSize.width;
    final devicePixelRatio = _element!.devicePixelRatio;
    _levelZeroTileScale = pageSizeToViewportSizeMultiplier * // make tile as large as the viewport
        devicePixelRatio; // render at the screen's density
    ImageTileLogs.pagePainting
        .finest("Tile scale: $pageSizeToViewportSizeMultiplier * $devicePixelRatio * 2 => $_levelZeroTileScale");
  }

  @override
  bool hitTestSelf(Offset position) {
    return size.contains(position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    ImageTileLogs.pagePainting.info("---- Painting page $_pageIndex ----");

    _findVisibleAndCacheRegionTiles();
    ImageTileLogs.pagePainting.fine("Page $_pageIndex has ${_visibleTiles.length} visible tiles");

    final pageParentData = _element!.pageParentData!;
    if (!_preventTileLoading) {
      final viewportPercentRect =
          _calculateViewportRectInPagePercents(pageParentData.offset, pageParentData.viewportSize);
      ImageTileLogs.pagePainting.finer("Viewport percent rect: $viewportPercentRect");

      _updateTilePriorities(viewportPercentRect);
      _requestNewTilesAndCancelOldRequests(viewportPercentRect);
    }

    // Paint the background of the page.
    context.canvas.drawRect(offset & size, Paint()..color = const Color(0xFFFFFFFF));

    // Paint the visible tiles.
    ImageTileLogs.pagePainting
        .info("Displaying painted tile textures (${_visibleTiles.length}): ${_visibleTiles.values}");

    if (_insertNewLayer) {
      _paintTilesInParentLayer(context, offset);
    } else {
      _paintTilesInNewLayer(context, offset);
    }
  }

  /// Finds all tiles relevant to displaying and caching.
  void _findVisibleAndCacheRegionTiles() {
    _visibleTiles.clear();
    _tilesInPrimaryCacheRegion.clear();
    _visibleNonPrimaryTiles.clear();

    ImageTileLogs.pagePainting.fine("Visiting tiles, focused at level $_tileLevel");
    _visitedTileCount = 0;
    _visitVisibleAndCachedTiles(
      tileSet: _tileStrategy.tileSet,
      tileLevel: _tileLevel,
      visitor: (TileSubdivision logicalTile, bool isVisible) {
        ImageTileLogs.pagePainting.fine(
            "Visiting tile: ${logicalTile.index} - is visible: $isVisible - is current level? ${logicalTile.index.level == _tileLevel}");
        _visitedTileCount = _visitedTileCount! + 1;

        final pageTileIndex = PageTileIndex(_pageIndex, logicalTile.index);

        if (logicalTile.index.level != _tileLevel) {
          if (isVisible) {
            // This tile is in the viewport, but its at a higher or lower zoom level.
            _visibleNonPrimaryTiles[pageTileIndex] = logicalTile;
          }
          return;
        }

        if (isVisible) {
          // This tile is visible at the current zoom level.
          _visibleTiles[pageTileIndex] = logicalTile;
        } else {
          // This tile isn't visible, but it's at the current zoom level, and
          // it's nearby.
          _tilesInPrimaryCacheRegion[pageTileIndex] = logicalTile;
        }
      },
    );
    ImageTileLogs.pagePainting.fine("Visited $_visitedTileCount tiles at level $_tileLevel");
  }

  /// Updates the priority of every existing tile paint request and every cached
  /// tile to reflect where that tile sits relative to the viewport and zoom level.
  void _updateTilePriorities(Rect viewportPercentRect) {
    ImageTileLogs.pagePainting.fine("Updating priorities");

    ImageTileLogs.pagePainting.finer("Updating tile request priorities");
    for (final request in _tileCache.pendingRequests) {
      if (request.pageTileIndex.pageIndex != _pageIndex) {
        ImageTileLogs.pagePainting.finer(" - (OTHER PAGE) - $request");
        continue;
      }

      request.priority = _calculatePriorityForTile(request.pageTileIndex, viewportPercentRect);
      ImageTileLogs.pagePainting.finer(" - $request");
    }

    ImageTileLogs.pagePainting.finer("Updating cached tile priorities (${_tileCache.cachedTileCount} tiles)");
    for (final cachedTile in _tileCache.cachedTiles) {
      if (cachedTile.pageTileIndex.pageIndex != _pageIndex) {
        ImageTileLogs.pagePainting.finer(" - (OTHER PAGE) - $cachedTile");
        continue;
      }

      cachedTile.priority = _calculatePriorityForTile(cachedTile.pageTileIndex, viewportPercentRect);
      ImageTileLogs.pagePainting.finer(" - $cachedTile");
    }
  }

  double _calculatePriorityForTile(PageTileIndex tileIndex, Rect viewportPercentRect) {
    TileSubdivision? logicalTile;
    late double basePriority;

    if (tileIndex.tileIndex.level == 0) {
      basePriority = _levelZeroTilePriority;
      logicalTile =
          (_visibleTiles[tileIndex] ?? _tilesInPrimaryCacheRegion[tileIndex] ?? _visibleNonPrimaryTiles[tileIndex]);
    } else if (_visibleTiles.keys.contains(tileIndex)) {
      basePriority = _visiblePrimaryTilePriority;
      logicalTile = _visibleTiles[tileIndex];
    } else if (_tilesInPrimaryCacheRegion.keys.contains(tileIndex)) {
      basePriority = _cachedPrimaryTilePriority;
      logicalTile = _tilesInPrimaryCacheRegion[tileIndex];
    } else if (_visibleNonPrimaryTiles.keys.contains(tileIndex)) {
      basePriority = _visibleNonPrimaryTilePriority;
      logicalTile = _visibleNonPrimaryTiles[tileIndex];
    } else {
      basePriority = _unneededPriority;
    }

    if (logicalTile != null) {
      // Adjust the priority based on how near/far the tile is from the viewport.
      final percentDistanceFromViewportToTile =
          (viewportPercentRect.center - logicalTile.index.pageRegion.center).distance.clamp(0.0, 1.0);
      return basePriority + (basePriority * (1.0 - percentDistanceFromViewportToTile));
    } else {
      return basePriority;
    }
  }

  /// Inspects every primary visible, cache region, and non-primary visible tile and
  /// submits a new paint request for any such tile that has yet to be requested or
  /// painted.
  void _requestNewTilesAndCancelOldRequests(Rect viewportPercentRect) {
    final tileRequests = <ImageTileRequest>{};
    final requestsToCancel = _tileCache.getTilesToPendingRequestsForPage(_pageIndex);

    // Always request level zero tile.
    requestsToCancel.removeWhere((key, value) => key.tileIndex.level == 0);
    final levelZeroTileIndex = TileIndex(
      row: 0,
      col: 0,
      level: 0,
      subdivisionBase: _tileStrategy.tileSet.subdivisionBase,
    );
    tileRequests.add(
      ImageTileRequest(
        pageTileIndex: PageTileIndex(
          _pageIndex,
          levelZeroTileIndex,
        ),
        scale: _tileStrategy.calculateTileScale(
          viewportSize: _viewportSize,
          pageNaturalSize: _naturalSize,
          tileIndex: levelZeroTileIndex,
        ),
        priority: _levelZeroTilePriority,
      ),
    );

    // Request primary visible tiles.
    for (final pageTileIndex in _visibleTiles.keys) {
      requestsToCancel.remove(pageTileIndex);
      if (_tileCache.hasPendingRequestForTile(pageTileIndex)) {
        continue;
      }
      if (_tileCache.hasCachedTile(pageTileIndex)) {
        continue;
      }

      tileRequests.add(
        ImageTileRequest(
          pageTileIndex: pageTileIndex,
          scale: _tileStrategy.calculateTileScale(
            viewportSize: _viewportSize,
            pageNaturalSize: _naturalSize,
            tileIndex: pageTileIndex.tileIndex,
          ),
          priority: _calculatePriorityForTile(pageTileIndex, viewportPercentRect),
        ),
      );
    }

    // Request non-visible primary tiles.
    for (final pageTileIndex in _tilesInPrimaryCacheRegion.keys) {
      requestsToCancel.remove(pageTileIndex);
      if (_tileCache.hasPendingRequestForTile(pageTileIndex)) {
        continue;
      }
      if (_tileCache.hasCachedTile(pageTileIndex)) {
        continue;
      }

      tileRequests.add(
        ImageTileRequest(
          pageTileIndex: pageTileIndex,
          scale: _tileStrategy.calculateTileScale(
            viewportSize: _viewportSize,
            pageNaturalSize: _naturalSize,
            tileIndex: pageTileIndex.tileIndex,
          ),
          priority: _calculatePriorityForTile(pageTileIndex, viewportPercentRect),
        ),
      );
    }

    // Request non-primary visible tiles.
    for (final pageTileIndex in _visibleNonPrimaryTiles.keys) {
      requestsToCancel.remove(pageTileIndex);
      if (_tileCache.hasPendingRequestForTile(pageTileIndex)) {
        continue;
      }
      if (_tileCache.hasCachedTile(pageTileIndex)) {
        continue;
      }

      tileRequests.add(
        ImageTileRequest(
          pageTileIndex: pageTileIndex,
          scale: _tileStrategy.calculateTileScale(
            viewportSize: _viewportSize,
            pageNaturalSize: _naturalSize,
            tileIndex: pageTileIndex.tileIndex,
          ),
          priority: _calculatePriorityForTile(pageTileIndex, viewportPercentRect),
        ),
      );
    }

    // Request new tiles.
    if (tileRequests.isNotEmpty) {
      _tileCache.requestTiles(tileRequests);
    }

    // Cancel requests that are no longer relevant.
    if (requestsToCancel.isNotEmpty) {
      _tileCache.cancelRequests(requestsToCancel.values.toSet());
    }

    // Now that we've sent new requests, and cancelled old requests, re-evaluate
    // the priorities of all pending requests.
    if (tileRequests.isNotEmpty || requestsToCancel.isNotEmpty) {
      ImageTileLogs.pagePainting
          .fine("Telling cache to re-evaluate priorities - page $_pageIndex - cache: ${_tileCache.hashCode}");
      _tileCache.reEvaluatePriorities();
    }
  }

  void _paintTilesInParentLayer(PaintingContext context, Offset offset) {
    if (_offsetLayer != null) {
      _offsetLayer!.dispose();
      _offsetLayer = null;
    }

    _paintTiles(context, offset);
  }

  TransformLayer? _offsetLayer;
  void _paintTilesInNewLayer(PaintingContext context, Offset offset) {
    _offsetLayer = context.pushTransform(
      true, // needs compositing,
      offset,
      Matrix4.identity(),
      (pageInnerContext, offset) {
        _paintTiles(context, offset);
      },
      oldLayer: null,
    );
  }

  void _paintTiles(PaintingContext context, Offset offset) {
    final tilesToPaint = List.from(_visibleNonPrimaryTiles.values)..addAll(_visibleTiles.values);
    for (final logicalTile in tilesToPaint) {
      final regionRect = logicalTile.index.pageRegion;
      final pixelRectInPage = Rect.fromLTWH(
        size.width * regionRect.left,
        size.height * regionRect.top,
        size.width * regionRect.width,
        size.height * regionRect.height,
      ).translate(offset.dx, offset.dy);

      final pageTileIndex = PageTileIndex(_pageIndex, logicalTile.index);
      final cachedTile = _tileCache.getCachedTile(pageTileIndex);
      final image = cachedTile?.image;
      if (image != null) {
        ImageTileLogs.pagePainting.fine("Display texture on screen for tile $pageTileIndex, texture: $image");

        final imageOffset = offset + pixelRectInPage.topLeft;
        final scale = pixelRectInPage.width / image.width;
        context.canvas
          ..save()
          ..translate(imageOffset.dx, imageOffset.dy)
          ..scale(scale, scale)
          ..drawImage(image, Offset.zero, Paint())
          ..restore();
      } else {
        ImageTileLogs.pagePainting.fine("Waiting on texture for tile $pageTileIndex");
      }

      // Paint debug rectangle.
      if (_showTileBounds) {
        context.canvas.drawRect(
          pixelRectInPage,
          Paint()
            ..color = Colors.blue
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5,
        );
      }
    }
  }

  void _visitVisibleAndCachedTiles({
    required SubdividingTileSet tileSet,
    required int tileLevel,
    required void Function(TileSubdivision tile, bool isVisibleOnScreen) visitor,
  }) {
    final pageParentData = _element!.pageParentData!;
    // print("Visiting visible tiles at level $tileLevel, page parent data offset: ${pageParentData.offset}");

    final viewportSize = pageParentData.viewportSize;

    // Add a cache extent in all four directions so that we load some tiles outside
    // the viewport bounds for a less jarring user experience when panning.
    final localViewportCacheRect = Rect.fromLTRB(
      0 - horizontalCacheExtent,
      0 - verticalCacheExtent,
      viewportSize.width + horizontalCacheExtent,
      viewportSize.height + verticalCacheExtent,
    );

    final localViewportVisibleRect = Rect.fromLTRB(
      0,
      0,
      viewportSize.width,
      viewportSize.height,
    );

    // Calculate the cache region as a rectangle within, or around, this page, measured
    // as a percent (instead of pixels). We use this to cull the tile visitor.
    final cacheRegionPercentRect = _calculateCacheRectInPagePercents(pageParentData.offset, viewportSize);

    // Visit the layer below the desired layer, and then the desired layer,
    // so that we layout and paint the lower res tiles beneath the higher
    // res tiles (to avoid loading flashes).
    // TODO: make this visiting smarter so that we make absolutely sure to paint
    //       all lower layers needed to avoid white flashes, and also that we never
    //       paint a tile that's completely covered by others.
    tileSet.visitBreadthFirst(
      (tile) {
        final tileRegionInPage = tile.index.pageRegion;
        final tileRectInPage = Rect.fromLTWH(
          size.width * tileRegionInPage.left,
          size.height * tileRegionInPage.top,
          size.width * tileRegionInPage.width,
          size.height * tileRegionInPage.height,
        );

        final tileViewportOrigin = pageParentData.offset + tileRectInPage.topLeft;
        final tileViewportRect = tileViewportOrigin & tileRectInPage.size;

        if (!localViewportCacheRect.overlaps(tileViewportRect)) {
          // This tile isn't in the visible region, or in the cache region.
          return;
        }

        final isVisible = localViewportVisibleRect.overlaps(tileViewportRect);

        visitor(tile, isVisible);
      },
      minLevel: 0,
      maxLevel: tileLevel,
      cullingViewport: cacheRegionPercentRect,
    );
  }

  Rect _calculateViewportRectInPagePercents(Offset pageOffsetInViewport, Size viewportSize) {
    final viewportPercentWidth = viewportSize.width / size.width;
    final viewportPercentHeight = viewportSize.height / size.height;
    final viewportPercentOffset = Offset(
      -pageOffsetInViewport.dx / size.width,
      -pageOffsetInViewport.dy / size.height,
    );
    return viewportPercentOffset & Size(viewportPercentWidth, viewportPercentHeight);
  }

  Rect _calculateCacheRectInPagePercents(Offset pageOffsetInViewport, Size viewportSize) {
    final cacheRegionPercentWidth = (viewportSize.width + (2 * horizontalCacheExtent)) / size.width;
    final cacheRegionPercentHeight = (viewportSize.height + (2 * verticalCacheExtent)) / size.height;
    final cacheRegionPixelOffset = const Offset(-horizontalCacheExtent, -verticalCacheExtent) - pageOffsetInViewport;
    final cacheRegionPercentOffset = Offset(
      cacheRegionPixelOffset.dx / size.width,
      cacheRegionPixelOffset.dy / size.height,
    );
    return cacheRegionPercentOffset & Size(cacheRegionPercentWidth, cacheRegionPercentHeight);
  }
}

const _levelZeroTilePriority = 10000.0;
const _visiblePrimaryTilePriority = 1000.0;
const _visibleNonPrimaryTilePriority = 100.0;
const _cachedPrimaryTilePriority = 10.0;
const _unneededPriority = 0.0;
