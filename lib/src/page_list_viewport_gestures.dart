import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'logging.dart';
import 'page_list_viewport.dart';

// packages for the friction simulation and gesture denial
import 'dart:collection';
import 'dart:math' as math;

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
    this.lockPanAxis = false,
    this.panAndZoomPointerDevices = const {
      PointerDeviceKind.mouse,
      PointerDeviceKind.trackpad,
      PointerDeviceKind.touch,
    },
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

  /// The set of [PointerDeviceKind] the gesture detector should detect.
  /// Any pointers not defined within the set will be ignored.
  final Set<PointerDeviceKind> panAndZoomPointerDevices;

  /// Whether the user should be locked into horizontal or vertical scrolling,
  /// when the user pans roughly in those directions.
  ///
  /// When the user drags near 45 degrees, the user retains full pan control.
  final bool lockPanAxis;

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

  bool _hasChosenWhetherToLock = false;
  bool _isLockedHorizontal = false;
  bool _isLockedVertical = false;

  Offset? _panAndScaleFocalPoint; // Point where the current gesture began.

  late DeprecatedPanAndScaleVelocityTracker _panAndScaleVelocityTracker;
  double? _startContentScale;
  Offset? _startOffset;
  int? _endTimeInMillis;

  @override
  void initState() {
    super.initState();
    _panAndScaleVelocityTracker = DeprecatedPanAndScaleVelocityTracker(clock: widget.clock);
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
    PageListViewportLogs.pagesListGestures.finer(() => "onScaleStart()");
    if (!_isPanningEnabled) {
      // The user is interacting with a stylus. We don't want to pan
      // or scale with a stylus.
      return;
    }
    _isPanning = true;

    final timeSinceLastGesture = _endTimeInMillis != null ? _timeSinceEndOfLastGesture : null;
    _startContentScale = widget.controller.scale;
    _startOffset = widget.controller.origin;
    _panAndScaleFocalPoint = details.localFocalPoint;
    _panAndScaleVelocityTracker.onScaleStart(details);

    if ((timeSinceLastGesture == null || timeSinceLastGesture > const Duration(milliseconds: 30))) {
      // We've started a new gesture after a reasonable period of time since the
      // last gesture. Stop any momentum from the last gesture.
      _stopMomentum();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    PageListViewportLogs.pagesListGestures.finer(
        () => "onScaleUpdate() - new focal point ${details.focalPoint}, focal delta: ${details.focalPointDelta}");
    if (!_isPanning) {
      // The user is interacting with a stylus. We don't want to pan
      // or scale with a stylus.
      return;
    }

    if (!_isPanningEnabled) {
      PageListViewportLogs.pagesListGestures
          .finer(() => "Started panning when the stylus was down. Resetting transform to:");
      PageListViewportLogs.pagesListGestures.finer(() => " - origin: ${widget.controller.origin}");
      PageListViewportLogs.pagesListGestures.finer(() => " - scale: ${widget.controller.scale}");
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

    // Translate so that the same point in the scene is underneath the
    // focal point before and after the movement.
    Offset focalPointTranslation = details.localFocalPoint - _panAndScaleFocalPoint!;

    // (Maybe) Axis locking.
    _lockPanningAxisIfDesired(focalPointTranslation, details.pointerCount);
    focalPointTranslation = _restrictVectorToAxisIfDesired(focalPointTranslation);

    _panAndScaleFocalPoint = _panAndScaleFocalPoint! + focalPointTranslation;

    widget.controller //
      ..setScale(details.scale * _startContentScale!, _panAndScaleFocalPoint!)
      ..translate(focalPointTranslation);

    _panAndScaleVelocityTracker.onScaleUpdate(_panAndScaleFocalPoint!, details.pointerCount);

    PageListViewportLogs.pagesListGestures
        .finer(() => "New origin: ${widget.controller.origin}, scale: ${widget.controller.scale}");
  }

  void _lockPanningAxisIfDesired(Offset translation, int pointerCount) {
    if (_hasChosenWhetherToLock) {
      // We've already made our locking decision. Fizzle.
      return;
    }

    if (translation.distance < ViewportThresholdsAndScales.minAxisLockingTranslationDistance) {
      // The translation distance is not sufficiently large to be
      // considered. Small translations should cause panning in an arbitrary direction.
      // This translation distance filtering also filters out the artifacts of screen calibration, which are
      // characterized by random direction of reported translation and small tranlation distance.
      // Fizzle and wait for the next panning notification.
      return;
    }

    _hasChosenWhetherToLock = true;

    if (!widget.lockPanAxis) {
      // The developer explicitly requested no locked panning.
      return;
    }
    if (pointerCount > 1) {
      // We don't lock axis direction when scaling with 2 fingers.
      return;
    }

    // Choose to lock in a particular axis direction, or not.
    final movementAngle = translation.direction;
    final movementAnglePositive = movementAngle.abs();

    // Consider axis locking for vertical and horizontal axes.
    // Defined constant positive and negative deviation angles from the vertical (horizontal) are compared
    // with the reported angle of translation movement.
    // If the movement angle lays within the threshold, it is locked to the axis.
    if ((pi / 2 - ViewportThresholdsAndScales.verticalAxisLockAngle < movementAnglePositive) &&
        (movementAnglePositive < pi / 2 + ViewportThresholdsAndScales.verticalAxisLockAngle)) {
      PageListViewportLogs.pagesListGestures.finer(() => "Locking panning into vertical-only movement.");
      _isLockedVertical = true;
    } else if (movementAnglePositive < ViewportThresholdsAndScales.horizontalAxisLockAngle ||
        movementAnglePositive > pi - ViewportThresholdsAndScales.horizontalAxisLockAngle) {
      PageListViewportLogs.pagesListGestures.finer(() => "Locking panning into horizontal-only movement.");
      _isLockedHorizontal = true;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    PageListViewportLogs.pagesListGestures.finer(() => "onScaleEnd()");
    if (!_isPanning) {
      return;
    }

    final velocity = _restrictVectorToAxisIfDesired(details.velocity.pixelsPerSecond);
    _panAndScaleVelocityTracker.onScaleEnd(velocity, details.pointerCount);
    if (details.pointerCount == 0) {
      _startMomentum();
      _isPanning = false;
      _hasChosenWhetherToLock = false;
      _isLockedHorizontal = false;
      _isLockedVertical = false;
    }
  }

  /// (Maybe) Restricts a 2D vector to a single axis of motion, e.g., restricts a translation
  /// vector, or a velocity vector to just horizontal or vertical motion.
  ///
  /// Restriction is based on the current state of [_isLockedHorizontal] and [_isLockedVertical].
  Offset _restrictVectorToAxisIfDesired(Offset rawVector) {
    if (_isLockedHorizontal) {
      return Offset(rawVector.dx, 0.0);
    } else if (_isLockedVertical) {
      return Offset(0.0, rawVector.dy);
    } else {
      return rawVector;
    }
  }

  Duration get _timeSinceEndOfLastGesture => Duration(milliseconds: widget.clock.millis - _endTimeInMillis!);
  void _startMomentum() {
    PageListViewportLogs.pagesListGestures.fine(() => "Starting momentum...");
    final velocity = _panAndScaleVelocityTracker.velocity;
    final momentumSimulationInitialVelocityIncreaseScalar =
        _panAndScaleVelocityTracker.momentumSimulationInitialVelocityIncreaseScalar;
    final dragIncreaseScalar = _panAndScaleVelocityTracker.dragIncreaseScalar;
    PageListViewportLogs.pagesListGestures.fine(() => "Starting momentum with velocity: $velocity");

    final panningSimulation = BallisticPanningOrientationSimulation(
      initialOrientation: AxisAlignedOrientation(
        widget.controller.origin,
        widget.controller.scale,
      ),
      panningSimulation: PanningFrictionSimulation(
        position: widget.controller.origin,
        velocity: velocity,
        initialVelocityIncreaseScalar: momentumSimulationInitialVelocityIncreaseScalar,
        dragIncreaseScalar: dragIncreaseScalar,
      ),
    );
    widget.controller.driveWithSimulation(panningSimulation);
  }

  void _stopMomentum() {
    widget.controller.stopSimulation();
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
        supportedDevices: widget.panAndZoomPointerDevices,
        child: widget.child,
      ),
    );
  }
}

