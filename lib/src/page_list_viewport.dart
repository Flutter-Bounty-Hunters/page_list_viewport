import 'dart:collection';
import 'dart:developer';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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
  final PageListViewportController controller;

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
    PageListViewportLogs.pagesList.finest("Creating PageListViewport element");
    return PageListViewportElement(this);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    PageListViewportLogs.pagesList.finest("Creating PageListViewport render object");
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
    PageListViewportLogs.pagesList.finest("Updating PageListViewport render object");
    renderObject //
      ..pageCount = pageCount
      ..naturalPageSize = naturalPageSize
      ..pageLayoutCacheCount = pageLayoutCacheCount
      ..pagePaintCacheCount = pagePaintCacheCount
      ..controller = controller;
  }
}

typedef PageBuilder = Widget Function(BuildContext context, int pageIndex);

class PageListViewportController with ChangeNotifier {
  PageListViewportController({
    required TickerProvider vsync,
    Offset origin = Offset.zero,
    double scale = 1.0,
    double minimumScale = 0.1,
    double maximumScale = double.infinity,
  })  : _origin = origin,
        _scale = scale,
        _minimumScale = minimumScale,
        _maximumScale = maximumScale {
    _animationController = AnimationController(vsync: vsync) //
      ..addListener(_onOrientationAnimationChange);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  late final AnimationController _animationController;
  Animation? _offsetAnimation;
  Animation? _scaleAnimation;

  /// The (x,y) offset of the top-left corner of the first page in
  /// the page list, measured in un-scaled pixels.
  Offset get origin => _origin;

  Offset _origin;

  set origin(Offset newOrigin) {
    if (newOrigin == _origin) {
      return;
    }

    // Stop any on-going orientation animation so that the origin stays at
    // the new offset.
    _animationController.stop();

    _origin = newOrigin;
    notifyListeners();
  }

  /// The scale of the content in the viewport.
  double get scale => _scale;
  double _scale;

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

  RenderPageListViewport? _viewport;

  /// Sets the [RenderPageListViewport] whose content transform is controlled
  /// by this controller.
  ///
  /// A connection to the viewport is needed to ensure that content doesn't
  /// move or scale in ways that violates the viewport's constraints, such as
  /// making the content smaller than the viewport.
  set viewport(RenderPageListViewport? viewport) {
    if (_viewport == viewport) {
      return;
    }

    _viewport = viewport;

    // Stop any on-going orientation animation because we received a new viewport.
    _animationController.stop();
  }

  Size? get viewportSize => _viewport?.size;

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

    final desiredZoomLevel = zoomLevel ?? scale;
    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(desiredZoomLevel);
    final desiredPageTopLeftInViewport =
        (viewportSize!).center(Offset.zero) - Offset(pageSizeAtZoomLevel.width / 2, pageSizeAtZoomLevel.height / 2);
    final contentAboveDesiredPage = pageSizeAtZoomLevel.height * pageIndex;
    final desiredOrigin = Offset(0, -contentAboveDesiredPage) + desiredPageTopLeftInViewport;
    _origin = _constrainOriginToViewportBounds(desiredOrigin);

    notifyListeners();
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

    final desiredZoomLevel = zoomLevel ?? scale;
    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(desiredZoomLevel);
    final pageFocalPointAtZoomLevel = pixelOffsetInPage * desiredZoomLevel;
    final desiredPageTopLeftInViewport = (viewportSize!).center(-pageFocalPointAtZoomLevel);
    final contentAboveDesiredPage = pageSizeAtZoomLevel.height * pageIndex;
    final desiredOrigin = Offset(0, -contentAboveDesiredPage) + desiredPageTopLeftInViewport;
    _origin = _constrainOriginToViewportBounds(desiredOrigin);

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

    // Stop any on-going orientation animation so we can start a new one.
    _animationController.stop();

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

    final desiredZoomLevel = zoomLevel ?? scale;
    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(desiredZoomLevel);
    final pageFocalPointAtZoomLevel = pixelOffsetInPage * desiredZoomLevel;
    final desiredPageTopLeftInViewport = (viewportSize!).center(-pageFocalPointAtZoomLevel);
    final contentAboveDesiredPage = pageSizeAtZoomLevel.height * pageIndex;
    final destinationOffset =
        _constrainOriginToViewportBounds(Offset(0, -contentAboveDesiredPage) + desiredPageTopLeftInViewport);

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
    notifyListeners();
  }

