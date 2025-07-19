import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

/// A viewport that displays [pageCount] pages of content, arranged in a vertical.
///
/// Each page can have its own natural page size, which is determined by [onGetNaturalPageSize].
///
/// {@macro page_list_viewport}
class PageListViewportWithVariablePageSize extends RenderObjectWidget {
  const PageListViewportWithVariablePageSize({
    super.key,
    required this.controller,
    required this.pageCount,
    required this.onGetNaturalPageSize,
    this.pageLayoutCacheCount = 0,
    this.pagePaintCacheCount = 0,
    required this.builder,
    this.rebuildOnOrientationChange = false,
  }) : assert(pageLayoutCacheCount >= pagePaintCacheCount);

  /// Controller that pans and zooms the page content.
  final PageListViewportWithVariableSizeController controller;

  /// The number of pages displayed in this viewport.
  final int pageCount;

  /// The size of a single page, if no constraints were applied.
  final PageSizeResolver onGetNaturalPageSize;

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
    return PageListViewportWithVariableSizeElement(this);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    PageListViewportLogs.pagesList.finest(() => "Creating PageListViewport render object");
    return RenderPageListVariableSizeViewport(
      element: context as PageListViewportWithVariableSizeElement,
      controller: controller,
      pageCount: pageCount,
      pageSizeResolver: onGetNaturalPageSize,
      pageLayoutCacheCount: pageLayoutCacheCount,
      pagePaintCacheCount: pagePaintCacheCount,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderPageListVariableSizeViewport renderObject) {
    PageListViewportLogs.pagesList.finest(() => "Updating PageListViewport render object");
    renderObject //
      ..pageCount = pageCount
      ..pageSizeResolver = onGetNaturalPageSize
      ..pageLayoutCacheCount = pageLayoutCacheCount
      ..pagePaintCacheCount = pagePaintCacheCount
      ..controller = controller;
  }
}

class RenderPageListVariableSizeViewport extends RenderBox implements PageListViewportLayout {
  RenderPageListVariableSizeViewport({
    required PageListViewportWithVariableSizeElement element,
    required OrientationController controller,
    required int pageCount,
    PageSizeResolver? pageSizeResolver,
    int pageLayoutCacheCount = 0,
    int pagePaintCacheCount = 0,
  })  : _element = element,
        _pageCount = pageCount,
        _pageSizeResolver = pageSizeResolver,
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

  PageListViewportWithVariableSizeElement? _element;
  int _pageCount;

  set pageCount(int newCount) {
    if (newCount == _pageCount) {
      return;
    }

    _pageCount = newCount;
    markNeedsLayout();
  }

  PageSizeResolver? _pageSizeResolver;
  set pageSizeResolver(PageSizeResolver? newPageSizeResolver) {
    if (newPageSizeResolver == _pageSizeResolver) {
      return;
    }

    _pageSizeResolver = newPageSizeResolver;
    markNeedsLayout();
  }

  @override
  Size getNaturalPageSize(int pageIndex) => _pageSizeResolver!(pageIndex);

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
    // ignore: invalid_use_of_protected_member
    _controller?.viewport = null;

    _controller = newController;
    // ignore: invalid_use_of_protected_member
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

  /// The baseline scale for each page, which is the ratio of the viewport width to the natural page width.
  ///
  /// This is the scale needed for each page to fill the viewport horizontally.
  final _pageBaselineScales = <double>[];

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

  @override
  Size calculatePageSize(int pageIndex, double scale) =>
      getNaturalPageSize(pageIndex) * scale * _pageBaselineScales[pageIndex];