/// Statically defined class with double constant values which parametrize
/// charateristic translation distances and velocities.
///
/// Distances are tiny, small, and large.
/// Velocitys are slow, normal, and fast.
/// These parameters are used to more carefully define viewport behavior
/// across a variety of scrolling situations.
class ViewportThresholdsAndScales {
  /// Gesture translation and velocity scale definitions.
  /// Distances scale diagram:
  /// (0 ... "tiny" ... tinyDistanceMax] (... "small" ... SmallDistanceMax]( ... "large" ...
  static const double tinyDistanceMax = 3;
  static const double smallDistanceMax = 120.0;

  /// Velocities scale diagram:
  /// (0 ... "slow" ... slowVelocityMax] (... "normal" ... normalVelocityMax]( ... "fast" ...
  static const double slowVelocityMax = 300.0;
  static const double normalVelocityMax = 850.0;

  /// Minimal neccessary velocity for which a momentum simulation is launched
  static const double minSmallTranslationMomentumActivationVelocity = 120.0;

  /// Scalar values by which momentum simulation launch velocitys are multiplied
  /// for different reported gesture velocities
  static const double smallTranslationSlowVelocityIncreaseScalar = 0.5;
  static const double smallTranslationNormalVelocityIncreaseScalar = 0.6;
  static const double smallTranslationFastVelocityIncreaseScalar = 0.7;
  static const double largeTranslationNormalVelocityIncreaseScalar = 0.85;

