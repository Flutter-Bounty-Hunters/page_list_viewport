import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'logging.dart';
import 'tiles.dart';

class TileImageCache {
  TileImageCache({
    required int maxTileCount,
    required ImagePainter tilePainter,
  })  : _maxTileCount = maxTileCount,
        _tilePainter = tilePainter;

  bool _isDisposed = false;

  void dispose() {
    ImageTileLogs.tilesCache.info("Disposing of a TileCache with ${_cachedTiles.length} cached tiles.");

    _isDisposed = true;

    _listeners.clear();

    for (final request in _requests.values) {
      request.removeListener(_onRequestPriorityChange);
    }
    _requests.clear();

    for (final cachedTile in _cachedTiles.entries) {
      cachedTile.value.removeListener(_onCachedTilePriorityChange);
    }
    ImageTileLogs.tilesCache
        .fine("Instructing platform to release textures: ${_cachedTiles.values.map((tile) => tile.image)}");
    _tilePainter.releaseTiles(_cachedTiles.values);
    _cachedTiles.clear();
  }

  final int _maxTileCount;

  final ImagePainter _tilePainter;

  bool hasPendingRequestForTile(PageTileIndex pageTileIndex) => _requests.containsKey(pageTileIndex);

  int get pendingRequestCount => _requests.length;
  int pendingRequestCountForPage(int pageIndex) =>
      _requests.values.where((request) => request.pageTileIndex.pageIndex == pageIndex).length;

  Iterable<ImageTileRequest> get pendingRequests => _requests.values;
  ImageTileRequest? getPendingRequest(PageTileIndex pageTileIndex) => _requests[pageTileIndex];

  Map<PageTileIndex, ImageTileRequest> get tilesToPendingRequests => Map.from(_requests);
  Map<PageTileIndex, ImageTileRequest> getTilesToPendingRequestsForPage(int pageIndex) =>
      Map.fromEntries(_requests.entries.where((entry) => entry.key.pageIndex == pageIndex));

  final _requests = <PageTileIndex, ImageTileRequest>{};

  ImageTileRequest? _inFlightRequest;
  bool get _isPainting => _inFlightRequest != null;

  bool hasCachedTile(PageTileIndex tileIndex) => _cachedTiles.containsKey(tileIndex);

  bool get _isCacheFull => _cachedTiles.length + (_isPainting ? 1 : 0) >= _maxTileCount;

  int get cachedTileCount => _cachedTiles.length;
  int cachedTileCountForPage(int pageIndex) =>
      _cachedTiles.values.where((cachedTile) => cachedTile.pageTileIndex.pageIndex == pageIndex).length;

  Iterable<CachedImage> get cachedTiles => _cachedTiles.values;
  CachedImage? getCachedTile(PageTileIndex tileIndex) => _cachedTiles[tileIndex];
  Iterable<CachedImage> getCachedTilesForPage(int pageIndex) =>
      _cachedTiles.values.where((tile) => tile.pageTileIndex.pageIndex == pageIndex);

  final _cachedTiles = <PageTileIndex, CachedImage>{};

  final _listeners = <ImageTileCacheListener>{};

  void addListener(ImageTileCacheListener listener) {
    _listeners.add(listener);
  }

  void removeListener(ImageTileCacheListener listener) {
    _listeners.remove(listener);
  }

  void requestTiles(Set<ImageTileRequest> requests) {
    if (_isDisposed) {
      throw Exception("Requested a tile from a TileCache that's already disposed - $this");
    }

    ImageTileLogs.tilePipeline.fine("Adding tile requests: $requests");
    bool didEnqueueAtLeastOneRequest = false;
    for (final request in requests) {
      didEnqueueAtLeastOneRequest |= _doRequestTile(request);
    }
    if (!didEnqueueAtLeastOneRequest) {
      return;
    }

    for (final listener in _listeners) {
      listener.onRequestsAdded(requests);
    }

    _startPainting();
  }

  void requestTile(ImageTileRequest request) {
    if (_isDisposed) {
      throw Exception("Requested a tile from a TileCache that's already disposed - $this");
    }

    final didEnqueue = _doRequestTile(request);
    if (!didEnqueue) {
      return;
    }

    for (final listener in _listeners) {
      listener.onRequestsAdded({request});
    }

    _startPainting();
  }