  void translate(Offset deltaInScreenSpace) {
    PageListViewportLogs.pagesListController.fine("Translation requested for delta: $deltaInScreenSpace");
    final desiredOrigin = _origin + deltaInScreenSpace;
    PageListViewportLogs.pagesListController.fine(
        "Origin before adjustment: $_origin. Content height: ${_viewport!.calculateContentHeight(scale)}, Scale: $scale");
    PageListViewportLogs.pagesListController
        .fine("Viewport size: ${_viewport!.size}, scaled page width: ${_viewport!.calculatePageWidth(scale)}");
    _origin = _constrainOriginToViewportBounds(desiredOrigin);

    notifyListeners();
  }

  void setScale(double newScale, Offset focalPointInViewport) {
    assert(newScale > 0.0);
    PageListViewportLogs.pagesListController
        .fine("Scale requested with desired scale: $newScale, min scale: $_minimumScale");
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
    PageListViewportLogs.pagesListController.fine("Setting scale to $newScale");
    _scale = newScale;

    notifyListeners();
  }

  Offset _constrainOriginToViewportBounds(Offset desiredOrigin) {
    final totalContentHeight = _viewport!.calculateContentHeight(scale);
    if (totalContentHeight >= _viewport!.size.height) {
      // Content is as tall, or taller than the viewport.
      return Offset(
        desiredOrigin.dx.clamp(_viewport!.size.width - _viewport!.calculatePageWidth(scale), 0.0),
        desiredOrigin.dy.clamp(-_viewport!.calculateContentHeight(scale) + _viewport!.size.height, 0.0),
      );
    } else {
      // Content is shorter than the viewport.
      return Offset(
        desiredOrigin.dx.clamp(_viewport!.size.width - _viewport!.calculatePageWidth(scale), 0.0),
        (_viewport!.size.height - totalContentHeight) / 2,
      );
    }
  }
}