  /// If a momentum simulation is launched diagonally (not locked to any axis)
  /// its launch velocity is increased by a scalar
  static const double diagonalLaunchVelocityIncreaseScalar = 0.7;

  /// Scalar by which the launch velocity of a regular momentum simulation is multiplied
  static const double defaultVelocityIncreaseScalar = 1.0;

  /// Scalar by which the drag coefficient of a momentum simulation is multiplied
  static const double defaultDragIncreaseScalar = 1.0;

  /// Minimal translation distance required for a gesture to be considered for axis locking.
  /// Note that this depends on the rate at which the gestures are sampled.
  static const double minAxisLockingTranslationDistance = 2.0;

  /// Angles for a gesture to be locked to an axis.
  static const double verticalAxisLockAngle = pi / 4;
  static const double horizontalAxisLockAngle = pi / 12;

  /// Scrolls which are repeated frequently and are in the same direction should cause the viewport
  /// to scroll faster and faster with each consequtive swiping input.
  ///
  /// This is called repeated swipe (or scroll) acceleration

  /// Maximal time between two scrolling gestures for them to be considered for viewport scrolling acceleration
  static const int timeBetweenRepeatedScrollGestures = 1000;
}

class DeprecatedPanAndScaleVelocityTracker {
  final _lastPositions = ListQueue<Offset>();

  DeprecatedPanAndScaleVelocityTracker({
    required Clock clock,
  }) : _clock = clock;

  final Clock _clock;

  int _previousPointerCount = 0;
  int? _previousGestureEndTimeInMillis;

  int? _currentGestureStartTimeInMillis;
  PanAndScaleGestureAction? _currentGestureStartAction;
  bool _isPossibleGestureContinuation = false;

  // Variables needed to keep track of repeated input scroll acceleration.
  // Repeated swipe acceleration is when the viewport moves faster then during
  // usual scrolls if the user swipes very frequently in the same direction.

  // Whether to consider the swipe for for repeated input acceleration
  bool _isPossibleRepeatedAcceleratedSwipe = false;

  // Whether the previous gesture ended up launching a scrolling momentum simulation.
  bool _previosLaunchedWithMomentum = true;

  // Number of repeated scrolling gestures already considered in the viewport acceleration.
  int _numberOfRepeatedAcceleratedSwipes = 0;

  // Velocity with which the prevous gesture which triggered the momentum simulation
  // was launched.
  Offset _previousLaunchVelocity = Offset.zero;

  Offset _launchVelocity = Offset.zero;
  Offset get velocity => _launchVelocity;

  // Scalar which multiplies the launch velocity in the momentum simulation.
  // The simulation will start at a faster velocity if this value is greater than 1.
  double _momentumSimulationInitialVelocityIncreaseScalar = 1.0;
  double get momentumSimulationInitialVelocityIncreaseScalar => _momentumSimulationInitialVelocityIncreaseScalar;

  // Scalar which multiplies the drag coefficient in the simulation.
  // The simulation will deccelerate faster with a higher drag coefficient.
  double _dragIncreaseScalar = 1.0;
  double get dragIncreaseScalar => _dragIncreaseScalar;