  @override
  double calculateContentHeight(double scale) {
    double totalContentHeight = 0.0;
    for (int i = 0; i < _pageCount; i++) {
      totalContentHeight += calculatePageSize(i, scale).height;
    }
    return totalContentHeight;
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    if (size.width == 0) {
      // Our content calculations depend on a non-zero width. If we have no width, there's
      // nothing to layout or paint anyway. Bail out now and avoid adding code to account
      // for zero width.
      return;
    }

    // First we need to calculate the baseline scale for each page. Since the page sizes can vary,
    // to determine the first visible page, we need to know the scaled size of each page.
    _pageBaselineScales.clear();
    for (int i = 0; i < _pageCount; i++) {
      final pageBaselineScale = size.width / getNaturalPageSize(i).width;
      _pageBaselineScales.add(pageBaselineScale);
    }

    // We must let the controller do its layout work before we create and cull the pages,
    // because the controller might change the offset of the viewport.
    // ignore: invalid_use_of_protected_member
    _controller!.onViewportLayout();

    _createAndCullVisibleAndCachedPages();

    Offset offset = Offset.zero;

    // Layout the visible and cached pages.
    _visitLayoutChildren((pageIndex, childElement) {
      if (childElement == null) {
        return;
      }

      final pageSize = calculatePageSize(pageIndex, _controller!.scale);

      final child = childElement.renderObject! as RenderBox;
      final pageParentData = child.parentData as ViewportPageParentData;
      pageParentData
        ..viewportSize = size
        ..pageIndex = pageIndex
        ..offset = offset;

      offset += Offset(0, pageSize.height);
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

          //final pageOriginVec = transform.transform3(Vector3(0, 0, 0));
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

    double dy = 0;
    for (int i = 0; i < pageIndex; i++) {
      dy += calculatePageSize(i, _controller!.scale).height;
    }

    final pageOrigin = Offset(
      _controller!.origin.dx,
      _controller!.origin.dy + dy,
    );
    transform.translate(pageOrigin.dx, pageOrigin.dy);
  }

  int _findFirstVisiblePageIndex() {
    return _findFirstVisiblePageAtY(_controller!.origin.dy.abs());
  }

  int _findLastVisiblePageIndex() {
    return _findFirstVisiblePageAtY(_controller!.origin.dy.abs() + size.height);
  }

  int _findFirstVisiblePageAtY(double y) {
    double currentContentHeight = 0.0;
    int index = 0;
    while (index < _pageCount) {
      final pageHeight = calculatePageSize(index, _controller!.scale).height;
      currentContentHeight += pageHeight;

      if (currentContentHeight >= y) {
        break;
      }

      index += 1;
    }

    return index;
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

  @override
  int getPageCount() => _pageCount;

  @override
  Size getSize() => size;
}

class PageListViewportWithVariableSizeElement extends RenderObjectElement {
  PageListViewportWithVariableSizeElement(super.widget);

  bool get hasChildren => _childElements.isNotEmpty;

  int get childCount => _childElements.length;

  final SplayTreeMap<int, Element?> _childElements = SplayTreeMap<int, Element?>();

  @override
  RenderPageListVariableSizeViewport get renderObject => super.renderObject as RenderPageListVariableSizeViewport;

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
    final pageListViewport = widget as PageListViewportWithVariablePageSize;
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
          (widget as PageListViewportWithVariablePageSize).builder(this, pageIndex),
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
    // ignore: invalid_use_of_protected_member
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
    // ignore: invalid_use_of_protected_member
    renderObject.dropChild(child);
  }
}

class ViewportPageWithVariableSizeParentData extends ContainerBoxParentData<RenderBox>
    with ContainerParentDataMixin<RenderBox> {
  ViewportPageWithVariableSizeParentData({
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

class PageListViewportWithVariableSizeController extends OrientationController {
  PageListViewportWithVariableSizeController.startAtPage({
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

  PageListViewportWithVariableSizeController({
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
  PageListViewportLayout? get viewport => _viewport;

  PageListViewportLayout? _viewport;

  /// Sets the [RenderPageListViewport] whose content transform is controlled
  /// by this controller.
  ///
  /// A connection to the viewport is needed to ensure that content doesn't
  /// move or scale in ways that violates the viewport's constraints, such as
  /// making the content smaller than the viewport.
  @override
  @protected
  set viewport(PageListViewportLayout? viewport) {
    if (_viewport == viewport) {
      return;
    }

    _viewport = viewport;

    // Stop any on-going orientation animation because we received a new viewport.
    _animationController.stop();
    stopSimulation();
  }

  Size? get _viewportSize => _viewport?.getSize();

  bool _isFirstLayoutForController = true;

  @override
  bool get isRunningOrientationSimulation => _activeSimulation != null;
  OrientationSimulation? _activeSimulation;
  Ticker? _simulationTicker;
  Duration? _previousSimulationTime;
  AxisAlignedOrientation? _previousSimulationOrientation;

  @override
  @protected
  void onViewportLayout() {
    disableNotifications();

    final viewportSize = _viewportSize!;

    if (_isFirstLayoutForController && _viewport!.getPageCount() > 0) {
      // 1.0 means we want to use the page's baseline scale, which will make it
      // fill the available width.
      scale = 1.0;

      final totalContentHeight = _viewport!.calculateContentHeight(scale);
      if (totalContentHeight < viewportSize.height) {
        // We don't have enough content to fill the viewport. Center the content, vertically.
        origin = Offset(
          origin.dx,
          (viewportSize.height - totalContentHeight) / 2,
        );
      }

      _isFirstLayoutForController = false;
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

    // Since each page can have its own size, to determine the offset we need to
    // comput the page size for each page above the desired page index.
    double contentAboveDesiredPage = 0.0;
    for (int i = 0; i < pageIndex; i++) {
      final pageSizeAtZoomLevel = _viewport!.calculatePageSize(i, desiredZoomLevel);
      contentAboveDesiredPage += pageSizeAtZoomLevel.height;
    }

    final pageSizeAtZoomLevel = _viewport!.calculatePageSize(pageIndex, desiredZoomLevel);
    final desiredPageTopLeftInViewport =
        (_viewportSize!).center(Offset.zero) - Offset(pageSizeAtZoomLevel.width / 2, pageSizeAtZoomLevel.height / 2);

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

    double contentAboveDesiredPage = 0.0;
    for (int i = 0; i < pageIndex; i++) {
      final pageSizeAtZoomLevel = _viewport!.calculatePageSize(i, desiredZoomLevel);
      contentAboveDesiredPage += pageSizeAtZoomLevel.height;
    }

    final pageFocalPointAtZoomLevel = pixelOffsetInPage * desiredZoomLevel;
    final desiredPageTopLeftInViewport = (_viewportSize!).center(-pageFocalPointAtZoomLevel);
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

    final centerOfPage = _viewport!.calculatePageSize(pageIndex, 1.0).center(Offset.zero);
    return animateToOffsetInPage(
      pageIndex,
      centerOfPage,
      duration,
      applyDurationPerPage: applyDurationPerPage,
      zoomLevel: zoomLevel,
      curve: curve,
    );
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

    double contentAboveDesiredPage = 0.0;
    for (int i = 0; i < pageIndex; i++) {
      final pageSizeAtZoomLevel = _viewport!.calculatePageSize(i, desiredZoomLevel);
      contentAboveDesiredPage += pageSizeAtZoomLevel.height;
    }

    final pageFocalPointAtZoomLevel = pixelOffsetInPage * desiredZoomLevel;
    final desiredPageTopLeftInViewport = (_viewportSize!).center(-pageFocalPointAtZoomLevel);
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

    Duration animationDuration = duration;
    if (applyDurationPerPage) {
      // Since we want to apply the duration per page, we need to find out how many pages
      // are between the current first visible page and the new first visible page.
      final currentFirstVisiblePageIndex = _findFirstVisiblePageAtY(_origin.dy.abs());
      final newFirstVisiblePageIndex = _findFirstVisiblePageAtY(destinationOffset.dy.abs());
      final pageCount = (newFirstVisiblePageIndex - currentFirstVisiblePageIndex).abs() + 1;

      animationDuration *= pageCount;
    }

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

  @override
  void translate(Offset deltaInScreenSpace) {
    PageListViewportLogs.pagesListController.fine(() => "Translation requested for delta: $deltaInScreenSpace");
    final desiredOrigin = _origin + deltaInScreenSpace;
    PageListViewportLogs.pagesListController.fine(() =>
        "Origin before adjustment: $_origin. Content height: ${_viewport!.calculateContentHeight(scale)}, Scale: $scale");
    PageListViewportLogs.pagesListController.fine(() => "Viewport size: ${_viewport!.getSize()}");

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

  @override
  void setScale(double newScale, Offset focalPointInViewport) {
    assert(newScale > 0.0);
    PageListViewportLogs.pagesListController
        .fine(() => "Scale requested with desired scale: $newScale, min scale: $_minimumScale");

    // Stop any on-going orientation animation so that we honor the desired scale.
    _animationController.stop();
    stopSimulation();

    // The scale cannot be less than 1.0, otherwise the content won't fill the viewport's width.
    newScale = newScale.clamp(math.max(_minimumScale, 1.0).toDouble(), maximumScale);

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
  @override
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
  @override
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

    final contentWidth = _viewport!.calculatePageSize(0, scale).width;
    final contentHeight = _viewport!.calculateContentHeight(scale);
    final viewportSize = _viewport!.getSize();

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

  int _findFirstVisiblePageAtY(double y) {
    double currentContentHeight = 0.0;
    int index = 0;
    final pageCount = _viewport!.getPageCount();
    while (index < pageCount) {
      final pageHeight = _viewport!.calculatePageSize(index, scale).height;
      currentContentHeight += pageHeight;

      if (currentContentHeight >= y) {
        break;
      }

      index += 1;
    }

    return index;
  }
}

/// A method that returns the size of a page at the given [pageIndex].
typedef PageSizeResolver = Size Function(int pageIndex);