  /// Returns `true` if the request was a new request without a tile, and was therefore
  /// queue'd for processing.
  bool _doRequestTile(ImageTileRequest request) {
    assert(!_requests.containsKey(request.pageTileIndex) || _requests[request.pageTileIndex] == request,
        "Tried to submit a new request for a tile that's already requested: $request");
    if (request == _inFlightRequest) {
      // We're currently painting this tile. Ignore the request.
      return false;
    }

    if (_requests.containsKey(request.pageTileIndex)) {
      // This is a request for a tile that's already been requested. Update the
      // request's priority and return.
      ImageTileLogs.tilePipeline.fine(
          "Trying to request tile that's already requested. Changing priority from ${_requests[request.pageTileIndex]!.priority}, to ${request.priority}. Request: $request");
      _requests[request.pageTileIndex]!.priority = request.priority;
      return false;
    }
    if (_cachedTiles.containsKey(request.pageTileIndex)) {
      // This request already has a corresponding tile. Ignore it.
      return false;
    }

    ImageTileLogs.tilePipeline.fine("Adding tile request: $request");
    request.addListener(_onRequestPriorityChange);
    _requests[request.pageTileIndex] = request;

    return true;
  }

  void cancelRequests(Set<ImageTileRequest> requests) {
    for (final request in requests) {
      cancelRequest(request);
    }

    for (final listener in _listeners) {
      listener.onRequestsCancelled(requests);
    }
  }

  void cancelRequest(ImageTileRequest request) {
    assert(_requests.containsKey(request.pageTileIndex),
        "Tried to cancel a tile request for a tile that has no associated request: $request");
    assert(_requests[request.pageTileIndex] == request,
        "Tried to cancel a tile request, but the given request doesn't match the pending request for that tile. Pending request: ${_requests[request.pageTileIndex]}, Request to cancel: $request");

    request.removeListener(_onRequestPriorityChange);
    _requests.remove(request.pageTileIndex);

    for (final listener in _listeners) {
      listener.onRequestsCancelled({request});
    }
  }

  void reEvaluatePriorities() {
    _startPainting();
  }

  void _onRequestPriorityChange() {}

  void _onCachedTilePriorityChange() {}

  Future<void> _startPainting() async {
    ImageTileLogs.tilePipeline.fine("(Maybe) painting a new tile");
    if (_requests.isEmpty) {
      ImageTileLogs.tilePipeline.fine("No pending tile requests. Not painting anything.");
      return;
    }

    if (_isPainting) {
      ImageTileLogs.tilePipeline.fine("Already painting a tile. Fizzling. Painting - $_inFlightRequest");
      return;
    }

    if (_isCacheFull) {
      if (!_shouldEvictCachedTileForNewRequest()) {
        // The cache is full and all requests are lower priority.
        ImageTileLogs.tilePipeline.fine("Cache is full without any higher priority requests. Fizzling.");
        return;
      }

      ImageTileLogs.tilePipeline.fine("Evicting a lower priority tile before starting new tile request.");
      _evictCachedTile();
    }

    // Mark the request that we're processing.
    _inFlightRequest = _selectNextRequest();
    ImageTileLogs.tilePipeline.fine("Selected tile request to paint: $_inFlightRequest");

    for (final listener in _listeners) {
      listener.onTilePaintStart(_inFlightRequest!);
    }

    // Paint the tile.
    ImageTileLogs.tilePipeline.fine("Painting the tile ($_inFlightRequest) (LONG ASYNC TASK)");
    final cachedTile = await _tilePainter.paintTile(_inFlightRequest!);
    ImageTileLogs.tilePipeline.fine("Done painting tile ($cachedTile)");
    if (_isDisposed) {
      return;
    }

    // Add the newly painted tile to the cache.
    ImageTileLogs.tilePipeline.fine("Adding newly painted tile to cache: $cachedTile");
    cachedTile.addListener(_onCachedTilePriorityChange);
    _cachedTiles[_inFlightRequest!.pageTileIndex] = cachedTile;

    // Notify listeners that we painted the tile.
    ImageTileLogs.tilePipeline.fine("Notifying listeners that we painted a tile ($cachedTile)");
    for (final listener in _listeners) {
      listener.onTilePainted(_inFlightRequest!, cachedTile);
    }

    // Clear out the request that we just completed.
    _inFlightRequest = null;

    // Paint the next request in the queue.
    ImageTileLogs.tilePipeline.fine("Restarting the paint process for the next request.");
    _startPainting();
  }

  ImageTileRequest _selectNextRequest() {
    if (_requests.isEmpty) {
      throw Exception("Tried to select a TileRequest but the request queue is empty");
    }

    MapEntry<PageTileIndex, ImageTileRequest>? nextRequest;
    for (final requestEntry in _requests.entries) {
      if (nextRequest == null || requestEntry.value.priority > nextRequest.value.priority) {
        nextRequest = requestEntry;
      }
    }

    _requests.remove(nextRequest!.key);
    return nextRequest.value;
  }