  /// The focal point when the gesture started.
  Offset _startFocalPosition = Offset.zero;

  /// The last focal point before the gesture ended
  Offset _lastFocalPosition = Offset.zero;

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
    } else if (_timeSinceLastGesture != null &&
        _timeSinceLastGesture! <
            Duration(milliseconds: ViewportThresholdsAndScales.timeBetweenRepeatedScrollGestures)) {
      // If the gesture is not a continued gesture, analyze if it can
      // be a repeated accelerated swipe.

      // If the previous gesture was a swipe, which triggered a momentum simulation
      // and it was in the y direction only, mark the gesture as potentially a repeated
      // acceleration swipe.
      if (_previosLaunchedWithMomentum &&
          // Scaling gestures cannot trigger acceleration of the viewport
          details.pointerCount == 1 &&
          !(_launchVelocity.dx.abs() > 0) &&
          _launchVelocity != Offset.zero) {
        // The gesture is strong enough to potentially accelerate the viewport faster than usual.
        _isPossibleRepeatedAcceleratedSwipe = true;
        _previousLaunchVelocity = _launchVelocity;
      }
    } else {
      PageListViewportLogs.pagesListGestures.fine(() => " - restarting velocity for new gesture");
      _isPossibleGestureContinuation = false;
      _isPossibleRepeatedAcceleratedSwipe = false;
      _launchVelocity = Offset.zero;
    }

    _previousPointerCount = details.pointerCount;
    _startFocalPosition = details.localFocalPoint;

    // Reinitialize the last position tracker every new gesture
    _lastPositions.clear();
    _lastPositions.addFirst(_startFocalPosition);
  }

  void onScaleUpdate(Offset localFocalPoint, int pointerCount) {
    // Update the queue tracking last positions
    if (_lastPositions.length > 3) {
      _lastPositions.removeFirst();
    }
    _lastPositions.addLast(localFocalPoint);

    PageListViewportLogs.pagesListGestures.fine(() => "Scale update: $localFocalPoint");

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
      _launchVelocity = Offset.zero;

      _isPossibleGestureContinuation = false;
    }

    _lastFocalPosition = localFocalPoint;
  }

  // Reset the variables tracking repeated swiping gestures.
  // Should be called after panning velocityTracker decides to return
  // and not launch a momentum simulation for a gesture.
  void _resetRepeatedAccelerationTracking() {
    _previosLaunchedWithMomentum = false;
    _numberOfRepeatedAcceleratedSwipes = 0;
    _isPossibleRepeatedAcceleratedSwipe = false;
    _launchVelocity = Offset.zero;
  }

  void onScaleEnd(Offset velocity, int pointerCount) {
    final gestureDuration = Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);
    PageListViewportLogs.pagesListGestures
        .fine(() => "onScaleEnd() - gesture duration: ${gestureDuration.inMilliseconds}");

    _previousGestureEndTimeInMillis = _clock.millis;
    _previousPointerCount = pointerCount;
    _currentGestureStartAction = null;
    _currentGestureStartTimeInMillis = null;

    if (_isPossibleGestureContinuation) {
      PageListViewportLogs.pagesListGestures.fine(() => " - this gesture is a continuation of a previous gesture.");
      if (pointerCount > 0) {
        PageListViewportLogs.pagesListGestures.fine(() =>
            " - this continuation gesture still has fingers touching the screen. The end of this gesture means nothing for the velocity.");
        return;
      } else {
        PageListViewportLogs.pagesListGestures.fine(() =>
            " - the user just removed the final finger. Using launch velocity from previous gesture: $_launchVelocity");
        return;
      }
    }

    if (_previousPointerCount > 1) {
      // The user was scaling. Now the user is panning. We don't want scale
      // gestures to contribute momentum, so we set the launch velocity to zero.
      // If the panning continues long enough, then we'll use the panning
      // velocity for momentum.
      PageListViewportLogs.pagesListGestures
          .fine(() => " - this gesture was a scale gesture and user switched to panning. Resetting launch velocity.");
      _launchVelocity = Offset.zero;
      return;
    }

    final translationDistance = (_lastFocalPosition - _startFocalPosition).distance;
    final velocityDistance = velocity.distance;

    // Set the default launch scrolling velocity scalar.
    // The scalar simply multiplies the launch velocity for the momentum simulation.
    _momentumSimulationInitialVelocityIncreaseScalar = ViewportThresholdsAndScales.defaultVelocityIncreaseScalar;

    // Set the default drag increase scalar.
    // The scalar simply multiplies the drag coefficient.
    _dragIncreaseScalar = ViewportThresholdsAndScales.defaultDragIncreaseScalar;

    // Judge the swiping gesture based on the length of the translation
    // and the velocity and either:
    // End the gesture at panning by resetting the accelerated scroll tracking settings and returning.
    // The swipe won't triger the momentum simulation.
    // OR
    // Proceed to initializing a momentum simulation for further motion.
    if (translationDistance < ViewportThresholdsAndScales.tinyDistanceMax) {
      // prevent momentum simulation for tiny scrolls
      _resetRepeatedAccelerationTracking();
      return;
    } else if (translationDistance < ViewportThresholdsAndScales.smallDistanceMax) {
      // Small or tiny translation, depending on the velocity decide whether to simulate momentum
      if (velocityDistance > ViewportThresholdsAndScales.normalVelocityMax) {
        // Small translation, fast velocity
        _momentumSimulationInitialVelocityIncreaseScalar =
            ViewportThresholdsAndScales.smallTranslationFastVelocityIncreaseScalar;
      } else if (velocityDistance > ViewportThresholdsAndScales.slowVelocityMax) {
        // Small translation, normal velocity
        _momentumSimulationInitialVelocityIncreaseScalar =
            ViewportThresholdsAndScales.smallTranslationNormalVelocityIncreaseScalar;
      } else if (velocityDistance > ViewportThresholdsAndScales.minSmallTranslationMomentumActivationVelocity) {
        // Small translation, slow velocity
        _momentumSimulationInitialVelocityIncreaseScalar =
            ViewportThresholdsAndScales.smallTranslationSlowVelocityIncreaseScalar;
      } else {
        // Small translation, velocity insufficient to launch a momentum simulation
        _resetRepeatedAccelerationTracking();
        return;
      }
    } else {
      // Large translation distance
      if (velocityDistance > ViewportThresholdsAndScales.normalVelocityMax) {
        // Large translation, fast velocity
      } else if (velocityDistance > ViewportThresholdsAndScales.slowVelocityMax) {
        _momentumSimulationInitialVelocityIncreaseScalar =
            ViewportThresholdsAndScales.largeTranslationNormalVelocityIncreaseScalar;
        // Large translation, normal velocity
      } else {
        // Large translation, slow velocity
        _resetRepeatedAccelerationTracking();
        return;
      }
    }

    // Solves the issue of reported random noise due to the uncalibrated touch sensor,
    // which happen usually at a finger halt.
    // The gesture is blocked if the reported gesture velocity is
    // in another direction to the previous tracked velocities.
    // The tracked velocities are collected using a circular buffer
    // storing the last 3 reported gesture offsets.
    if (_lastPositions.length >= ViewportThresholdsAndScales.minAxisLockingTranslationDistance) {
      // We need to have at least one translation in the buffer to compare to
      Offset oldTranslationVector = _lastPositions.elementAt(1) - _lastPositions.first;
      double scalarProduct = oldTranslationVector.dx * velocity.dx + oldTranslationVector.dy * velocity.dy;
      if (scalarProduct <= 0) {
        _resetRepeatedAccelerationTracking();
        return;
      }
    } else {
      // This gesture was short and we are not going to consider it for acceleration due to repeated swiping
      _resetRepeatedAccelerationTracking();
    }

    if (pointerCount > 0) {
      PageListViewportLogs.pagesListGestures
          .fine(() => " - the user removed a finger, but is still interacting. Storing velocity for later.");
      PageListViewportLogs.pagesListGestures
          .fine(() => " - stored velocity: $_launchVelocity, magnitude: ${_launchVelocity.distance}");
      return;
    }

    // Check that the two swipes consequtively considered for repeated
    // swiping acceleration are collinear
    if (_isPossibleRepeatedAcceleratedSwipe && !((_previousLaunchVelocity.dy * velocity.dy).isNegative)) {
      // Proceed to increase the momentum simulation initial boost to
      // scroll faster
      _numberOfRepeatedAcceleratedSwipes++;
      // If the user makes tiny slow scrolls, which get deccelerated by
      // constants due to their scale, they wont't be accelerated for the first 3 of such swipes.
      if (_numberOfRepeatedAcceleratedSwipes > 2) {
        _momentumSimulationInitialVelocityIncreaseScalar =
            _repeatedSwipeVelocityIncreaseScalar(_numberOfRepeatedAcceleratedSwipes);
        _dragIncreaseScalar = _repeatedSwipeDragIncreaseScalar(_numberOfRepeatedAcceleratedSwipes);
      }
    } else {
      _resetRepeatedAccelerationTracking();
    }

    _launchVelocity = velocity;
    // Updating a repeated swipe tracking parameter
    if (_launchVelocity.distance > 0) {
      _previosLaunchedWithMomentum = true;
    }

    PageListViewportLogs.pagesListGestures
        .fine(() => " - the user has completely stopped interacting. Launch velocity is: $_launchVelocity");
  }

  Duration get _timeSinceStartOfGesture => Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);

  Duration? get _timeSinceLastGesture => _previousGestureEndTimeInMillis != null
      ? Duration(milliseconds: _clock.millis - _previousGestureEndTimeInMillis!)
      : null;
}

