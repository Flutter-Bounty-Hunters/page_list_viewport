import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart';

import 'logging.dart';

/// A viewport that displays [pageCount] pages of content, arranged in a vertical
/// list, with a given [naturalPageSize].
///
/// Each page is built lazily, by calling [builder].
///
/// A [PageListViewportController] can translate and scale the pages in this
/// viewport. Upon first layout, this widget will set the [controller]'s scale
/// such that the pages fit the exact width of the available space.
///
/// After initial layout, the [controller] can be used to make the pages larger
/// than the available space, and pan the pages up/down/left/right. However, the
/// pages can never be scaled down smaller than the width of the available space,
/// and the pages can't be panned in a way that would leave a gap between the edge
/// of the page, and the edge of the viewport.
///
/// To control the [controller] with gestures, see [PageListViewportGestures].
class PageListViewport extends RenderObjectWidget {
  const PageListViewport({
    super.key,
    required this.controller,
    required this.pageCount,
    required this.naturalPageSize,
    this.pageLayoutCacheCount = 0,
    this.pagePaintCacheCount = 0,
    required this.builder,
    this.rebuildOnOrientationChange = false,
  }) : assert(pageLayoutCacheCount >= pagePaintCacheCount);

  /// Controller that pans and zooms the page content.
  final OrientationController controller;

  /// The number of pages displayed in this viewport.
  final int pageCount;

  /// The size of a single page, if no constraints were applied.
  final Size naturalPageSize;

  /// The number of pages above and below the viewport that should
  /// be laid out, even though they aren't visible.
  final int pageLayoutCacheCount;

  /// The number of pages above and below the viewport that should
  /// be painted, even though they aren't visible.
  final int pagePaintCacheCount;

  /// [PageBuilder], which lazily builds the widgets for each page in
  /// this viewport.
  final PageBuilder builder;

  /// Whether the pages in this viewport should rebuild every time the orientation
  /// changes.
  ///
  /// Orientation changes include panning (horizontal and vertical movement), and
  /// zooming (scale up/down). Orientation changes happen rapidly. When rebuilding
  /// on orientation change, the visible and cached pages will rebuild at 60 fps
  /// during the duration of the orientation change. You should only rebuild during
  /// orientation change if your page widgets alter their layout or painting based
  /// on relative position or scale.
  final bool rebuildOnOrientationChange;

  @override
  RenderObjectElement createElement() {
    PageListViewportLogs.pagesList.finest(() => "Creating PageListViewport element");
    return PageListViewportElement(this);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    PageListViewportLogs.pagesList.finest(() => "Creating PageListViewport render object");
    return RenderPageListViewport(
      element: context as PageListViewportElement,
      controller: controller,
      pageCount: pageCount,
      pageSize: naturalPageSize,
      pageLayoutCacheCount: pageLayoutCacheCount,
      pagePaintCacheCount: pagePaintCacheCount,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderPageListViewport renderObject) {
    PageListViewportLogs.pagesList.finest(() => "Updating PageListViewport render object");
    renderObject //
      ..pageCount = pageCount
      ..naturalPageSize = naturalPageSize
      ..pageLayoutCacheCount = pageLayoutCacheCount
      ..pagePaintCacheCount = pagePaintCacheCount
      ..controller = controller;
  }
}

typedef PageBuilder = Widget Function(BuildContext context, int pageIndex);

class PageListViewportController extends OrientationController {
  PageListViewportController.startAtPage({
    required TickerProvider vsync,
    required int pageIndex,
    double scale = 1.0,
    double minimumScale = 0.1,
    double maximumScale = double.infinity,
  })  : assert(pageIndex >= 0, "The initial page index must be >= 0"),
        _tickerProvider = vsync,
        _initialPageIndex = pageIndex,
        _origin = Offset.zero,
        _previousOrigin = Offset.zero,
        _velocityStopwatch = Stopwatch(),
        _scale = scale,
        previousScale = scale,
        _scaleVelocity = 0.0,
        _scaleVelocityStopwatch = Stopwatch(),
        _minimumScale = minimumScale,
        _maximumScale = maximumScale {
    initController(vsync);
  }

  PageListViewportController({
    required TickerProvider vsync,
    Offset origin = Offset.zero,
    double scale = 1.0,
    double minimumScale = 0.1,
    double maximumScale = double.infinity,
  })  : _tickerProvider = vsync,
        _origin = origin,
        _previousOrigin = origin,
        _velocityStopwatch = Stopwatch(),
        _scale = scale,
        previousScale = scale,
        _scaleVelocity = 0.0,
        _scaleVelocityStopwatch = Stopwatch(),
        _minimumScale = minimumScale,
        _maximumScale = maximumScale {
    initController(vsync);
  }

  @protected
  void initController(TickerProvider vsync) {
    _animationController = AnimationController(vsync: vsync) //
      ..addListener(_onOrientationAnimationChange)
      ..addStatusListener((status) {
        switch (status) {
          case AnimationStatus.dismissed:
          case AnimationStatus.completed:
            _onOrientationAnimationEnd();
            break;
          case AnimationStatus.forward:
          case AnimationStatus.reverse:
            break;
        }
      });

    _velocityStopwatch.start();
    _scaleVelocityStopwatch.start();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _velocityStopwatch.stop();
    _velocityResetTimer?.cancel();
    _scaleVelocityStopwatch.stop();
    super.dispose();
  }

  final TickerProvider _tickerProvider;

  late final AnimationController _animationController;
  Animation? _offsetAnimation;
  Animation? _scaleAnimation;

  /// The index of the page that this controller will jump to, when attached to its first
  /// viewport.
  ///
  /// This value is cleared after it's applied. This controller won't jump to this page,
  /// again.
  // TODO: should we have a way to set this so that the controller can be attached to new
  //       viewports?
  int? _initialPageIndex;

  /// The (x,y) offset of the top-left corner of the first page in
  /// the page list, measured in un-scaled pixels.
  @override
  Offset get origin => _origin;

  Offset _origin;
  Offset _previousOrigin; // used to calculate velocity

  @override
  set origin(Offset newOrigin) {
    if (newOrigin == _origin) {
      return;
    }

    // Stop any on-going orientation animation so that the origin stays at
    // the new offset.
    _animationController.stop();
    stopSimulation();

    _origin = newOrigin;
    notifyListeners();
  }

  /// The velocity of the translation of the viewport origin.
  Offset get velocity => _velocity;
  Offset _velocity = Offset.zero;
  final Stopwatch _velocityStopwatch;
  Timer? _velocityResetTimer; // resets the velocity to zero if we haven't received a translation recently