class RenderPageListViewport extends RenderBox {
  RenderPageListViewport({
    required PageListViewportElement element,
    required PageListViewportController controller,
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
    _controller?.removeListener(_onPanScrollOrZoom);
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

  double _minimumScaleToFillViewport = 1.0;

  double get _contentScale => max(_controller!.scale, _minimumScaleToFillViewport);

  Size get _scaledPageSize => _naturalPageSize * _contentScale;

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

  PageListViewportController? _controller;

  set controller(PageListViewportController newController) {
    if (_controller == newController) {
      return;
    }

    _controller?.removeListener(_onPanScrollOrZoom);
    _controller?.viewport = null;

    _controller = newController;
    _controller!.viewport = this;
    _controller!.addListener(_onPanScrollOrZoom);

    _isFirstLayoutForController = true;

    markNeedsLayout();
  }

  // Whether the next layout phase will be the first layout phase
  // applied to the attached controller. We track this information
  // so that we can force the controller to scale exactly to the
  // width of the viewport when the controller is first attached.
  bool _isFirstLayoutForController = true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  ClipRectLayer? get layer => super.layer as ClipRectLayer?;

  @override
  set layer(ContainerLayer? newLayer) => super.layer = newLayer as ClipRectLayer?;

  @override
  void attach(PipelineOwner owner) {
    PageListViewportLogs.pagesList.finest("attach()'ing viewport render object to pipeline");
    super.attach(owner);

    visitChildren((child) {
      child.attach(owner);
    });
  }

  @override
  void detach() {
    PageListViewportLogs.pagesList.finest("detach()'ing viewport render object from pipeline");
    // IMPORTANT: we must detach ourselves before detaching our children.
    // This is a Flutter framework requirement.
    super.detach();

    // Detach our children.
    visitChildren((child) {
      child.detach();
    });
  }

  void _onPanScrollOrZoom() {
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

    _minimumScaleToFillViewport = size.width / _naturalPageSize.width;
    _controller!._minimumScale = _minimumScaleToFillViewport;
    if (_isFirstLayoutForController && _pageCount > 0) {
      _controller!._scale = _minimumScaleToFillViewport;

      final totalContentHeight = calculateContentHeight(_controller!._scale);
      if (totalContentHeight < size.height) {
        // We don't have enough content to fill the viewport. Center the content, vertically.
        _controller!._origin = Offset(
          _controller!._origin.dx,
          (size.height - totalContentHeight) / 2,
        );
      }

      _isFirstLayoutForController = false;
    }

    // TODO: optimization - deactivate all elements no longer in cache range
    _buildVisibleAndCachedChildren();

    final pageSize = Size(
      calculatePageWidth(_controller!._scale),
      calculatePageHeight(_controller!._scale),
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
      PageListViewportLogs.pagesList.finest("Laying out child (at $pageIndex): $child");
      child.layout(BoxConstraints.tight(pageSize), parentUsesSize: true);
      PageListViewportLogs.pagesList.finest(" - child size: ${child.size}");
    });
  }

  // This page list needs to build and layout any pages that should
  // be visible in the viewport. It also needs to build and layout
  // any pages that sit near the viewport (based on our cache policy).
  //
  // This method finds any relevant pages that have yet to be built,
  // and then builds those pages, and adds their new `RenderObject`s
  // as children.
  void _buildVisibleAndCachedChildren() {
    _visitLayoutChildren((pageIndex, childElement) {
      if (childElement == null) {
        // We call invokeLayoutCallback() because that's the only way we're
        // allowed to adopt children during layout.
        invokeLayoutCallback((constraints) {
          _element!.createPage(pageIndex);
        });
      }
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

    return didHitChild;
  }

  void _visitLayoutChildren(Function(int pageIndex, Element? childElement) visitor) {
    final firstPageIndexToLayout = max(_findFirstVisiblePageIndex()! - _pageLayoutCacheCount, 0);
    final lastPageIndexToLayout = min(_findLastVisiblePageIndex()! + _pageLayoutCacheCount, _pageCount - 1);
    for (int pageIndex = firstPageIndexToLayout; pageIndex <= lastPageIndexToLayout; pageIndex += 1) {
      visitor(pageIndex, _element!._childElements[pageIndex]);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final childElements = _element!._childElements;
    final firstPageToPaintIndex = max(_findFirstVisiblePageIndex()! - _pagePaintCacheCount, 0);
    final lastPageToPaintIndex = min(_findLastVisiblePageIndex()! + _pagePaintCacheCount, _pageCount - 1);

    PageListViewportLogs.pagesList.finest("Painting children at scale: $_contentScale");

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
    PageListViewportLogs.pagesList.finest("Done with viewport paint");
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

  int? _findFirstVisiblePageIndex() {
    return _controller!.origin.dy.abs() ~/ _scaledPageSize.height;
  }

  int? _findLastVisiblePageIndex() {
    return (_controller!.origin.dy.abs() + size.height) ~/ _scaledPageSize.height;
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
    PageListViewportLogs.pagesList.finest("update() on element");
    super.update(newWidget);

    if (Widget.canUpdate(widget, newWidget)) {
      performRebuild();
    }
  }

  @override
  Element? updateChild(Element? child, Widget? newWidget, Object? newSlot) {
    PageListViewportLogs.pagesList.finest("updateChild(): $newWidget");
    return super.updateChild(child, newWidget, newSlot);
  }

  @override
  void performRebuild() {
    PageListViewportLogs.pagesList.finest("performRebuild()");
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

  @override
  void insertRenderObjectChild(RenderObject child, Object? slot) {
    PageListViewportLogs.pagesList.finest("Viewport adopting render object child: $child");
    renderObject.adoptChild(child);
  }

  @override
  void moveRenderObjectChild(RenderObject child, Object? oldSlot, Object? newSlot) {
    // no-op
  }

  @override
  void removeRenderObjectChild(RenderObject child, Object? slot) {
    PageListViewportLogs.pagesList
        .finest("removeRenderObjectChild() - child: $child, slot: $slot, is attached? ${child.attached}");
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

/// Controls a [PageListViewportController] with scale gestures to pan and zoom the
/// associated [PageListViewport].
class PageListViewportGestures extends StatefulWidget {
  const PageListViewportGestures({
    Key? key,
    required this.controller,
    this.onTapUp,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onDoubleTapDown,
    this.onDoubleTap,
    this.onDoubleTapCancel,
    this.clock = const Clock(),
    required this.child,
  }) : super(key: key);

  final PageListViewportController controller;

  // All of these methods were added because our client needs to
  // respond to them, and we internally respond to other gestures.
  // Flutter won't let gestures pass from parent to child, so we're
  // forced to expose all of these callbacks so that our client can
  // hook into them.
  final void Function(TapUpDetails)? onTapUp;
  final void Function(LongPressStartDetails)? onLongPressStart;
  final void Function(LongPressMoveUpdateDetails)? onLongPressMoveUpdate;
  final void Function(LongPressEndDetails)? onLongPressEnd;
  final void Function(TapDownDetails)? onDoubleTapDown;
  final void Function()? onDoubleTap;
  final void Function()? onDoubleTapCancel;

  /// Reports the time, so that the gesture system can track how much
  /// time has passed.
  ///
  /// [clock] is configurable so that a fake version can be injected
  /// in tests.
  final Clock clock;

  final Widget child;

  @override
  State<PageListViewportGestures> createState() => _PageListViewportGesturesState();
}

class _PageListViewportGesturesState extends State<PageListViewportGestures> with TickerProviderStateMixin {
  bool _isPanningEnabled = true;
  bool _isPanning = false;

  late PanAndScaleVelocityTracker _panAndScaleVelocityTracker;
  double? _startContentScale;
  Offset? _startOffset;
  int? _endTimeInMillis;
  late Ticker _ticker;
  PanningFrictionSimulation? _frictionSimulation;

  @override
  void initState() {
    super.initState();
    _panAndScaleVelocityTracker = PanAndScaleVelocityTracker(clock: widget.clock);
    _ticker = createTicker(_onFrictionTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.stylus) {
      _isPanningEnabled = false;
    }

    // Stop any on-going friction simulation.
    _stopMomentum();
  }

  void _onPointerUp(PointerUpEvent event) {
    _isPanningEnabled = true;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _isPanningEnabled = true;
  }

  void _onScaleStart(ScaleStartDetails details) {
    PageListViewportLogs.pagesListGestures.finer("onScaleStart()");
    if (!_isPanningEnabled) {
      // The user is interacting with a stylus. We don't want to pan
      // or scale with a stylus.
      return;
    }

    _isPanning = true;

    final timeSinceLastGesture = _endTimeInMillis != null ? _timeSinceEndOfLastGesture : null;
    _startContentScale = widget.controller.scale;
    _startOffset = widget.controller.origin;

    _panAndScaleVelocityTracker.onScaleStart(details);

    if ((timeSinceLastGesture == null || timeSinceLastGesture > const Duration(milliseconds: 30))) {
      // We've started a new gesture after a reasonable period of time since the
      // last gesture. Stop any momentum from the last gesture.
      _stopMomentum();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    PageListViewportLogs.pagesList
        .finer("onScaleUpdate() - new focal point ${details.focalPoint}, focal delta: ${details.focalPointDelta}");
    if (!_isPanning) {
      // The user is interacting with a stylus. We don't want to pan
      // or scale with a stylus.
      return;
    }

    if (!_isPanningEnabled) {
      PageListViewportLogs.pagesListGestures.finer("Started panning when the stylus was down. Resetting transform to:");
      PageListViewportLogs.pagesListGestures.finer(" - origin: ${widget.controller.origin}");
      PageListViewportLogs.pagesListGestures.finer(" - scale: ${widget.controller.scale}");

      _isPanning = false;

      // When this condition is triggered, _startOffset and _startContentScale
      // should be non-null. But sometimes they are null. I don't know why. When that
      // happens, return.
      if (_startOffset == null || _startContentScale == null) {
        return;
      }

      widget.controller
        ..setScale(_startContentScale!, details.focalPoint)
        ..translate(_startOffset! - widget.controller.origin);
      return;
    }

    _panAndScaleVelocityTracker.onScaleUpdate(details);

    widget.controller //
      ..setScale(details.scale * _startContentScale!, details.localFocalPoint)
      ..translate(details.focalPointDelta);
    PageListViewportLogs.pagesListGestures
        .finer("New origin: ${widget.controller.origin}, scale: ${widget.controller.scale}");
  }

  void _onScaleEnd(ScaleEndDetails details) {
    PageListViewportLogs.pagesListGestures.finer("onScaleEnd()");
    if (!_isPanning) {
      return;
    }

    _panAndScaleVelocityTracker.onScaleEnd(details);

    if (details.pointerCount == 0) {
      _startMomentum();
      _isPanning = false;
    }
  }

  Duration get _timeSinceEndOfLastGesture => Duration(milliseconds: widget.clock.millis - _endTimeInMillis!);

  void _startMomentum() {
    PageListViewportLogs.pagesListGestures.fine("Starting momentum...");
    final velocity = _panAndScaleVelocityTracker.velocity;
    PageListViewportLogs.pagesListGestures.fine("Starting momentum with velocity: $velocity");

    _frictionSimulation = PanningFrictionSimulation(
      position: widget.controller.origin,
      velocity: velocity,
    );

    if (!_ticker.isTicking) {
      _ticker.start();
    }
  }

  void _stopMomentum() {
    if (_ticker.isTicking) {
      _ticker.stop();
    }
  }

  void _onFrictionTick(Duration elapsedTime) {
    if (elapsedTime == Duration.zero) {
      return;
    }

    final secondsFraction = elapsedTime.inMilliseconds / 1000;
    final currentVelocity = _frictionSimulation!.dx(secondsFraction);
    final originBeforeDelta = widget.controller.origin;
    final newOrigin = _frictionSimulation!.x(secondsFraction);
    final translate = newOrigin - originBeforeDelta;

    PageListViewportLogs.pagesListGestures.finest(
        "Friction tick. Time: ${elapsedTime.inMilliseconds}ms. Velocity: $currentVelocity. Movement: $translate");

    widget.controller.translate(translate);

    PageListViewportLogs.pagesListGestures.finest("New origin: $newOrigin");

    // If the viewport hit a wall, or if the simulations are done, stop
    // ticking.
    if (originBeforeDelta == widget.controller.origin || _frictionSimulation!.isDone(secondsFraction)) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Listen for finger-down in a Listener so that we have zero
      // latency when stopping a friction simulation. Also, track when
      // a stylus is used, so we can prevent panning.
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        onTapUp: widget.onTapUp,
        onLongPressStart: widget.onLongPressStart,
        onLongPressMoveUpdate: widget.onLongPressMoveUpdate,
        onLongPressEnd: widget.onLongPressEnd,
        onDoubleTapDown: widget.onDoubleTapDown,
        onDoubleTap: widget.onDoubleTap,
        onDoubleTapCancel: widget.onDoubleTapCancel,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: widget.child,
      ),
    );
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
  _PanAndScaleGestureAction? _currentGestureStartAction;
  bool _isPossibleGestureContinuation = false;

  Offset get velocity => _launchVelocity;
  Offset _launchVelocity = Offset.zero;

  void onScaleStart(ScaleStartDetails details) {
    PageListViewportLogs.pagesListGestures.fine(
        "onScaleStart() - pointer count: ${details.pointerCount}, time since last gesture: ${_timeSinceLastGesture?.inMilliseconds}ms");

    if (_previousPointerCount == 0) {
      _currentGestureStartAction = _PanAndScaleGestureAction.firstFingerDown;
    } else if (details.pointerCount > _previousPointerCount) {
      // This situation might signify:
      //
      //  1. The user is trying to place 2 fingers on the screen and the 2nd finger
      //     just touched down.
      //
      //  2. The user was panning with 1 finger and just added a 2nd finger to start
      //     scaling.
      _currentGestureStartAction = _PanAndScaleGestureAction.addFinger;
    } else if (details.pointerCount == 0) {
      _currentGestureStartAction = _PanAndScaleGestureAction.removeLastFinger;
    } else {
      // This situation might signify:
      //
      //  1. The user is trying to remove 2 fingers from the screen and the 1st finger
      //     just lifted off.
      //
      //  2. The user was scaling with 2 fingers and just removed 1 finger to start
      //     panning instead of scaling.
      _currentGestureStartAction = _PanAndScaleGestureAction.removeNonLastFinger;
    }
    PageListViewportLogs.pagesListGestures.fine(" - start action: $_currentGestureStartAction");
    _currentGestureStartTimeInMillis = _clock.millis;

    if (_timeSinceLastGesture != null && _timeSinceLastGesture! < const Duration(milliseconds: 30)) {
      PageListViewportLogs.pagesListGestures.fine(
          " - this gesture started really fast. Assuming that this is a continuation. Previous pointer count: $_previousPointerCount. Current pointer count: ${details.pointerCount}");
      _isPossibleGestureContinuation = true;
    } else {
      PageListViewportLogs.pagesListGestures.fine(" - restarting velocity for new gesture");
      _isPossibleGestureContinuation = false;
      _previousGesturePointerCount = details.pointerCount;
      _launchVelocity = Offset.zero;
    }

    _previousPointerCount = details.pointerCount;
  }

  void onScaleUpdate(ScaleUpdateDetails details) {
    PageListViewportLogs.pagesListGestures.fine("Scale update: ${details.localFocalPoint}");

    if (_isPossibleGestureContinuation) {
      if (_timeSinceStartOfGesture < const Duration(milliseconds: 24)) {
        PageListViewportLogs.pagesListGestures.fine(" - this gesture is a continuation. Ignoring update.");
        return;
      }

      // Enough time has passed for us to conclude that this gesture isn't just
      // an intermediate moment as the user adds or removes fingers. This gesture
      // is intentional, and we need to track its velocity.
      PageListViewportLogs.pagesListGestures
          .fine(" - a possible gesture continuation has been confirmed as a new gesture. Restarting velocity.");
      _currentGestureStartTimeInMillis = _clock.millis;
      _previousGesturePointerCount = details.pointerCount;
      _launchVelocity = Offset.zero;

      _isPossibleGestureContinuation = false;
    }
  }

  void onScaleEnd(ScaleEndDetails details) {
    final gestureDuration = Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);
    PageListViewportLogs.pagesListGestures.fine("onScaleEnd() - gesture duration: ${gestureDuration.inMilliseconds}");

    _previousGestureEndTimeInMillis = _clock.millis;
    _previousPointerCount = details.pointerCount;
    _currentGestureStartAction = null;
    _currentGestureStartTimeInMillis = null;

    if (_isPossibleGestureContinuation) {
      PageListViewportLogs.pagesListGestures.fine(" - this gesture is a continuation of a previous gesture.");
      if (details.pointerCount > 0) {
        PageListViewportLogs.pagesListGestures.fine(
            " - this continuation gesture still has fingers touching the screen. The end of this gesture means nothing for the velocity.");
        return;
      } else {
        PageListViewportLogs.pagesListGestures.fine(
            " - the user just removed the final finger. Using launch velocity from previous gesture: $_launchVelocity");
        return;
      }
    }

    if (gestureDuration < const Duration(milliseconds: 40)) {
      PageListViewportLogs.pagesListGestures.fine(" - this gesture was too short to count. Ignoring.");
      return;
    }

    if (_previousGesturePointerCount! > 1) {
      // The user was scaling. Now the user is panning. We don't want scale
      // gestures to contribute momentum, so we set the launch velocity to zero.
      // If the panning continues long enough, then we'll use the panning
      // velocity for momentum.
      PageListViewportLogs.pagesListGestures
          .fine(" - this gesture was a scale gesture and user switched to panning. Resetting launch velocity.");
      _launchVelocity = Offset.zero;
      return;
    }

    if (details.pointerCount > 0) {
      PageListViewportLogs.pagesListGestures
          .fine(" - the user removed a finger, but is still interacting. Storing velocity for later.");
      PageListViewportLogs.pagesListGestures
          .fine(" - stored velocity: $_launchVelocity, magnitude: ${_launchVelocity.distance}");
      return;
    }

    _launchVelocity = details.velocity.pixelsPerSecond;
    PageListViewportLogs.pagesListGestures
        .fine(" - the user has completely stopped interacting. Launch velocity is: $_launchVelocity");
  }

  Duration get _timeSinceStartOfGesture => Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);

  Duration? get _timeSinceLastGesture => _previousGestureEndTimeInMillis != null
      ? Duration(milliseconds: _clock.millis - _previousGestureEndTimeInMillis!)
      : null;
}

enum _PanAndScaleGestureAction {
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

class PanningFrictionSimulation {
  PanningFrictionSimulation({
    required Offset position,
    required Offset velocity,
  })  : _position = position,
        _velocity = velocity {
    _xSimulation = ClampingScrollSimulation(
        position: _position.dx, velocity: _velocity.dx, tolerance: const Tolerance(velocity: 0.001));
    _ySimulation = ClampingScrollSimulation(
        position: _position.dy, velocity: _velocity.dy, tolerance: const Tolerance(velocity: 0.001));
  }

  final Offset _position;
  final Offset _velocity;
  late final ClampingScrollSimulation _xSimulation;
  late final ClampingScrollSimulation _ySimulation;

  Offset x(double time) {
    return Offset(
      _xSimulation.x(time),
      _ySimulation.x(time),
    );
  }

  Offset dx(double time) {
    return Offset(
      _xSimulation.dx(time),
      _ySimulation.dx(time),
    );
  }

  bool isDone(double time) => _xSimulation.isDone(time) && _ySimulation.isDone(time);
}