double _repeatedSwipeVelocityIncreaseScalar(int numberOfRepeatedAcceleratedSwipes) {
  // The function takes the number of the repeated swipes already considered in the repeated swipe acceleration sequence
  // and as returns the launch velocity scalar for the momentum simulation.
  // The model for acceleration due to repeated input assumes this
  // model: startValue+\frac{endValue-startValue}{1+e^{-k(x-transitionValue)}}
  const double transitionValue = 9; // where the function takes it's intermediate value
  const double k = 0.5; // how quickly the shift happens (smaller is slower)
  const double startValue = 1;
  const double endValue = 14;
  return startValue + (endValue - startValue) / (1 + exp(-k * (numberOfRepeatedAcceleratedSwipes - transitionValue)));
}

double _repeatedSwipeDragIncreaseScalar(int numberOfRepeatedAcceleratedSwipes) {
  // The function takes the number of the repeated swipes already considered in the repeated swipe acceleration sequence
  // and as returns the drag increase scalar for the momentum simulation.
  // model: startValue+\frac{endValue-startValue}{1+e^{-k(x-transitionValue)}}
  const double transitionValue = 5; // where the function takes its intermediate value
  const double k = 0.8; // how quickly the shift happens (smaller is slower)
  const double startValue = 1;
  const double endValue = 0.5;
  return startValue + (endValue - startValue) / (1 + exp(-k * (numberOfRepeatedAcceleratedSwipes - transitionValue)));
}