  Offset get acceleration => _acceleration;
  Offset _acceleration = Offset.zero;

  /// The scale of the content in the viewport.
  @override
  double get scale => _scale;
  double _scale;
  @override
  set scale(double newScale) {
    if (newScale == _scale) {
      return;
    }

    // An external source has changed the scale. Stop any ongoing orientation simulation.
    stopSimulation();

    _scale = newScale;
    notifyListeners();
  }

  @protected
  double previousScale;

  double get scaleVelocity => _scaleVelocity;
  double _scaleVelocity;
  final Stopwatch _scaleVelocityStopwatch;

  /// The largest that the viewport content is allowed to be.
  double get maximumScale => _maximumScale;
  double _maximumScale;

  set maximumScale(double newMaximumScale) {
    if (newMaximumScale == _maximumScale) {
      return;
    }

    _maximumScale = maximumScale;
    if (_scale > _maximumScale) {
      _scale = _maximumScale;
    }

    notifyListeners();
  }

  /// The smallest that the viewport content is allowed to be.
  double get minimumScale => _minimumScale;
  double _minimumScale;

  set minimumScale(double newMinimumScale) {
    if (newMinimumScale == _minimumScale) {
      return;
    }

    _minimumScale = newMinimumScale;
    if (_scale < _minimumScale) {
      _scale = _minimumScale;
    }

    notifyListeners();
  }

  @override
  RenderPageListViewport? get viewport => _viewport;

  RenderPageListViewport? _viewport;

  /// Sets the [RenderPageListViewport] whose content transform is controlled
  /// by this controller.
  ///
  /// A connection to the viewport is needed to ensure that content doesn't
  /// move or scale in ways that violates the viewport's constraints, such as
  /// making the content smaller than the viewport.
  @override
  @protected
  set viewport(RenderPageListViewport? viewport) {
    if (_viewport == viewport) {
      return;
    }

    _viewport = viewport;

    // Stop any on-going orientation animation because we received a new viewport.
    _animationController.stop();
    stopSimulation();
  }

  Size? get _viewportSize => _viewport?.size;

  bool _isFirstLayoutForController = true;

  bool get isRunningOrientationSimulation => _activeSimulation != null;
  OrientationSimulation? _activeSimulation;
  Ticker? _simulationTicker;
  Duration? _previousSimulationTime;
  AxisAlignedOrientation? _previousSimulationOrientation;

  @override
  @protected
  void onViewportLayout() {
    disableNotifications();

    final minimumScaleToFillViewport = _viewport!.size.width / _viewport!._naturalPageSize.width;
    minimumScale = minimumScaleToFillViewport;

    if (_isFirstLayoutForController && _viewport!._pageCount > 0) {
      scale = minimumScaleToFillViewport;

      final totalContentHeight = _viewport!.calculateContentHeight(scale);
      if (totalContentHeight < _viewport!.size.height) {
        // We don't have enough content to fill the viewport. Center the content, vertically.
        origin = Offset(
          origin.dx,
          (_viewport!.size.height - totalContentHeight) / 2,
        );
      }

      _isFirstLayoutForController = false;
    } else if (scale < minimumScaleToFillViewport) {
      // Update the private property so that we don't markNeedsLayout during layout.
      scale = minimumScaleToFillViewport;
    }

    if (_initialPageIndex != null) {
      // Jump to the desired page on viewport attachment.
      _origin = _getPageOffset(_initialPageIndex!);
      _initialPageIndex = null;
    } else {
      _origin = _constrainOriginToViewportBounds(_origin);
    }

    enableNotifications(
      notifyIfNotificationsWereBlocked: true,
      notifyImmediately: false,
    );
  }

  /// Immediately changes the viewport offset so that the page at the given [pageIndex] is positioned as close
  /// as possible to the center of the viewport.
  ///
  /// To change the zoom level at the same time, provide a [zoomLevel].
  void jumpToPage(int pageIndex, [double? zoomLevel]) {
    if (_viewport == null) {
      PageListViewportLogs.pagesList
          .warning("Tried to jump to a PDF page but the controller isn't connected to a page list viewport");
      return;
    }

    // Stop any on-going orientation animation so that we can jump to the desired page.
    _animationController.stop();
    stopSimulation();

    _origin = _getPageOffset(pageIndex, zoomLevel);
    _velocity = Offset.zero;
    _velocityStopwatch.reset();

    notifyListeners();
  }

  Offset _getPageOffset(int pageIndex, [double? zoomLevel]) {
    final desiredZoomLevel = zoomLevel ?? scale;
    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(desiredZoomLevel);
    final desiredPageTopLeftInViewport =
        (_viewportSize!).center(Offset.zero) - Offset(pageSizeAtZoomLevel.width / 2, pageSizeAtZoomLevel.height / 2);
    final contentAboveDesiredPage = pageSizeAtZoomLevel.height * pageIndex;
    final desiredOrigin = Offset(0, -contentAboveDesiredPage) + desiredPageTopLeftInViewport;
    return _constrainOriginToViewportBounds(desiredOrigin);
  }

  /// Immediately changes the viewport offset so that the given [pixelOffsetInPage], within the  page at the given
  /// [pageIndex], is positioned as close as possible to the center of the viewport.
  ///
  /// To change the zoom level at the same time, provide a [zoomLevel].
  void jumpToOffsetInPage(int pageIndex, Offset pixelOffsetInPage, [double? zoomLevel]) {
    if (_viewport == null) {
      PageListViewportLogs.pagesList
          .warning("Tried to jump to a PDF page but the controller isn't connected to a page list viewport");
      return;
    }

    // Stop any on-going orientation animation so that we can jump to the desired page.
    _animationController.stop();
    stopSimulation();

    final desiredZoomLevel = zoomLevel ?? scale;
    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(desiredZoomLevel);
    final pageFocalPointAtZoomLevel = pixelOffsetInPage * desiredZoomLevel;
    final desiredPageTopLeftInViewport = (_viewportSize!).center(-pageFocalPointAtZoomLevel);
    final contentAboveDesiredPage = pageSizeAtZoomLevel.height * pageIndex;
    final desiredOrigin = Offset(0, -contentAboveDesiredPage) + desiredPageTopLeftInViewport;

    _origin = _constrainOriginToViewportBounds(desiredOrigin);
    _velocity = Offset.zero;
    _velocityStopwatch.reset();

    notifyListeners();
  }