  bool _shouldEvictCachedTileForNewRequest() {
    if (_requests.isEmpty || _cachedTiles.isEmpty) {
      return false;
    }

    final highestRequestPriority = _requests.values.fold(
      double.negativeInfinity,
      (previousValue, element) => max(element.priority.toDouble(), previousValue),
    );
    final lowestCachedTilePriority = _cachedTiles.values.fold(
      double.infinity,
      (previousValue, element) => min(element.priority.toDouble(), previousValue),
    );

    // We should evict a tile if the most important request has a higher
    // priority than the least important cached tile.
    return highestRequestPriority > lowestCachedTilePriority;
  }

  void _evictCachedTile() {
    if (_cachedTiles.isEmpty) {
      throw Exception("Tried to evict a cached tile from an empty cache");
    }

    MapEntry<PageTileIndex, CachedImage>? tileToEvict;
    for (final entry in _cachedTiles.entries) {
      if (tileToEvict == null || entry.value.priority < tileToEvict.value.priority) {
        tileToEvict = entry;
      }
    }

    ImageTileLogs.tilePipeline.fine("Evicting ${tileToEvict!.value}");
    _cachedTiles.remove(tileToEvict.key);
    tileToEvict.value.removeListener(_onCachedTilePriorityChange);

    // Notify listeners that we evicted this tile.
    for (final listener in _listeners) {
      listener.onTileEvicted(tileToEvict.value);
    }

    // Release the backing texture.
    _tilePainter.releaseTile(tileToEvict.value);
  }

  void evictCachedTilesOnMemoryPressure() {
    var tileCountToEvict = _cachedTiles.length ~/ 2;
    while (tileCountToEvict > 0) {
      _evictCachedTile();
      tileCountToEvict--;
    }
  }
}

abstract class ImagePainter {
  Future<CachedImage> paintTile(ImageTileRequest request);

  void releaseTiles(Iterable<CachedImage> cachedTiles);

  void releaseTile(CachedImage cachedTile);
}

abstract class ImageTileCacheListener {
  void onRequestsAdded(Set<ImageTileRequest> requests) {}

  void onRequestsCancelled(Set<ImageTileRequest> requests) {}

  void onTilePaintStart(ImageTileRequest request) {}

  void onTilePainted(ImageTileRequest request, CachedImage cachedTile) {}

  void onTileEvicted(CachedImage cachedTile) {}
}

class ImageTileRequest with ChangeNotifier {
  ImageTileRequest({
    required this.pageTileIndex,
    required this.scale,
    required double priority,
  }) : _priority = priority;

  final PageTileIndex pageTileIndex;
  final double scale;

  double get priority => _priority;
  double _priority;
  set priority(double newPriority) {
    if (newPriority == priority) {
      return;
    }

    _priority = newPriority;
    notifyListeners();
  }

  @override
  String toString() =>
      "[TileRequest] - pageIndex: ${pageTileIndex.pageIndex}, tileIndex: ${pageTileIndex.tileIndex}, priority: $priority, scale: $scale";

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageTileRequest &&
          runtimeType == other.runtimeType &&
          pageTileIndex == other.pageTileIndex &&
          scale == other.scale;

  @override
  int get hashCode => pageTileIndex.hashCode ^ scale.hashCode;
}

class CachedImage with ChangeNotifier {
  CachedImage({
    required this.pageTileIndex,
    required this.image,
    required double priority,
    required this.scale,
  }) : _priority = priority;

  final PageTileIndex pageTileIndex;

  final ui.Image image;

  double get priority => _priority;
  double _priority;
  set priority(double newPriority) {
    if (newPriority == _priority) {
      return;
    }

    _priority = newPriority;
    notifyListeners();
  }

  final double scale;

  @override
  String toString() =>
      "[CachedTile] - page: ${pageTileIndex.pageIndex}, tile: ${pageTileIndex.tileIndex}, priority: $priority, image: $image";
}

class DocumentPageTileImagePainter implements ImagePainter {
  static final random = Random();

  DocumentPageTileImagePainter() {
    _prepLogId = random.nextInt(1000000);
  }

  /// ID used to distinguish log messages between different instances of
  /// [_TileTexturePainter]s because each pipeline runs multiple
  /// asynchronous behaviors.
  late final int _prepLogId;

  late ImageTileRequest _request;
  late ui.Image? _image;

  bool _isPaintingTexture = false;