class PanningFrictionSimulation implements PanningSimulation {
  // Dampening factors applied to each component of a [FrictionSimulation].
  // Larger values result in the [FrictionSimulation] to accelerate faster and approach
  // zero slower, giving the impression of the simulation being "more slippery".
  // It was found through testing that other scroll systems seem to be use different dampening
  // factors for the vertical and horizontal components.
  static const horizontalDragCoefficient = 250.0;
  static const verticalDragCoefficient = 300.0;
  static const staticFrictionCoefficient = 20.0;
  // Mass is a redundant parameter, the ratio of m/c, mass to drag is important! Don't change:
  static const mass = 100.0;

  PanningFrictionSimulation({
    required Offset position,
    required Offset velocity,
    double initialVelocityIncreaseScalar = 1.0,
    double dragIncreaseScalar = 1.0,
  })  : _position = position,
        _velocity = velocity,
        _momentumSimInitialVelocityScalar = initialVelocityIncreaseScalar,
        _dragIncreaseScalar = dragIncreaseScalar {
    if (_velocity.dx.abs() > 0 && _velocity.dy.abs() > 0) {
      // The simulation is not locked to an axis, it is in an arbitrary direction.
      _xSimulation = FrictionAndFirstOrderDragMomentumSimulation(
          staticFrictionCoefficient,
          horizontalDragCoefficient * _dragIncreaseScalar,
          mass,
          _position.dx,
          _velocity.distance,
          math.cos(math.atan2(_velocity.dy, _velocity.dx)),
          initialVelocityScalar: ViewportThresholdsAndScales.diagonalLaunchVelocityIncreaseScalar);
      _ySimulation = FrictionAndFirstOrderDragMomentumSimulation(
          staticFrictionCoefficient,
          horizontalDragCoefficient * _dragIncreaseScalar,
          mass,
          _position.dy,
          _velocity.distance,
          math.sin(math.atan2(_velocity.dy, _velocity.dx)),
          initialVelocityScalar: ViewportThresholdsAndScales.diagonalLaunchVelocityIncreaseScalar);
    } else {
      // The simulation is locked to one of the axes.
      _xSimulation = FrictionAndFirstOrderDragMomentumSimulation(
          staticFrictionCoefficient, verticalDragCoefficient * _dragIncreaseScalar, mass, _position.dx, _velocity.dx, 1,
          initialVelocityScalar: _momentumSimInitialVelocityScalar);
      _ySimulation = FrictionAndFirstOrderDragMomentumSimulation(staticFrictionCoefficient,
          horizontalDragCoefficient * _dragIncreaseScalar, mass, _position.dy, _velocity.dy, 1,
          initialVelocityScalar: _momentumSimInitialVelocityScalar);
    }
  }