  /// Animates the viewport offset so that the page at the given [pageIndex] is positioned as close
  /// as possible to the center of the viewport.
  ///
  /// By default, the animation runs with the given [duration]. To increase or decrease the duration based on
  /// the overall panning distance, pass `true` for [applyDurationPerPage].
  ///
  /// To change the zoom level at the same time, provide a [zoomLevel].
  ///
  /// Use [curve] to apply an animation curve.
  Future<void> animateToPage(
    int pageIndex,
    Duration duration, {
    double? zoomLevel,
    Curve curve = Curves.easeOut,
    bool applyDurationPerPage = false,
  }) {
    if (_viewport == null) {
      PageListViewportLogs.pagesList
          .warning("Tried to jump to a PDF page but the controller isn't connected to a page list viewport");
      return Future.value();
    }

    // We want to animate to a page, which means we don't want to continue with any
    // on-going orientation simulations.
    stopSimulation();

    final centerOfPage = _viewport!.calculatePageSize(1.0).center(Offset.zero);
    return animateToOffsetInPage(pageIndex, centerOfPage, duration);
  }

  /// Animates the viewport offset so that the [pixelOffsetInPage], within the page at the given [pageIndex], is
  /// positioned as close as possible to the center of the viewport.
  ///
  /// By default, the animation runs with the given [duration]. To increase or decrease the duration based on
  /// the overall panning distance, pass `true` for [applyDurationPerPage].
  ///
  /// To change the zoom level at the same time, provide a [zoomLevel].
  ///
  /// Use [curve] to apply an animation curve.
  Future<void> animateToOffsetInPage(
    int pageIndex,
    Offset pixelOffsetInPage,
    Duration duration, {
    double? zoomLevel,
    Curve curve = Curves.easeOut,
    bool applyDurationPerPage = false,
  }) {
    if (_viewport == null) {
      PageListViewportLogs.pagesList
          .warning("Tried to jump to a PDF page but the controller isn't connected to a page list viewport");
      return Future.value();
    }

    // Stop any on-going orientation animation so that we can jump to the desired page.
    _animationController.stop();
    stopSimulation();

    final desiredZoomLevel = zoomLevel ?? scale;
    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(desiredZoomLevel);
    final pageFocalPointAtZoomLevel = pixelOffsetInPage * desiredZoomLevel;
    final desiredPageTopLeftInViewport = (_viewportSize!).center(-pageFocalPointAtZoomLevel);
    final contentAboveDesiredPage = pageSizeAtZoomLevel.height * pageIndex;
    final destinationOffset =
        _constrainOriginToViewportBounds(Offset(0, -contentAboveDesiredPage) + desiredPageTopLeftInViewport);

    _previousOrigin = _origin;
    _velocityStopwatch.reset();
    _offsetAnimation = Tween<Offset>(begin: _origin, end: destinationOffset).animate(
      CurvedAnimation(parent: _animationController, curve: curve),
    );

    _scaleAnimation = Tween<double>(begin: scale, end: desiredZoomLevel).animate(
      CurvedAnimation(parent: _animationController, curve: curve),
    );
    final animationDuration = applyDurationPerPage
        ? duration * ((destinationOffset - _origin).dy.abs() / pageSizeAtZoomLevel.height)
        : duration;

    _animationController.duration = animationDuration;
    return _animationController.forward(from: 0);
  }

  void _onOrientationAnimationChange() {
    _origin = _offsetAnimation!.value;
    _scale = _scaleAnimation!.value;

    if (_velocityStopwatch.elapsedMilliseconds > 0) {
      _velocity = (_offsetAnimation!.value - _previousOrigin) / (_velocityStopwatch.elapsedMilliseconds / 1000);
      _velocityStopwatch.reset();
    }
    _previousOrigin = _offsetAnimation!.value;

    notifyListeners();
  }

  void _onOrientationAnimationEnd() {
    _velocity = Offset.zero;
    _velocityStopwatch.reset();

    notifyListeners();
  }

  void translate(Offset deltaInScreenSpace) {
    PageListViewportLogs.pagesListController.fine(() => "Translation requested for delta: $deltaInScreenSpace");
    final desiredOrigin = _origin + deltaInScreenSpace;
    PageListViewportLogs.pagesListController.fine(() =>
        "Origin before adjustment: $_origin. Content height: ${_viewport!.calculateContentHeight(scale)}, Scale: $scale");
    PageListViewportLogs.pagesListController
        .fine(() => "Viewport size: ${_viewport!.size}, scaled page width: ${_viewport!.calculatePageWidth(scale)}");

    // Stop any on-going orientation animation so that we can translate from the current orientation.
    _animationController.stop();
    stopSimulation();

    final newOrigin = _constrainOriginToViewportBounds(desiredOrigin);

    _previousOrigin = _origin;
    _origin = newOrigin;

    // Update velocity tracking.
    if (_velocityStopwatch.elapsedMilliseconds > 0) {
      _velocity = (newOrigin - _previousOrigin) / (_velocityStopwatch.elapsedMicroseconds / 1000000);

      _velocityStopwatch.reset();
      _velocityResetTimer?.cancel();

      if (_velocity.distance > 0) {
        // When the user is panning, we won't know when the final translation comes in.
        // Therefore, to eventually report a velocity of zero, we need to assume that the
        // absence of a message across a couple of frames indicates that we're done moving.
        _velocityResetTimer = Timer(const Duration(milliseconds: 32), () {
          _velocity = Offset.zero;
          notifyListeners();
        });
      }
    }

    notifyListeners();
  }

  void setScale(double newScale, Offset focalPointInViewport) {
    assert(newScale > 0.0);
    PageListViewportLogs.pagesListController
        .fine(() => "Scale requested with desired scale: $newScale, min scale: $_minimumScale");

    // Stop any on-going orientation animation so that we honor the desired scale.
    _animationController.stop();
    stopSimulation();

    newScale = newScale.clamp(_minimumScale, maximumScale);

    final scaleDiff = newScale / _scale;

    // When the scale changes, the origin offset needs to move accordingly.
    // The distance that the origin offset moves depends on how far the
    // origin sits from the scaling focal point. For example, when the
    // origin sits exactly at the focal point, the origin shouldn't move
    // at all.
    final focalPointToOrigin = _origin - focalPointInViewport;
    _origin = focalPointInViewport + (focalPointToOrigin * scaleDiff);

    // Update our scale.
    PageListViewportLogs.pagesListController.fine(() => "Setting scale to $newScale");
    previousScale = _scale;
    _scale = newScale;
    _scaleVelocity = (_scale - previousScale) / (_scaleVelocityStopwatch.elapsedMilliseconds / 1000);
    _scaleVelocityStopwatch.reset();

    // Snap the content back to the viewport edges.
    _origin = _constrainOriginToViewportBounds(_origin);

    notifyListeners();
  }

