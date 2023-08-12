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

  /// Whether the user should be locked into horizontal or vertical
  /// scrolling, when the user pans roughly in those directions.
  ///
  /// When the user drags near 45 degrees, the user retains full pan
  /// control.
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
      // We've started a new gesture after a reasonable period of time
      // since the last gesture. Stop any momentum from the last
      // gesture.
      _stopMomentum();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    PageListViewportLogs.pagesListGestures.finer(() =>
        "onScaleUpdate() - new focal point ${details.focalPoint}, focal delta: ${details.focalPointDelta}");
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
      // When this condition is triggered, _startOffset and
      // _startContentScale should be non-null. But sometimes they are
      // null. I don't know why. When that happens, return.
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

    if (translation.distance < KViewportScaleThresholds.minAxisLockingTranslationDistance) {
      // The translation distance is not sufficiently large to be
      // considered. Small translations should cause panning. This also
      // partially filters out the artifacts of screen calibration,
      // which are characterized by random direction of
      // translation and small distance. Fizzle and wait for the next
      // panning notification.
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
    // only consider axis locking if the translation distance is sufficiently large
    // this is FPS dependent, so 2 should be dewpendent on fps
    if ((pi / 2 - KViewportScaleThresholds.verticalAxisLockAngle < movementAnglePositive) &&
        (movementAnglePositive < pi / 2 + KViewportScaleThresholds.verticalAxisLockAngle)) {
      PageListViewportLogs.pagesListGestures.finer(() => "Locking panning into vertical-only movement.");
      _isLockedVertical = true;
    } else if (movementAnglePositive < KViewportScaleThresholds.horizontalAxisLockAngle ||
        movementAnglePositive > pi - KViewportScaleThresholds.horizontalAxisLockAngle) {
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

  Duration get _timeSinceEndOfLastGesture =>
      Duration(milliseconds: widget.clock.millis - _endTimeInMillis!);
  void _startMomentum() {
    PageListViewportLogs.pagesListGestures.fine(() => "Starting momentum...");
    final velocity = _panAndScaleVelocityTracker.velocity;
    final momentumSimInitialVelocitySclar = _panAndScaleVelocityTracker.momentumSimInitialVelocitySclar;
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
        momentumSimInitialVelocitySclar: momentumSimInitialVelocitySclar,
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

// statically defined class with double constant values which parametrize
// charateristic translation distances and velocities
// distances are tiny | small | large
// speeds are slow | normal | fast
class KViewportScaleThresholds {
  static const double tinyDistanceMax = 0.1;
  static const double smallDistanceMax = 120.0;
  static const double slowSpeedMax = 300.0;
  static const double normalSpeedMax = 850.0;
  static const double minSmallTranslationMomentumActivationSpeed = 120.0;
  static const double smallTranslationSlowSpeedScalar = 0.5;
  static const double smallTranslationNormSpeedScalar = 0.6;
  static const double smallTranslationFastSpeedScalar = 0.7;
  static const double largeTranslationNormSpeedScalar = 0.85;
  static const double diagLaunchSpeedScalar = 0.7;
  static const double defaultSpeedScalar = 1.0;
  static const double defaultDragIncreaseScalar = 1.0;
  // Minimal translation distance for a gesture to be considered for
  // axis locking
  // Note that this depends on the rate at which the gestures are sampled.
  static const double minAxisLockingTranslationDistance = 2.0;

  // Angles for a gesture to be axis locked
  static const double verticalAxisLockAngle = pi / 4;
  static const double horizontalAxisLockAngle = pi / 12;
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

  // Variables needed to keep track of repeated input scroll acceleration
  // Consider the swipe for for repeated input acceleration
  bool _isPossibleAccelSwipe = false;
  bool _previosLaunchedWithMomentum = true;
  int _numberOfRepeatedAcceleratedSwipes = 0;
  final int _maxTimeIntervalBtwRepeatedSwipes = 1000;
  Offset _prevLaunchVelocity = Offset.zero;

  Offset get velocity => _launchVelocity;
  // Initial scalar multiplying velocity in the momentum simulation
  double get momentumSimInitialVelocitySclar => _momentumSimInitialVelocityScalar;
  double get dragIncreaseScalar => _dragIncreaseScalar;
  Offset _launchVelocity = Offset.zero;

  double _momentumSimInitialVelocityScalar = 1.0;
  double _dragIncreaseScalar = 1.0;

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
        _timeSinceLastGesture! < Duration(milliseconds: _maxTimeIntervalBtwRepeatedSwipes)) {
      // if the gesture is not a continued gesture, analyze if it can
      // be a repeated accelerated swipe

      // if the previous gesture was a swipe and it was in the y
      // direction only, mark the gesture as potentially a repeated
      // acceleration swipe
      if (_previosLaunchedWithMomentum &&
          // ignore scales
          details.pointerCount == 1 &&
          !(_launchVelocity.dx.abs() > 0) &&
          _launchVelocity != Offset.zero) {
        _isPossibleAccelSwipe = true;
        _prevLaunchVelocity = _launchVelocity;
      }
    } else {
      PageListViewportLogs.pagesListGestures.fine(() => " - restarting velocity for new gesture");
      _isPossibleGestureContinuation = false;
      _isPossibleAccelSwipe = false;
      _launchVelocity = Offset.zero;
    }

    _previousPointerCount = details.pointerCount;
    _startFocalPosition = details.localFocalPoint;

    // reinitialize the last position tracker every new gesture
    _lastPositions.clear();
    _lastPositions.addFirst(_startFocalPosition);
  }

  void onScaleUpdate(Offset localFocalPoint, int pointerCount) {
    // update the queue tracking last positions
    if (_lastPositions.length > 3) {
      _lastPositions.removeFirst();
    }
    _lastPositions.addLast(localFocalPoint);

    PageListViewportLogs.pagesListGestures.fine(() => "Scale update: $localFocalPoint");

    if (_isPossibleGestureContinuation) {
      if (_timeSinceStartOfGesture < const Duration(milliseconds: 24)) {
        PageListViewportLogs.pagesListGestures
            .fine(() => " - this gesture is a continuation. Ignoring update.");
        return;
      }

      // Enough time has passed for us to conclude that this gesture isn't just
      // an intermediate moment as the user adds or removes fingers. This gesture
      // is intentional, and we need to track its velocity.
      PageListViewportLogs.pagesListGestures.fine(() =>
          " - a possible gesture continuation has been confirmed as a new gesture. Restarting velocity.");
      _currentGestureStartTimeInMillis = _clock.millis;
      _launchVelocity = Offset.zero;

      _isPossibleGestureContinuation = false;
    }

    _lastFocalPosition = localFocalPoint;
  }

  // Reset the variables tracking accelerated repeated swiping gestures.
  // Should be called after panning velocityTracker decides to return
  // and not not launch a momentum simulation.
  void _resetRepeatedAccelerationTracking() {
    _previosLaunchedWithMomentum = false;
    _numberOfRepeatedAcceleratedSwipes = 0;
    _isPossibleAccelSwipe = false;
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
      PageListViewportLogs.pagesListGestures
          .fine(() => " - this gesture is a continuation of a previous gesture.");
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
      PageListViewportLogs.pagesListGestures.fine(() =>
          " - this gesture was a scale gesture and user switched to panning. Resetting launch velocity.");
      _launchVelocity = Offset.zero;
      return;
    }

    final translationDistance = (_lastFocalPosition - _startFocalPosition).distance;
    final velocityDistance = velocity.distance;

    // set default initial scrolling velocity boost
    _momentumSimInitialVelocityScalar = KViewportScaleThresholds.defaultSpeedScalar;
    _dragIncreaseScalar = KViewportScaleThresholds.defaultDragIncreaseScalar;
    // judge the swiping gesture based on the length of the translation
    // and the velocity and either end it at pannign by setting the
    // accelerated scroll tracking settings and returning OR proceed to
    // initializing a momentum simulation
    if (translationDistance < KViewportScaleThresholds.tinyDistanceMax) {
      // prevent momentum simulation for tiny scrolls
      _resetRepeatedAccelerationTracking();
      return;
    } else if (translationDistance < KViewportScaleThresholds.smallDistanceMax) {
      // medium translation, depending on the speed decide whether to simulate momentum
      if (velocityDistance > KViewportScaleThresholds.normalSpeedMax) {
        // small translation, fast speed
        _momentumSimInitialVelocityScalar = KViewportScaleThresholds.smallTranslationFastSpeedScalar;
      } else if (velocityDistance > KViewportScaleThresholds.slowSpeedMax) {
        // small translation, normal speed
        _momentumSimInitialVelocityScalar = KViewportScaleThresholds.smallTranslationNormSpeedScalar;
      } else if (velocityDistance > KViewportScaleThresholds.minSmallTranslationMomentumActivationSpeed) {
        // small translation, slow speed
        _momentumSimInitialVelocityScalar = KViewportScaleThresholds.smallTranslationSlowSpeedScalar;
      } else {
        // small translation, speed insufficient to launch a momentum simulation
        _resetRepeatedAccelerationTracking();
        return;
      }
    } else {
      // large translation distance
      if (velocityDistance > KViewportScaleThresholds.normalSpeedMax) {
        // large translation, fast speed
      } else if (velocityDistance > KViewportScaleThresholds.slowSpeedMax) {
        _momentumSimInitialVelocityScalar = KViewportScaleThresholds.largeTranslationNormSpeedScalar;
        // large translation, normal speed
      } else {
        // large translation, slow speed
        _resetRepeatedAccelerationTracking();
        return;
      }
    }

    // Spaghetti code which blocks the issue when the uncalibrated touch
    // sensor gives attributes to the gestures which end at a finger
    // halt.
    // The gesture is blocked if the flutter-reported velocity is
    // in another direction to what we track based on the buffer of last
    // positions.
    if (_lastPositions.length >= KViewportScaleThresholds.minAxisLockingTranslationDistance) {
      // we need to have at least one translation to compare to
      Offset oldTranslationVector = _lastPositions.elementAt(1) - _lastPositions.first;
      double scalarProduct = oldTranslationVector.dx * velocity.dx + oldTranslationVector.dy * velocity.dy;
      if (scalarProduct <= 0) {
        _resetRepeatedAccelerationTracking();
        return;
      }
    } else {
      // This gesture was short and we are not going to consider it for repeated acceleration
      _resetRepeatedAccelerationTracking();
    }

    if (pointerCount > 0) {
      PageListViewportLogs.pagesListGestures.fine(
          () => " - the user removed a finger, but is still interacting. Storing velocity for later.");
      PageListViewportLogs.pagesListGestures
          .fine(() => " - stored velocity: $_launchVelocity, magnitude: ${_launchVelocity.distance}");
      return;
    }

    // Check that the two swipes consequtively considered for repeated
    // swiping acceleration are collinear
    if (_isPossibleAccelSwipe && !((_prevLaunchVelocity.dy * velocity.dy).isNegative)) {
      // Proceed to increase the momentum simulation initial boost to
      // scroll faster
      _numberOfRepeatedAcceleratedSwipes++;
      // if the user makes tiny slow scrolls, which get deccelerated by
      // constants, don't override them for the first 3 swipes
      if (_numberOfRepeatedAcceleratedSwipes > 2) {
        _momentumSimInitialVelocityScalar = repeatedSwipeVelocityScalar(_numberOfRepeatedAcceleratedSwipes);
        _dragIncreaseScalar = repeatedSwipeDragIncreaseScalar(_numberOfRepeatedAcceleratedSwipes);
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

  Duration get _timeSinceStartOfGesture =>
      Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);

  Duration? get _timeSinceLastGesture => _previousGestureEndTimeInMillis != null
      ? Duration(milliseconds: _clock.millis - _previousGestureEndTimeInMillis!)
      : null;
}

double repeatedSwipeVelocityScalar(int numberOfRepeatedAcceleratedSwipes) {
  // The function takes the number of the repeated swipe considered in the repeated swipe acceleration sequence and as return gives the initial velocity scalar.
  // The model for acceleration due to repeated input assumes this
  // model: kStartValue+\frac{kEndValue-kStartValue}{1+e^{-kK(x-kMidway)}}
  const double kMidway = 9; // where the function takes it's intermediate value
  const double kK = 0.5; // how quickly the transition happens (smaller is slower)
  const double kStartValue = 1;
  const double kEndValue = 14;
  return kStartValue +
      (kEndValue - kStartValue) / (1 + exp(-kK * (numberOfRepeatedAcceleratedSwipes - kMidway)));
}

double repeatedSwipeDragIncreaseScalar(int numberOfRepeatedAcceleratedSwipes) {
  // The function takes the number of the repeated swipe considered in the repeated swipe acceleration sequence and as return gives the initial velocity scalar.
  // The model for acceleration due to repeated input assumes this
  // model: kStartValue+\frac{kEndValue-kStartValue}{1+e^{-kK(x-kMidway)}}
  const double kMidway = 5; // where the function takes it's intermediate value
  const double kK = 0.8; // how quickly the transition happens (smaller is slower)
  const double kStartValue = 1;
  const double kEndValue = 0.5;
  return kStartValue +
      (kEndValue - kStartValue) / (1 + exp(-kK * (numberOfRepeatedAcceleratedSwipes - kMidway)));
}

class PanningFrictionSimulation implements PanningSimulation {
  // Dampening factors applied to each component of a [FrictionSimulation].
  // Larger values result in the [FrictionSimulation] to accelerate faster and approach
  // zero slower, giving the impression of the simulation being "more slippery".
  // It was found through testing that other scroll systems seem to be use different dampening
  // factors for the vertical and horizontal components.
  static const kNormalDrag = 250.0;
  static const kDragHorizontal = 300.0;
  static const kFriction = 20.0;
  // Mass is a redundant parameter, the ratio of m/c, mass to drag is important! Don't change:
  static const kMass = 100.0;

  PanningFrictionSimulation({
    required Offset position,
    required Offset velocity,
    double momentumSimInitialVelocitySclar = 1.0,
    double dragIncreaseScalar = 1.0,
  })  : _position = position,
        _velocity = velocity,
        _momentumSimInitialVelocityScalar = momentumSimInitialVelocitySclar,
        _dragIncreaseScalar = dragIncreaseScalar {
    if (_velocity.dx.abs() > 0 && _velocity.dy.abs() > 0) {
      // mixed direction simulation
      _xSimulation = FrictionDragScalar(kFriction, kNormalDrag * _dragIncreaseScalar, kMass, _position.dx,
          _velocity.distance, math.cos(math.atan2(_velocity.dy, _velocity.dx)),
          initialSpeedScalar: KViewportScaleThresholds.diagLaunchSpeedScalar);
      _ySimulation = FrictionDragScalar(kFriction, kNormalDrag * _dragIncreaseScalar, kMass, _position.dy,
          _velocity.distance, math.sin(math.atan2(_velocity.dy, _velocity.dx)),
          initialSpeedScalar: KViewportScaleThresholds.diagLaunchSpeedScalar);
    } else {
      _xSimulation = FrictionDragScalar(
          kFriction, kDragHorizontal * _dragIncreaseScalar, kMass, _position.dx, _velocity.dx, 1,
          initialSpeedScalar: _momentumSimInitialVelocityScalar);
      _ySimulation = FrictionDragScalar(
          kFriction, kNormalDrag * _dragIncreaseScalar, kMass, _position.dy, _velocity.dy, 1,
          initialSpeedScalar: _momentumSimInitialVelocityScalar);
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

class FrictionDragScalar extends Simulation {
  FrictionDragScalar(
      double friction, double drag, double mass, double position, double velocity, double scalar,
      {super.tolerance, double initialSpeedScalar = 1, double maxScrollingVelocity = 100000})
      : _c = drag,
        _n = friction,
        _m = mass,
        _x = position,
        _w = velocity.abs() * initialSpeedScalar,
        _sign = velocity.sign,
        _scalar = scalar {
    _finalTime = _m * math.log(1 + _w * _c / (_m * _n)) / _c;
    if (_w > maxScrollingVelocity) {
      _w = maxScrollingVelocity;
    }
  }

  final double _c; // fluid drag first order
  final double _n; // static friction
  final double _x; // initial position
  final double _m; // mass
  double _w; // absolute value of the initial velocity
  final double _sign; // sign of the initial velocity
  final double _scalar; // scalar, by which to multiply all the positional results
  double _finalTime = double.infinity; // total time for the simulation, initialized upon build

  @override
  double x(double time) {
    if (time > _finalTime) {
      return finalX;
    }
    // Computes the position at time time:
    // \frac{\left(k_{1}m\ e^{\frac{-c\ x}{m}}-m\ n\ x\right)}{c}+k_{2}
    // where k_{1}=-\left(w+\frac{mn}{c}\right)
    // and \frac{\left(w+\frac{mn}{c}\right)m}{c}
    double p1 = -(_w + _m * _n / _c) * _m * math.pow(math.e, -_c * time / _m);
    double p2 = -_m * _n * time;
    double k2 = (_w + _m * _n / _c) * _m / _c;
    late double posi;
    posi = _x + (_sign * ((p1 - p2) / _c + k2)) * _scalar;

    return posi;
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