  final Offset _position;
  final Offset _velocity;
  final double _momentumSimInitialVelocityScalar;
  final double _dragIncreaseScalar;
  late final Simulation _xSimulation;
  late final Simulation _ySimulation;

  @override
  Offset offsetAt(Duration time) {
    final offset = x(time.inMicroseconds.toDouble() / 1e6);
    return offset;
  }

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

class FrictionAndFirstOrderDragMomentumSimulation extends Simulation {
  FrictionAndFirstOrderDragMomentumSimulation(
      double friction, double drag, double mass, double position, double velocity, double scalar,
      {super.tolerance, double initialVelocityScalar = 1, double maxScrollingVelocity = 100000})
      : _c = drag,
        _n = friction,
        _m = mass,
        _x = position,
        _w = velocity.abs() * initialVelocityScalar,
        _sign = velocity.sign,
        _scalar = scalar {
    _finalTime = _m * math.log(1 + _w * _c / (_m * _n)) / _c;
    if (_w > maxScrollingVelocity) {
      _w = maxScrollingVelocity;
    }
  }

  final double _c; // Fluid drag first order
  final double _n; // Static friction
  final double _x; // Initial position
  final double _m; // Mass
  double _w; // Absolute value of the initial velocity
  final double _sign; // Sign of the initial velocity
  // Scalar, by which to multiply all the positional results.
  // Needed to calculate projection onto an arbitrary simulation axis.
  final double _scalar;
  double _finalTime = double.infinity; // Total time for the simulation, initialized upon build

  @override
  double x(double time) {
    if (time > _finalTime) {
      return finalX;
    }
    // Computes the position `x` at time `t`:
    // x = \frac{\left(k_{1}m\ e^{\frac{-c\ t}{m}}-m\ n\ t\right)}{c}+k_{2}
    // where k_{1} = -\left(w+\frac{mn}{c}\right)
    // and k_{2} = \frac{\left(w+\frac{mn}{c}\right)m}{c}
    // Note that k_{1} = p1+p2
    double p1 = -(_w + _m * _n / _c) * _m * math.pow(math.e, -_c * time / _m);
    double p2 = -_m * _n * time;
    double k2 = (_w + _m * _n / _c) * _m / _c;
    late double position;
    position = _x + (_sign * ((p1 - p2) / _c + k2)) * _scalar;

    return position;
  }

  @override
  double dx(double time) {
    // Not used, but required for a simulation object.
    if (time > _finalTime) {
      return 0;
    }
    // Computes velocity at time time:
    // -k_{1}\ e^{-\frac{cx}{m}}-\frac{mn}{c}
    // where k_{1}=-\left(w+\frac{mn}{c}\right)
    double velo = ((_w + _m * _n / _c) * math.pow(math.e, -_c * time / _m) - _m * _n / _c);
    if (_finalTime - time < 2) {
      velo = velo / (_finalTime - time);
    }
    return velo * _scalar;
  }

  /// The value of [x] at the time when the simulation stops.
  double get finalX {
    return x(_finalTime);
  }

  @override
  bool isDone(double time) {
    return time < _finalTime;
  }
}