  /// The given [simulation] takes control of the orientation of the content associated
  /// with this controller.
  ///
  /// Any manual adjustment of the orientation will cause this simulation to immediately
  /// cease controlling the orientation.
  void driveWithSimulation(OrientationSimulation simulation) {
    if (_activeSimulation != null) {
      stopSimulation();
    }

    _activeSimulation = simulation;
    _previousSimulationTime = Duration.zero;
    _previousSimulationOrientation = AxisAlignedOrientation(_origin, _scale);
    _simulationTicker ??= _tickerProvider.createTicker(_onSimulationTick);

    _simulationTicker!.start();
  }

  void _onSimulationTick(Duration elapsedTime) {
    if (!isRunningOrientationSimulation) {
      return;
    }
    if (elapsedTime == Duration.zero) {
      return;
    }

    // Calculate a new orientation based on the time that's passed.
    final orientation = _activeSimulation!.orientationAt(elapsedTime);

    // Update the velocity calculations.
    final dt = elapsedTime - (_previousSimulationTime ?? Duration.zero);
    final dtInSeconds = dt.inMicroseconds.toDouble() / 1e6;
    final velocity = (orientation.origin - _previousSimulationOrientation!.origin) / dtInSeconds;
    _acceleration = velocity - _velocity;
    _velocity = velocity;
    _scaleVelocity = (orientation.scale - _previousSimulationOrientation!.scale) / dtInSeconds;

    // Update the content origin and scale.
    _scale = orientation.scale;
    _previousOrigin = _origin;
    _origin = _constrainOriginToViewportBounds(orientation.origin);

    // Check if the simulation is close enough to complete for us to stop it.
    if ((_origin - _previousOrigin).distance.abs() < 0.01) {
      stopSimulation();

      // Ensure that we always report a zero velocity at the end of the simulation.
      _acceleration = Offset.zero;
      _velocity = Offset.zero;
      _scaleVelocity = 0;
    }

    // Update our previous-frame accounting, for the next simulation frame.
    _previousSimulationTime = elapsedTime;
    _previousSimulationOrientation = AxisAlignedOrientation(_origin, _scale);

    notifyListeners();
  }

  /// Stops any on-going orientation simulation, started by [driveWithSimulation].
  void stopSimulation() {
    _activeSimulation = null;

    _simulationTicker?.stop();
    _simulationTicker = null;

    _previousSimulationTime = null;
    _previousSimulationOrientation = null;
  }

  Offset _constrainOriginToViewportBounds(Offset desiredOrigin) {
    // If content is thinner than a viewport dimension, that content should be centered.
    //
    // If content is as wide, or wider than a viewport dimension, that content offset should
    // be constrained so that no white space ever appears on either side of the content along
    // that dimension.
    double originX = desiredOrigin.dx;
    double originY = desiredOrigin.dy;

    final contentWidth = _viewport!.calculatePageWidth(scale);
    final contentHeight = _viewport!.calculateContentHeight(scale);
    final viewportSize = _viewport!.size;

    if (contentWidth <= viewportSize.width) {
      originX = (viewportSize.width - contentWidth) / 2;
    } else {
      const maxOriginX = 0.0;
      final minOriginX = viewportSize.width - contentWidth;
      originX = originX.clamp(minOriginX, maxOriginX);
    }

    if (contentHeight <= viewportSize.height) {
      originY = (viewportSize.height - contentHeight) / 2;
    } else {
      const maxOriginY = 0.0;
      final minOriginY = viewportSize.height - contentHeight;
      originY = originY.clamp(minOriginY, maxOriginY);
    }

    return Offset(originX, originY);
  }
}

abstract class OrientationSimulation {
  AxisAlignedOrientation orientationAt(Duration time);
}

class AxisAlignedOrientation {
  const AxisAlignedOrientation(this.origin, this.scale);

  final Offset origin;
  final double scale;
}

/// An [OrientationSimulation] that moves the viewport content based an initial
/// velocity
class BallisticPanningOrientationSimulation implements OrientationSimulation {
  BallisticPanningOrientationSimulation({
    required AxisAlignedOrientation initialOrientation,
    required PanningSimulation panningSimulation,
  })  : _initialOrientation = initialOrientation,
        _panningSimulation = panningSimulation;

  final AxisAlignedOrientation _initialOrientation;
  final PanningSimulation _panningSimulation;

  @override
  AxisAlignedOrientation orientationAt(Duration time) {
    return AxisAlignedOrientation(
      _panningSimulation.offsetAt(time),
      _initialOrientation.scale,
    );
  }
}

abstract class PanningSimulation {
  Offset offsetAt(Duration time);
}

abstract class OrientationController with ChangeNotifier {
  /// The (x,y) offset of the top-left corner of the content from the top-left corner of the
  /// viewport bounds.
  Offset get origin;
  set origin(Offset newOrigin);

  /// The scale of the content, as a ratio of the content's intrinsic size.
  double get scale;
  set scale(double newScale);

  /// The [RenderPageListViewport] whose content transform is controlled
  /// by this controller.
  ///
  /// A connection to the viewport is needed to ensure that content doesn't
  /// move or scale in ways that violates the viewport's constraints, such as
  /// making the content smaller than the viewport.
  @protected
  RenderPageListViewport? get viewport;

  /// Sets the [RenderPageListViewport] whose content transform is controlled
  /// by this controller.
  ///
  /// A connection to the viewport is needed to ensure that content doesn't
  /// move or scale in ways that violates the viewport's constraints, such as
  /// making the content smaller than the viewport.
  @protected
  set viewport(RenderPageListViewport? viewport);

  @protected
  void onViewportLayout();

  bool _sendNotifications = true;
  bool _didBlockNotifications = false;

  /// Allow this controller to [notifyListeners] again.
  ///
  /// If [notifyIfNotificationsWereBlocked] is `true`, and any notifications
  /// were blocked while notifications were disabled, then [notifyListeners] is
  /// called. If [notifyImmediately] is `true`, listeners will be notified
  /// immediately, otherwise, listeners will be notified at the end of the frame.
  @protected
  void enableNotifications({
    bool notifyIfNotificationsWereBlocked = true,
    bool notifyImmediately = true,
  }) {
    _sendNotifications = true;

    if (_didBlockNotifications && notifyIfNotificationsWereBlocked) {
      if (notifyImmediately) {
        notifyListeners();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
          notifyListeners();
        });
      }
    }
    _didBlockNotifications = false;
  }

  /// Don't allow this controller to [notifyListeners].
  @protected
  void disableNotifications() => _sendNotifications = false;

  @override
  void notifyListeners() {
    if (!_sendNotifications) {
      _didBlockNotifications = true;
      return;
    }

    super.notifyListeners();
  }
}