  @override
  Future<CachedImage> paintTile(ImageTileRequest request) async {
    _request = request;

    // Decode the image.
    _prepareToPaintImage();
    _log("Painting image for tile ${_request.pageTileIndex} (LONG RUNNING ASYNC)");
    final renderRequest = PageRegionRenderRequest(
      pageIndex: request.pageTileIndex.pageIndex,
      scale: request.scale,
      pageRegion: request.pageTileIndex.tileIndex.pageRegion,
    );
    await _paintImage(renderRequest, request.pageTileIndex.tileIndex);
    _onImagePainted();

    // Finalize our accounting and return.
    _log("Done preparing texture ($_image) for tile (${request.pageTileIndex})");

    return CachedImage(
      pageTileIndex: request.pageTileIndex,
      image: _image!,
      priority: request.priority,
      scale: request.scale,
    );
  }

  void _prepareToPaintImage() {
    _log("Running pre-flight checks before painting image for tile ${_request.pageTileIndex}");

    if (_isPaintingTexture) {
      _throwException(
          "Tried to prepare to paint a tile that's already being painted. Tile: ${_request.pageTileIndex}, New texture: $_image");
    }

    _isPaintingTexture = true;
    _log("Done with pre-flight checks before painting tile ${_request.pageTileIndex}");
  }

  static const _imageAssets = [
    "assets/image-1.jpeg",
    "assets/image-2.jpeg",
    "assets/image-3.jpeg",
    "assets/image-4.jpeg",
    "assets/image-5.jpeg",
    "assets/image-6.jpeg",
    "assets/image-7.jpeg",
    "assets/image-8.jpeg",
    "assets/image-9.jpeg",
    "assets/image-10.jpeg",
    "assets/image-11.jpeg",
    "assets/image-12.jpeg",
    "assets/image-13.jpeg",
    "assets/image-14.jpeg",
    "assets/image-15.jpeg",
  ];
  Future<void> _paintImage(PageRegionRenderRequest request, TileIndex tileIndex) async {
    final imageCompleter = Completer<ui.Image>();
    final index = (tileIndex.col + tileIndex.row) % _imageAssets.length;
    final imageStream = ResizeImage(
      AssetImage(_imageAssets[index]),
      width: 400,
      policy: ResizeImagePolicy.fit,
    ).resolve(
      const ImageConfiguration(),
    );

    final listener = ImageStreamListener((ImageInfo imageInfo, bool synchronousCall) {
      imageCompleter.complete(imageInfo.image);
    });
    imageStream.addListener(listener);

    _image = await imageCompleter.future;
  }

  void _onImagePainted() {
    _log("Running post-flight checks after tile (${_request.pageTileIndex}) was painted to texture ($_image)");

    if (!_isPaintingTexture) {
      _throwException(
          "Tile ${_request.pageTileIndex} was marked as not being painted while it was being painted to texture $_image");
    }

    _log("Marking texture $_image as no longer being painted for tile ${_request.pageTileIndex}");
    _isPaintingTexture = false;

    _log("Done with post-flight checks for tile ${_request.pageTileIndex} and texture $_image");
  }

  @override
  void releaseTiles(Iterable<CachedImage> cachedTiles) {
    for (final tile in cachedTiles) {
      tile.image.dispose();
    }
  }

  @override
  void releaseTile(CachedImage cachedTile) {
    cachedTile.image.dispose();
  }

  void _log(String message) {
    ImageTileLogs.tilePipeline.finer("Prep ($_prepLogId) - $message");
  }

  void _throwException(String message) {
    throw Exception("Prep ($_prepLogId) - $message");
  }

  @override
  String toString() =>
      "[_TileTexturePreparationPipeline] - tile: ${_request.pageTileIndex}, texture: $_image (is painting: $_isPaintingTexture)";
}

class PageRegionRenderRequest {
  const PageRegionRenderRequest({
    required this.pageIndex,
    required this.scale,
    this.pageRegion = const Rect.fromLTWH(0, 0, 1, 1),
  });

  /// Index of the page to render, starting at zero.
  final int pageIndex;

  /// Scale of the rendered image compared to the natural size of the page.
  ///
  /// A value of `1.0` renders a page at natural resolution.
  final double scale;

  /// The region of the page that should be rendered, represented as a percentage.
  ///
  /// By default, the full page is rendered, which corresponds to a rectangle
  /// defined by (0.0,0.0) -> (1.0, 1.0).
  final Rect pageRegion;

  @override
  String toString() => "Page: $pageIndex, Scale: $scale, Region: $pageRegion";
}