class RenderPageListViewport extends RenderBox {
  RenderPageListViewport({
    required PageListViewportElement element,
    required OrientationController controller,
    required int pageCount,
    required Size pageSize,
    int pageLayoutCacheCount = 0,
    int pagePaintCacheCount = 0,
  })  : _element = element,
        _pageCount = pageCount,
        _naturalPageSize = pageSize,
        _pageLayoutCacheCount = pageLayoutCacheCount,
        _pagePaintCacheCount = pagePaintCacheCount {
    // Run controller assignment through the public method
    // so that we attach ourselves to it.
    this.controller = controller;
  }

  @override
  void dispose() {
    _controller?.removeListener(_onOrientationChange);
    _element = null;
    super.dispose();
  }

  PageListViewportElement? _element;
  int _pageCount;

  set pageCount(int newCount) {
    if (newCount == _pageCount) {
      return;
    }

    _pageCount = newCount;
    markNeedsLayout();
  }

  Size _naturalPageSize;

  set naturalPageSize(Size newPageSize) {
    if (newPageSize == _naturalPageSize) {
      return;
    }

    _naturalPageSize = newPageSize;
    markNeedsLayout();
  }

  Size get _scaledPageSize => _naturalPageSize * _controller!.scale;

  int _pageLayoutCacheCount;

  set pageLayoutCacheCount(int newCount) {
    assert(newCount >= 0);
    if (newCount == _pageLayoutCacheCount) {
      return;
    }

    if (newCount > _pageLayoutCacheCount) {
      // Only request a layout if we want MORE pages cached
      // than we did before. Otherwise, it costs us nothing
      // to wait until the next pass and throw away what we
      // don't need.
      markNeedsLayout();
    }

    _pageLayoutCacheCount = newCount;
  }

  int _pagePaintCacheCount;

  set pagePaintCacheCount(int newCount) {
    assert(newCount >= 0);
    if (newCount == _pagePaintCacheCount) {
      return;
    }

    if (newCount > _pagePaintCacheCount) {
      // Only request a paint if we want MORE pages cached
      // than we did before. Otherwise, it costs us nothing
      // to wait until the next pass and throw away what we
      // don't need.
      markNeedsPaint();
    }

    _pagePaintCacheCount = newCount;
  }

  OrientationController? _controller;

  set controller(OrientationController newController) {
    if (_controller == newController) {
      return;
    }

    _controller?.removeListener(_onOrientationChange);
    _controller?.viewport = null;

    _controller = newController;
    _controller!.viewport = this;
    _controller!.addListener(_onOrientationChange);

    markNeedsLayout();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  ClipRectLayer? get layer => super.layer as ClipRectLayer?;

  @override
  set layer(ContainerLayer? newLayer) => super.layer = newLayer as ClipRectLayer?;

  @override
  void attach(PipelineOwner owner) {
    PageListViewportLogs.pagesList.finest(() => "attach()'ing viewport render object to pipeline");
    super.attach(owner);

    visitChildren((child) {
      child.attach(owner);
    });
  }

  @override
  void detach() {
    PageListViewportLogs.pagesList.finest(() => "detach()'ing viewport render object from pipeline");
    // IMPORTANT: we must detach ourselves before detaching our children.
    // This is a Flutter framework requirement.
    super.detach();

    // Detach our children.
    visitChildren((child) {
      child.detach();
    });
  }

  void _onOrientationChange() {
    markNeedsLayout();

    // When the viewport only translates (no scale), the children won't have their performLayout()
    // function called because their constraints didn't change, and no one marked them dirty.
    //
    // But, child pages that care about the viewport translation, such as pages that cull their
    // content, need to re-run layout, even when their size doesn't change.
    //
    // For now, we force all of our children to re-run layout whenever we pan.
    // FIXME: find another way to trigger relevant child page relayout, or at least add a way to
    //        opt-in to this behavior, instead of forcing relayout on all pages of all types.
    visitChildren((child) {
      child.markNeedsLayout();
    });
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! ViewportPageParentData) {
      child.parentData = ViewportPageParentData(pageIndex: -1);
    }
  }

  @override
  void visitChildren(RenderObjectVisitor visitor) {
    final children = _element!._childElements.values.toList();
    for (final child in children) {
      visitor(child!.renderObject!);
    }
  }

  Size calculatePageSize(double scale) => _naturalPageSize * scale;

  double calculatePageWidth(double scale) => _naturalPageSize.width * scale;

  double calculatePageHeight(double scale) => _naturalPageSize.height * scale;

  double calculateContentHeight(double scale) => calculatePageHeight(scale) * _pageCount;

  @override
  void performLayout() {
    size = constraints.biggest;
    if (size.width == 0) {
      // Our content calculations depend on a non-zero width. If we have no width, there's
      // nothing to layout or paint anyway. Bail out now and avoid adding code to account
      // for zero width.
      return;
    }

    // We must let the controller do its layout work before we create and cull the pages,
    // because the controller might change the offset of the viewport.
    _controller!.onViewportLayout();

    _createAndCullVisibleAndCachedPages();

    final pageSize = Size(
      calculatePageWidth(_controller!.scale),
      calculatePageHeight(_controller!.scale),
    );

    _visitLayoutChildren((pageIndex, childElement) {
      if (childElement == null) {
        return;
      }

      final child = childElement.renderObject! as RenderBox;
      final pageParentData = child.parentData as ViewportPageParentData;
      pageParentData
        ..viewportSize = size
        ..pageIndex = pageIndex
        ..offset = _controller!.origin + (Offset(0, pageSize.height) * pageIndex.toDouble());
      PageListViewportLogs.pagesList.finest(() => "Laying out child (at $pageIndex): $child");
      child.layout(BoxConstraints.tight(pageSize), parentUsesSize: true);
      PageListViewportLogs.pagesList.finest(() => " - child size: ${child.size}");
    });
  }

  // This page list needs to build and layout any pages that should
  // be visible in the viewport. It also needs to build and layout
  // any pages that sit near the viewport (based on our cache policy).
  //
  // This method finds any relevant pages that have yet to be built,
  // and then builds those pages, and adds their new `RenderObject`s
  // as children.
  void _createAndCullVisibleAndCachedPages() {
    invokeLayoutCallback((constraints) {
      // Create new pages in visual and cache range.
      _visitLayoutChildren((pageIndex, childElement) {
        if (childElement == null) {
          // We call invokeLayoutCallback() because that's the only way we're
          // allowed to adopt children during layout.
          _element!.createPage(pageIndex);
        }
      });

      // Remove pages outside of cache range.
      final firstPageIndex = _findFirstCachedPageIndex();
      final lastPageIndex = _findLastCachedPageIndex();
      _element!.removePagesOutsideRange(firstPageIndex, lastPageIndex);
    });
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    bool didHitChild = false;
    _visitLayoutChildren((pageIndex, childElement) {
      if (childElement == null) {
        return;
      }
      if (didHitChild) {
        return;
      }

      final childRenderBox = childElement.renderObject as RenderBox;
      final childTransform = Matrix4.identity();
      applyPaintTransform(childRenderBox, childTransform);
      didHitChild = result.addWithPaintTransform(
        transform: childTransform,
        position: position,
        hitTest: (BoxHitTestResult result, Offset position) {
          return childRenderBox.hitTest(result, position: position);
        },
      );
    });
    if (didHitChild) {
      return true;
    }

    if (hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }

    return false;
  }

  @override
  bool hitTestSelf(Offset position) {
    return size.contains(position);
  }

  void _visitLayoutChildren(Function(int pageIndex, Element? childElement) visitor) {
    final firstPageIndexToLayout = _findFirstCachedPageIndex();
    final lastPageIndexToLayout = _findLastCachedPageIndex();
    for (int pageIndex = firstPageIndexToLayout; pageIndex <= lastPageIndexToLayout; pageIndex += 1) {
      visitor(pageIndex, _element!._childElements[pageIndex]);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.width == 0) {
      // Our content calculations depend on a non-zero width. If we have no width, there's
      // nothing to layout or paint anyway. Bail out now and avoid adding code to account
      // for zero width.
      return;
    }

    final childElements = _element!._childElements;
    final firstPageToPaintIndex = _findFirstPaintedPageIndex();
    final lastPageToPaintIndex = _findLastPaintedPageIndex();

    PageListViewportLogs.pagesList.finest(() => "Painting children at scale: ${_controller!.scale}");

    layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      oldLayer: layer,
      (context, offset) {
        // Paint all the pages that are visible or cached.
        for (int pageIndex = firstPageToPaintIndex; pageIndex <= lastPageToPaintIndex; pageIndex += 1) {
          if (debugProfilePaintsEnabled) {
            Timeline.startSync("Paint page $pageIndex");
            Timeline.startSync("Vars");
          }

          final childElement = childElements[pageIndex]!;
          final childRenderBox = childElement.renderObject! as RenderBox;
          final transform = Matrix4.identity();

          if (debugProfilePaintsEnabled) {
            Timeline.finishSync();
            Timeline.startSync("Paint transform");
          }

          applyPaintTransform(childRenderBox, transform);

          if (debugProfilePaintsEnabled) {
            Timeline.finishSync();
            Timeline.startSync("Local to global");
          }

          final pageOriginVec = transform.transform3(Vector3(0, 0, 0));
          // PageListViewportLogs.pagesList.finer("Painting page index: $pageIndex");
          // PageListViewportLogs.pagesList.finer(" - child element: $childElement");
          // PageListViewportLogs.pagesList.finer(" - scaled page size: $_scaledPageSize");
          // PageListViewportLogs.pagesList.finer(" - page origin: $pageOriginVec");
          // PageListViewportLogs.pagesList.finer(" - scaled origin: ${pageOriginVec * _contentScale}");
          // PageListViewportLogs.pagesList.finer("Painting child render object: $childRenderBox");
          if (debugProfilePaintsEnabled) {
            Timeline.finishSync();
          }

          final parentData = childRenderBox.parentData as ViewportPageParentData;
          parentData.transformLayerHandle.layer = context.pushTransform(
            needsCompositing,
            offset,
            transform,
            oldLayer: parentData.transformLayerHandle.layer,
            // Calling context.paintChild() seems to be necessary. Without it, it seems that our children
            // might need to paint and yet we don't paint them. Not sure why.
            (context, offset) => context.paintChild(childRenderBox, offset),
          );

          if (debugProfilePaintsEnabled) {
            Timeline.finishSync();
          }
        }
      },
    );
    PageListViewportLogs.pagesList.finest(() => "Done with viewport paint");
  }

  // The transform in this method is used to map from global-to-local, and
  // local-to-global. We need to report the position of our [child] through
  // the given [transform].
  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    final pageIndex = (child.parentData as ViewportPageParentData).pageIndex;
    final pageOrigin = Offset(
      _controller!.origin.dx,
      _controller!.origin.dy + (_scaledPageSize.height * pageIndex),
    );
    transform.translate(pageOrigin.dx, pageOrigin.dy);
  }

  int _findFirstVisiblePageIndex() {
    return _controller!.origin.dy.abs() ~/ _scaledPageSize.height;
  }

  int _findLastVisiblePageIndex() {
    return (_controller!.origin.dy.abs() + size.height) ~/ _scaledPageSize.height;
  }

  int _findFirstPaintedPageIndex() {
    return math.max(_findFirstVisiblePageIndex() - _pagePaintCacheCount, 0);
  }

  int _findLastPaintedPageIndex() {
    return math.min(_findLastVisiblePageIndex() + _pagePaintCacheCount, _pageCount - 1);
  }

  int _findFirstCachedPageIndex() {
    return math.max(_findFirstVisiblePageIndex() - _pageLayoutCacheCount, 0);
  }

  int _findLastCachedPageIndex() {
    return math.min(_findLastVisiblePageIndex() + _pageLayoutCacheCount, _pageCount - 1);
  }
}

class PageListViewportElement extends RenderObjectElement {
  PageListViewportElement(super.widget);

  bool get hasChildren => _childElements.isNotEmpty;

  int get childCount => _childElements.length;

  final SplayTreeMap<int, Element?> _childElements = SplayTreeMap<int, Element?>();

  @override
  RenderPageListViewport get renderObject => super.renderObject as RenderPageListViewport;

  @override
  void visitChildren(ElementVisitor visitor) {
    for (final childElement in _childElements.values) {
      visitor(childElement!);
    }
  }

  // TODO: check if we can use multi child element to automatically rebuild
  // our children at the appropriate time.
  @override
  void update(RenderObjectWidget newWidget) {
    PageListViewportLogs.pagesList.finest(() => "update() on element");
    super.update(newWidget);

    if (Widget.canUpdate(widget, newWidget)) {
      performRebuild();
    }
  }

  @override
  Element? updateChild(Element? child, Widget? newWidget, Object? newSlot) {
    PageListViewportLogs.pagesList.finest(() => "updateChild(): $newWidget");
    return super.updateChild(child, newWidget, newSlot);
  }

  @override
  void performRebuild() {
    PageListViewportLogs.pagesList.finest(() => "performRebuild()");
    super.performRebuild();

    // rebuild() is where typical RenderObjects add and remove children
    // based on its widget. We add children during layout(), so we can't
    // do that here. However, if the widget has reduced the number of
    // desired pages, we can remove extra pages here.
    final pageListViewport = widget as PageListViewport;
    if (pageListViewport.pageCount < childCount) {
      for (int i = childCount - 1; i >= pageListViewport.pageCount; i -= 1) {
        forgetChild(_childElements[i]!);
        _childElements.remove(i);
      }
    }

    for (final childEntry in _childElements.entries) {
      final pageIndex = childEntry.key;
      final pageWidget = pageListViewport.builder(this, pageIndex);

      _childElements[pageIndex] = updateChild(
        _childElements[pageIndex],
        pageWidget,
        pageIndex,
      );
    }
  }

  void createPage(int pageIndex) {
    owner!.buildScope(this, () {
      Element? newChild;
      try {
        newChild = updateChild(
          _childElements[pageIndex],
          (widget as PageListViewport).builder(this, pageIndex),
          pageIndex,
        );
      } finally {}
      if (newChild != null) {
        _childElements[pageIndex] = newChild;
      } else {
        _childElements.remove(pageIndex);
      }
    });
  }

  void removePagesOutsideRange(int firstPageIndex, int lastPageIndex) {
    assert(firstPageIndex <= lastPageIndex);

    final pageIndices = _childElements.keys.toList(growable: false);
    for (final pageIndex in pageIndices) {
      if (pageIndex >= firstPageIndex && pageIndex <= lastPageIndex) {
        continue;
      }

      // Remove this page because it isn't in the desired range.
      deactivateChild(_childElements[pageIndex]!);
      _childElements.remove(pageIndex);
    }
  }

  @override
  void insertRenderObjectChild(RenderObject child, Object? slot) {
    PageListViewportLogs.pagesList.finest(() => "Viewport adopting render object child: $child");
    renderObject.adoptChild(child);
  }

  @override
  void moveRenderObjectChild(RenderObject child, Object? oldSlot, Object? newSlot) {
    // no-op
  }

  @override
  void removeRenderObjectChild(RenderObject child, Object? slot) {
    PageListViewportLogs.pagesList
        .finest(() => "removeRenderObjectChild() - child: $child, slot: $slot, is attached? ${child.attached}");
    renderObject.dropChild(child);
  }
}

class ViewportPageParentData extends ContainerBoxParentData<RenderBox> with ContainerParentDataMixin<RenderBox> {
  ViewportPageParentData({
    required this.pageIndex,
  });

  late Size viewportSize;
  int pageIndex;

  final transformLayerHandle = LayerHandle<TransformLayer>();

  @override
  void detach() {
    transformLayerHandle.layer = null;
    super.detach();
  }
}

/// Tracks scale gesture events and calculates a velocity based on those
/// events.
///
/// A custom tracker is needed because Flutter reports a new gesture every time
/// a user's finger is added or removed. It's virtually impossible for a user to
/// place both fingers down at exactly the same time, or remove them at exactly
/// the same time. Therefore, additional tracking and analysis is required to
/// determine when a gesture actually ends, as well as the appropriate final
/// velocity for that gesture.
///
/// This tracker ignores the very brief gestures that represent fingers being
/// added to, or removed from the screen.
///
/// This tracker doesn't report velocity for gestures with 2+ fingers because
/// the reported velocity during scale operations rarely seems to match the
/// intentions of the scale behavior. So we ignore velocity in those cases
/// altogether.
class PanAndScaleVelocityTracker {
  PanAndScaleVelocityTracker({
    required Clock clock,
  }) : _clock = clock;

  final Clock _clock;

  int _previousPointerCount = 0;
  int? _previousGestureEndTimeInMillis;
  int? _previousGesturePointerCount;

  int? _currentGestureStartTimeInMillis;
  PanAndScaleGestureAction? _currentGestureStartAction;
  bool _isPossibleGestureContinuation = false;

  Offset get velocity => _launchVelocity;
  Offset _launchVelocity = Offset.zero;
  final _recentVelocity = <_VelocitySlice>[];
  int _lastScaleTime = 0;

  void onScaleStart(ScaleStartDetails details) {
    PageListViewportLogs.pagesListGestures.fine(() =>
        "onScaleStart() - pointer count: ${details.pointerCount}, time since last gesture: ${_timeSinceLastGesture?.inMilliseconds}ms");

    if (_previousPointerCount == 0) {
      _currentGestureStartAction = PanAndScaleGestureAction.firstFingerDown;
    } else if (details.pointerCount > _previousPointerCount) {
      // This situation might signify:
      //
      //  1. The user is trying to place 2 fingers on the screen and the 2nd finger
      //     just touched down.
      //
      //  2. The user was panning with 1 finger and just added a 2nd finger to start
      //     scaling.
      _currentGestureStartAction = PanAndScaleGestureAction.addFinger;
    } else if (details.pointerCount == 0) {
      _currentGestureStartAction = PanAndScaleGestureAction.removeLastFinger;
    } else {
      // This situation might signify:
      //
      //  1. The user is trying to remove 2 fingers from the screen and the 1st finger
      //     just lifted off.
      //
      //  2. The user was scaling with 2 fingers and just removed 1 finger to start
      //     panning instead of scaling.
      _currentGestureStartAction = PanAndScaleGestureAction.removeNonLastFinger;
    }
    PageListViewportLogs.pagesListGestures.fine(() => " - start action: $_currentGestureStartAction");
    _currentGestureStartTimeInMillis = _clock.millis;

    if (_timeSinceLastGesture != null && _timeSinceLastGesture! < const Duration(milliseconds: 30)) {
      PageListViewportLogs.pagesListGestures.fine(() =>
          " - this gesture started really fast. Assuming that this is a continuation. Previous pointer count: $_previousPointerCount. Current pointer count: ${details.pointerCount}");
      _isPossibleGestureContinuation = true;
    } else {
      PageListViewportLogs.pagesListGestures.fine(() => " - restarting velocity for new gesture");
      _isPossibleGestureContinuation = false;
      _previousGesturePointerCount = details.pointerCount;
      _launchVelocity = Offset.zero;
      _lastScaleTime = _clock.millis;
      _recentVelocity.clear();
    }

    _previousPointerCount = details.pointerCount;
  }

  void onScaleUpdate(ScaleUpdateDetails details) {
    PageListViewportLogs.pagesListGestures.fine(() => "Scale update: ${details.localFocalPoint}");

    if (_isPossibleGestureContinuation) {
      if (_timeSinceStartOfGesture < const Duration(milliseconds: 24)) {
        PageListViewportLogs.pagesListGestures.fine(() => " - this gesture is a continuation. Ignoring update.");
        return;
      }

      // Enough time has passed for us to conclude that this gesture isn't just
      // an intermediate moment as the user adds or removes fingers. This gesture
      // is intentional, and we need to track its velocity.
      PageListViewportLogs.pagesListGestures
          .fine(() => " - a possible gesture continuation has been confirmed as a new gesture. Restarting velocity.");
      _currentGestureStartTimeInMillis = _clock.millis;
      _previousGesturePointerCount = details.pointerCount;
      _launchVelocity = Offset.zero;
      _lastScaleTime = _clock.millis;
      _recentVelocity.clear();
      PageListViewportLogs.pagesListGesturesVelocity.finer(() => "Clearing velocity history");

      _isPossibleGestureContinuation = false;

      return;
    }

    // Update velocity tracking.
    if (_recentVelocity.length == 20) {
      _recentVelocity.removeAt(0);
    }

    final velocitySlice =
        _VelocitySlice(translation: details.focalPointDelta, dtInMillis: _clock.millis - _lastScaleTime);
    PageListViewportLogs.pagesListGesturesVelocity.finer(() =>
        "Velocity: ${velocitySlice.pixelsPerSecond} pixels/second (focal delta: ${details.focalPointDelta}) (dt: ${velocitySlice.seconds})");
    _recentVelocity.add(velocitySlice);
    _lastScaleTime = _clock.millis;
  }

  void onScaleEnd(ScaleEndDetails details) {
    final gestureDuration = Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);
    PageListViewportLogs.pagesListGestures
        .fine(() => "onScaleEnd() - gesture duration: ${gestureDuration.inMilliseconds}");

    _previousGestureEndTimeInMillis = _clock.millis;
    _previousPointerCount = details.pointerCount;
    _currentGestureStartAction = null;
    _currentGestureStartTimeInMillis = null;

    if (_isPossibleGestureContinuation) {
      PageListViewportLogs.pagesListGestures.fine(() => " - this gesture is a continuation of a previous gesture.");
      if (details.pointerCount > 0) {
        PageListViewportLogs.pagesListGestures.fine(() =>
            " - this continuation gesture still has fingers touching the screen. The end of this gesture means nothing for the velocity.");
        return;
      } else {
        PageListViewportLogs.pagesListGestures.fine(() =>
            " - the user just removed the final finger. Using launch velocity from previous gesture: $_launchVelocity");
        return;
      }
    }

    if (gestureDuration < const Duration(milliseconds: 40)) {
      PageListViewportLogs.pagesListGestures.fine(() => " - this gesture was too short to count. Ignoring.");
      return;
    }

    if (_previousGesturePointerCount! > 1) {
      // The user was scaling. Now the user is panning. We don't want scale
      // gestures to contribute momentum, so we set the launch velocity to zero.
      // If the panning continues long enough, then we'll use the panning
      // velocity for momentum.
      PageListViewportLogs.pagesListGestures
          .fine(() => " - this gesture was a scale gesture and user switched to panning. Resetting launch velocity.");
      _launchVelocity = Offset.zero;
      _lastScaleTime = _clock.millis;
      _recentVelocity.clear();
      PageListViewportLogs.pagesListGesturesVelocity.finer(() => "Clearing velocity history");
      return;
    }

    if (details.pointerCount > 0) {
      PageListViewportLogs.pagesListGestures
          .fine(() => " - the user removed a finger, but is still interacting. Storing velocity for later.");
      PageListViewportLogs.pagesListGestures
          .fine(() => " - stored velocity: $_launchVelocity, magnitude: ${_launchVelocity.distance}");
      return;
    }

    PageListViewportLogs.pagesListGesturesVelocity
        .finer(() => "Ending velocity: ${details.velocity.pixelsPerSecond} pixels per second");
    // _launchVelocity = details.velocity.pixelsPerSecond;
    _launchVelocity = _recentVelocity
        .fold(_VelocitySlice.zero, (totalVelocity, velocitySlice) => totalVelocity + velocitySlice)
        .pixelsPerSecond;
    _recentVelocity.clear();
    PageListViewportLogs.pagesListGesturesVelocity
        .finer(() => "Average velocity (launch velocity): $_launchVelocity pixels per second");
    PageListViewportLogs.pagesListGesturesVelocity.finer(() => "Clearing velocity history");
    PageListViewportLogs.pagesListGestures
        .fine(() => " - the user has completely stopped interacting. Launch velocity is: $_launchVelocity");
  }

  Duration get _timeSinceStartOfGesture => Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);

  Duration? get _timeSinceLastGesture => _previousGestureEndTimeInMillis != null
      ? Duration(milliseconds: _clock.millis - _previousGestureEndTimeInMillis!)
      : null;
}

class _VelocitySlice {
  static const zero = _VelocitySlice(translation: Offset.zero, dtInMillis: 0);

  const _VelocitySlice({
    required this.translation,
    required this.dtInMillis,
  });

  final Offset translation;
  final int dtInMillis;

  _VelocitySlice operator +(_VelocitySlice other) {
    return _VelocitySlice(
      translation: translation + other.translation,
      dtInMillis: dtInMillis + other.dtInMillis,
    );
  }

  Offset get pixelsPerSecond => seconds > 0 ? translation / seconds : Offset.zero;

  double get seconds => dtInMillis / 1000.0;
}

enum PanAndScaleGestureAction {
  firstFingerDown,
  addFinger,
  removeNonLastFinger,
  removeLastFinger,
}

class Clock {
  const Clock();

  int get millis => DateTime.now().millisecondsSinceEpoch;
}

class FakeClock implements Clock {
  @override
  int millis = 0;
}
