import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'logging.dart';
import 'page_list_viewport.dart';

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

    if (translation.distance < GestureThresholdsAndScales.minAxisLockingTranslationDistance) {
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
    // The viewport thhresholds define the angle window around the
    // vertical and horizontal axes which would result in axis locking.
    // Vertical axis locking if the angle lays in the
    // (pi/2 - vAngle, pi/2 + vAngle) window.
    // Horizontal window is (hAngle, 0) or (pi - hAngle, pi).
    const hAngle = GestureThresholdsAndScales.horizontalAxisLockAngle;
    const vAngle = GestureThresholdsAndScales.verticalAxisLockAngle;

    if ((math.pi / 2 - vAngle < movementAnglePositive) && (movementAnglePositive < math.pi / 2 + vAngle)) {
      PageListViewportLogs.pagesListGestures.finer(() => "Locking panning into vertical-only movement.");
      _isLockedVertical = true;
    } else if (movementAnglePositive < hAngle || movementAnglePositive > math.pi - hAngle) {
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
    final dragMultiplier = _panAndScaleVelocityTracker.dragIncreaseMultiplier;
    PageListViewportLogs.pagesListGestures
        .fine(() => "Starting momentum with velocity: ${_panAndScaleVelocityTracker.velocity}");

    final panningSimulation = BallisticPanningOrientationSimulation(
      initialOrientation: AxisAlignedOrientation(
        widget.controller.origin,
        widget.controller.scale,
      ),
      panningSimulation: PanningFrictionSimulation(
        position: widget.controller.origin,
        velocity: _panAndScaleVelocityTracker.velocity,
        initialVelocityMultiplier: _panAndScaleVelocityTracker.ballisticSimulationInitialVelocityMultiplier,
        dragMultiplier: dragMultiplier,
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

/// Definiton for gestures' translation distance and velocity categories.
///
/// Distances are tiny, small, and large.
/// Speeds are slow, normal, and fast.
/// These categories are used to individually define ballistic simulation behavior
/// across a variety of scrolling situations.
class GestureThresholdsAndScales {
  /// The maximum distance for a motion to be categorizes as "tiny".
  ///
  /// {@template distance_definitions}
  /// Gesture translation distance categorization.
  /// The launch velocity for the ballistic simulation can be individually
  /// scaled for gestures categorized into these categories.
  /// Distances scale diagram:
  /// (0 ... "tiny" ... tinyDistanceMax] (... "small" ... SmallDistanceMax]( ... "large" ...
  /// {@endtemplate}
  static const double tinyDistanceMax = 3;

  /// Definition for a small distance in pixels.
  ///
  /// {@macro distance_definitions}
  static const double smallDistanceMax = 120.0;

  /// Maximum velocity for a gesture to be considered "slow".
  ///
  /// {@template speed_definitions}
  /// Gesture speed categorization.
  /// The launch velocity for the ballistic simulation can be individually
  /// scaled for gestures categorized into these categories.
  /// Speeds scale categorization diagram:
  /// (0 ... "slow" ... slowVelocityMax] (... "normal" ... normalVelocityMax]( ... "fast" ...
  /// {@endtemplate}
  static const double slowSpeedMax = 300.0;

  /// Maximum speed for a gesture to be considered "normal".
  ///
  /// {@macro speed_definitions}
  static const double normalSpeedMax = 850.0;

  /// Minimal neccessary speed when the user releases from any panning motion
  /// required for which a ballistic simulation to be launched.
  ///
  /// Value is in pixels per second.
  static const double minSmallTranslationBallisticActivationSpeed = 120.0;

  /// {@template velocity_increase}
  /// Ballistic simulation launch velocity multiplier according to the
  /// category into which its translation distanca and reported velocity
  /// fall.
  ///
  /// Used to speed up or slow down the simulation speed for different gesture kinds.
  /// Is applied when the user releases an arbitrary direction panning motion (not locked axis), and the content goes
  /// ballistic.
  /// This value is unit-less and should be multiplied by a velocity that's measured in pixels
  /// per second.
  /// {@endtemplate}
  /// Modifies launch velocity for gestures categorizes with small translation distance and slow speed
  static const double smallTranslationSlowSpeedMultiplier = 0.5;

  /// {@macro velocity_increase}
  /// Modifies launch velocity for gestures categorizes with small translation distance and normal speed
  static const double smallTranslationNormalSpeedMultiplier = 0.6;

  /// {@macro velocity_increase}
  /// Modifies launch velocity for gestures categorizes with small translation distance and fast speed
  static const double smallTranslationFastSpeedMultiplier = 0.7;

  /// {@macro velocity_increase}
  /// Modifies launch velocity for gestures categorizes with large translation distance and normal speed
  static const double largeTranslationNormalSpeedMultiplier = 0.85;

  /// {@macro velocity_increase}
  /// Modifies launch velocity for gestures categorizes with large translation distance and fast speed
  static const double largeTranslationFastSpeedMultiplier = 1.0;

  // Tiny translation distance is not considered for ballistic simulation.

  /// Velocity multiplier that should be applied when the user releases an arbitrary direction
  /// panning motion (not locked axis), and the content goes ballistic.
  ///
  /// This value is unit-less and should be multiplied by a velocity that's measured in pixels
  /// per second.
  /// Speed up the diagonal ballistic simulation.
  static const double diagonalLaunchVelocityMultiplier = 0.7;

  /// Default velocity multiplier that should be applied when the user lifts
  /// their finger after a panning motion when the content goes ballistic.
  ///
  /// This value is unit-less and should be multiplied by a velocity that's measured in pixels
  /// per second.
  static const double defaultVelocityMultiplier = 1.0;

  /// Increase the drag coefficient of the ballistic simulation.
  ///
  /// Higher drag coefficient means that the simulation launched after user lifts
  /// their finger will deccelerate faster.
  /// The drag deccelaration term in the simulation is -d/dt(v) = dragCoefficient * v.
  static const double defaultDragMultiplier = 1.0;

  /// Minimal translation distance required for a gesture to be considered for axis locking.
  ///
  /// After the user has panned more than this distance, the gesture will be locked
  /// if it is close enough to the horizontal or vertical axis as defined in
  /// [horizontalAxisLockAngle] and [verticalAxisLockAngle].
  /// Artificially increase the distance to prevent axis locking for tiny gestures.
  /// Note that this depends on the rate at which the gestures are sampled.
  static const double minAxisLockingTranslationDistance = 2.0;

  /// Angle w.r.t. the horizontal axis for a gesture to be locked to the horizontal axis.
  ///
  /// {@template axis_locking_angles}
  /// The angle defines a window around the axis, in which the gesture
  /// will be locked to the axis.
  /// The larger this angle, the easier gestures will be locked to the axis.
  /// The angle is measured in radians.
  /// {@endtemplate}
  static const double horizontalAxisLockAngle = math.pi / 12;

  /// Angle w.r.t. the vertical axis for a gesture to be locked to the vertical axis.
  ///
  /// {@macro axis_locking_angles}
  static const double verticalAxisLockAngle = math.pi / 4;

  /// Maximal time between any two scrolling gestures for them to be considered for viewport scrolling acceleration
  ///
  /// Scrolls which are repeated frequently and are in the same direction should cause the viewport
  /// to scroll faster and faster with each consequtive swiping input.
  /// This is called repeated swipe (or scroll) acceleration
  static const Duration maxDurationForRepeatGesturesToAcceleratePanning = Duration(milliseconds: 1000);
}

class DeprecatedPanAndScaleVelocityTracker {
  final _focalPointHistory = ListQueue<Offset>();

  DeprecatedPanAndScaleVelocityTracker({
    required Clock clock,
  }) : _clock = clock;

  final Clock _clock;

  int _previousGesturePointerCount = 0;
  int? _previousGestureEndTimeInMillis;

  int? _currentGestureStartTimeInMillis;
  PanAndScaleGestureAction? _currentGestureStartAction;
  bool _isPossibleGestureContinuation = false;

  // Variables needed to keep track of repeated input scroll acceleration.
  // Repeated swipe acceleration is when the viewport moves faster than during
  // regular scrolls if the user swipes very frequently in the same direction.

  // Whether it is possible that the gesture is a repeated swipe which should
  // speed up the accelerate the viewport.
  bool _isPossibleRepeatedAcceleratedSwipe = false;

  // Whether the previous gesture ended up launching a scrolling ballistic simulation.
  bool _previosLaunchedWithBallistic = true;

  // Number of repeated scrolling gestures already considered in the viewport acceleration.
  int _numberOfRepeatedAcceleratedSwipes = 0;

  // Velocity with which the prevous gesture which triggered the ballistic simulation
  // was launched.
  Offset _previousLaunchVelocity = Offset.zero;

  /// Launch velocity of the ballistic simulation.
  ///
  /// The simulation will start at a faster velocity if this value is greater than 1.
  /// This value is in pixels per second.
  /// Value is computed based on the reported velocities and translation distances
  /// after gesture end.
  /// It is modified by scales defined in [GestureThresholdsAndScales] based on
  /// the type of the gesture, its translation distance, velocity magnitude, and direction
  /// and then passed into the ballistic simulation.
  /// Value is in pixels per second.
  Offset get velocity => _launchVelocity;
  Offset _launchVelocity = Offset.zero;

  /// Increase the launch velocity in the ballistic simulation.
  ///
  /// The simulation will start at a faster velocity if this value is greater than 1.
  /// Default value is set here, but is overriden by the [GestureThresholdsAndScales].
  /// Value is unit-less and should be multiplied by a velocity that's measured in pixels.
  double get ballisticSimulationInitialVelocityMultiplier => _ballisticSimulationInitialVelocityMultiplier;
  double _ballisticSimulationInitialVelocityMultiplier = 1.0;

  /// Value which multiplies the drag coefficient in the simulation.
  ///
  /// The simulation will deccelerate faster with a higher drag coefficient.
  /// Default value is set here, but is overriden by the [GestureThresholdsAndScales].
  /// Value is unit-less and should be multiplied by a velocity that's measured in pixels.
  double get dragIncreaseMultiplier => _ballisticSimulationDragMultiplier;
  double _ballisticSimulationDragMultiplier = 1.0;

  /// The focal point when the gesture started.
  Offset _startFocalPosition = Offset.zero;

  /// The last focal point before the gesture ended
  Offset _lastFocalPosition = Offset.zero;

  void onScaleStart(ScaleStartDetails details) {
    PageListViewportLogs.pagesListGestures.fine(() =>
        "onScaleStart() - pointer count: ${details.pointerCount}, time since last gesture: ${_timeSinceLastGesture?.inMilliseconds}ms");

    if (_previousGesturePointerCount == 0) {
      _currentGestureStartAction = PanAndScaleGestureAction.firstFingerDown;
    } else if (details.pointerCount > _previousGesturePointerCount) {
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
          " - this gesture started really fast. Assuming that this is a continuation. Previous pointer count: $_previousGesturePointerCount. Current pointer count: ${details.pointerCount}");
      _isPossibleGestureContinuation = true;
    } else if (_timeSinceLastGesture != null &&
        _timeSinceLastGesture! < GestureThresholdsAndScales.maxDurationForRepeatGesturesToAcceleratePanning) {
      // If the gesture is not a continued gesture, analyze if it can
      // be a repeated accelerated swipe.

      // If the previous gesture was a swipe, which triggered a ballistic simulation
      // and it was in the y direction only, mark the gesture as potentially a repeated
      // acceleration swipe.
      if (_previosLaunchedWithBallistic &&
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

    _previousGesturePointerCount = details.pointerCount;
    _startFocalPosition = details.localFocalPoint;

    // Reinitialize the previos position tracker every new gesture
    _focalPointHistory.clear();
    _focalPointHistory.addFirst(_startFocalPosition);
  }

  void onScaleUpdate(Offset localFocalPoint, int pointerCount) {
    // Update the queue tracking previous positions
    if (_focalPointHistory.length > 3) {
      _focalPointHistory.removeFirst();
    }
    _focalPointHistory.addLast(localFocalPoint);

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
  // and not launch a ballistic simulation for a gesture.
  void _resetRepeatedAccelerationTracking() {
    _previosLaunchedWithBallistic = false;
    _numberOfRepeatedAcceleratedSwipes = 0;
    _isPossibleRepeatedAcceleratedSwipe = false;
    _launchVelocity = Offset.zero;
  }

  void onScaleEnd(Offset velocity, int pointerCount) {
    final gestureDuration = Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);
    PageListViewportLogs.pagesListGestures
        .fine(() => "onScaleEnd() - gesture duration: ${gestureDuration.inMilliseconds}");

    _previousGestureEndTimeInMillis = _clock.millis;
    _previousGesturePointerCount = pointerCount;
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

    if (_previousGesturePointerCount > 1) {
      // The user was scaling. Now the user is panning. We don't want scale gestures to result in a ballistic
      // simulation, so we set the launch velocity to zero.
      // If the panning continues long enough, then we'll use the panning
      // velocity for ballistic.
      PageListViewportLogs.pagesListGestures
          .fine(() => " - this gesture was a scale gesture and user switched to panning. Resetting launch velocity.");
      _launchVelocity = Offset.zero;
      return;
    }

    final translationDistance = (_lastFocalPosition - _startFocalPosition).distance;
    final speed = velocity.distance;

    // Set the default launch scrolling velocity multiplier.
    // The value multiplies the launch velocity for the ballistic simulation to speed it up or slow it down.
    _ballisticSimulationInitialVelocityMultiplier = GestureThresholdsAndScales.defaultVelocityMultiplier;

    // Set the default drag multiplier.
    // The scalar simply multiplies the drag coefficient. Larger multipliers mean faster decceleration.
    _ballisticSimulationDragMultiplier = GestureThresholdsAndScales.defaultDragMultiplier;

    // Judge the swiping gesture based on the translation distance
    // and the velocity and either:
    // End the gesture at panning by resetting the accelerated scroll tracking settings and returning.
    // The swipe won't triger the ballistic simulation.
    // OR
    // Proceed to initializing a ballistic simulation for further motion.
    if (translationDistance < GestureThresholdsAndScales.tinyDistanceMax) {
      // prevent ballistic simulation for tiny scrolls
      _resetRepeatedAccelerationTracking();
      return;
    } else if (translationDistance < GestureThresholdsAndScales.smallDistanceMax) {
      // Small or tiny translation, depending on the velocity decide whether to simulate ballistic
      if (speed > GestureThresholdsAndScales.normalSpeedMax) {
        // Small translation, fast velocity
        _ballisticSimulationInitialVelocityMultiplier = GestureThresholdsAndScales.smallTranslationFastSpeedMultiplier;
      } else if (speed > GestureThresholdsAndScales.slowSpeedMax) {
        // Small translation, normal velocity
        _ballisticSimulationInitialVelocityMultiplier =
            GestureThresholdsAndScales.smallTranslationNormalSpeedMultiplier;
      } else if (speed > GestureThresholdsAndScales.minSmallTranslationBallisticActivationSpeed) {
        // Small translation, slow velocity
        _ballisticSimulationInitialVelocityMultiplier = GestureThresholdsAndScales.smallTranslationSlowSpeedMultiplier;
      } else {
        // Small translation, velocity insufficient to launch a ballistic simulation
        _resetRepeatedAccelerationTracking();
        return;
      }
    } else {
      // Large translation distance
      if (speed > GestureThresholdsAndScales.normalSpeedMax) {
        _ballisticSimulationInitialVelocityMultiplier = GestureThresholdsAndScales.largeTranslationFastSpeedMultiplier;
        // Large translation, fast speed
      } else if (speed > GestureThresholdsAndScales.slowSpeedMax) {
        _ballisticSimulationInitialVelocityMultiplier =
            GestureThresholdsAndScales.largeTranslationNormalSpeedMultiplier;
        // Large translation, normal speed
      } else {
        // Large translation, slow speed
        _resetRepeatedAccelerationTracking();
        return;
      }
    }

    // Solves the issue of reported random noise due to the uncalibrated touch sensor,
    // which happen usually at a finger halt.
    // This is called when the gesture ends, and the velocity is reported.
    // The gesture is blocked if the reported gesture velocity is
    // in another direction to the previously tracked velocities.
    // The tracked velocities are collected using a queue
    // storing the last 3 reported gesture offsets.
    if (_focalPointHistory.length >= 2) {
      // There is at least one gesture translation in the history buffer to compare to

      // The vector defining the general direction of the gesture before it ended,
      // computed as the vecor between the first and the last saved points in the history buffer.
      Offset historicTranslationVector = _focalPointHistory.elementAt(1) - _focalPointHistory.first;
      double scalarProduct = historicTranslationVector.dx * velocity.dx + historicTranslationVector.dy * velocity.dy;
      if (scalarProduct <= 0) {
        // If the scalar product is nonpositive, the vectors are in opposite directions or
        // Perpendicular. The gesture is blocked.
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

    // If the user is still swiping in the same direction, increase speed.
    if (_isPossibleRepeatedAcceleratedSwipe && (_previousLaunchVelocity.dy.sign == velocity.dy.sign)) {
      // Proceed to increase the ballistic simulation initial boost to
      // scroll faster
      _numberOfRepeatedAcceleratedSwipes += 1;
      // Don't alter the launch velocity for the ballistic simulation of the first 3 swipes.
      if (_numberOfRepeatedAcceleratedSwipes > 2) {
        _ballisticSimulationInitialVelocityMultiplier =
            _calculateVelocityMultiplierFromRepeatedSwipeCount(_numberOfRepeatedAcceleratedSwipes);
        _ballisticSimulationDragMultiplier =
            _calculateDragMultiplierFromRepeatedSwipeCount(_numberOfRepeatedAcceleratedSwipes);
      }
    } else {
      // The user is not panning in the same direction as the last frame. Reset direction tracking.
      _resetRepeatedAccelerationTracking();
    }

    _launchVelocity = velocity;
    // Updating a repeated swipe tracking parameter
    // so the next gesture, the second in a series,
    // can be considered for repeated swipe acceleration.
    if (_launchVelocity.distance > 0) {
      _previosLaunchedWithBallistic = true;
    }

    PageListViewportLogs.pagesListGestures
        .fine(() => " - the user has completely stopped interacting. Launch velocity is: $_launchVelocity");
  }

  /// Compute ballistic simulation launch velocity multiplier for repeated swiping gestures.
  ///
  /// The function takes the number of the repeated swipes already considered in the repeated swipe acceleration
  /// sequence and returns the launch velocity multiplier for ballistic simulation after the
  /// next gesture.
  /// Velocity multiplier due to repeated input assumes this model:
  /// startValue+\frac{endValue-startValue}{1+e^{-k(x-transitionValue)}}
  double _calculateVelocityMultiplierFromRepeatedSwipeCount(int numberOfRepeatedAcceleratedSwipes) {
    const double transitionValue = 9; // where the function takes it's intermediate value
    const double k = 0.5; // how quickly the shift happens (smaller is slower)
    const double startValue = 1;
    const double endValue = 14;
    return startValue +
        (endValue - startValue) / (1 + math.exp(-k * (numberOfRepeatedAcceleratedSwipes - transitionValue)));
  }

  /// Compute ballistic simulation drag multiplier for repeated swiping gestures.
  ///
  /// The function takes the number of the repeated swipes already considered in the repeated swipe acceleration
  /// sequence and returns the drag multiplier for ballistic simulation after the
  /// next gesture.
  /// It assumes this model: startValue+\frac{endValue-startValue}{1+e^{-k(x-transitionValue)}}
  double _calculateDragMultiplierFromRepeatedSwipeCount(int numberOfRepeatedAcceleratedSwipes) {
    const double transitionValue = 5; // where the function takes its intermediate value
    const double k = 0.8; // how quickly the shift happens (smaller is slower)
    const double startValue = 1;
    const double endValue = 0.5;
    return startValue +
        (endValue - startValue) / (1 + math.exp(-k * (numberOfRepeatedAcceleratedSwipes - transitionValue)));
  }

  Duration get _timeSinceStartOfGesture => Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);

  Duration? get _timeSinceLastGesture => _previousGestureEndTimeInMillis != null
      ? Duration(milliseconds: _clock.millis - _previousGestureEndTimeInMillis!)
      : null;
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
  // Mass is used here as a redundant parameter, the ratio of m/c, mass to drag is important.
  // It is recommended to change the drag coefficient instead of the mass.
  // Changing the mass would have the inversely proportional effect as
  // changing the drag coefficient.
  static const mass = 100.0;

  PanningFrictionSimulation({
    required Offset position,
    required Offset velocity,
    double initialVelocityMultiplier = 1.0,
    double dragMultiplier = 1.0,
  })  : _position = position,
        _velocity = velocity,
        _ballisticSimulationInitialVelocityMultiplier = initialVelocityMultiplier,
        _dragMultiplier = dragMultiplier {
    if (_velocity.dx.abs() > 0 && _velocity.dy.abs() > 0) {
      // The simulation is not locked to an axis, it is in an arbitrary direction.

      _xSimulation = FrictionAndFirstOrderDragBallisticSimulation(
          staticFrictionCoefficient,
          horizontalDragCoefficient * _dragMultiplier,
          mass,
          _position.dx,
          _velocity.distance,
          math.cos(math.atan2(_velocity.dy, _velocity.dx)),
          initialVelocityMultiplier: GestureThresholdsAndScales.diagonalLaunchVelocityMultiplier);

      _ySimulation = FrictionAndFirstOrderDragBallisticSimulation(
          staticFrictionCoefficient,
          horizontalDragCoefficient * _dragMultiplier,
          mass,
          _position.dy,
          _velocity.distance,
          math.sin(math.atan2(_velocity.dy, _velocity.dx)),
          initialVelocityMultiplier: GestureThresholdsAndScales.diagonalLaunchVelocityMultiplier);
    } else {
      // The simulation is locked to one of the axes.

      _xSimulation = FrictionAndFirstOrderDragBallisticSimulation(
          staticFrictionCoefficient, verticalDragCoefficient * _dragMultiplier, mass, _position.dx, _velocity.dx, 1,
          initialVelocityMultiplier: _ballisticSimulationInitialVelocityMultiplier);

      _ySimulation = FrictionAndFirstOrderDragBallisticSimulation(
          staticFrictionCoefficient, horizontalDragCoefficient * _dragMultiplier, mass, _position.dy, _velocity.dy, 1,
          initialVelocityMultiplier: _ballisticSimulationInitialVelocityMultiplier);
    }
  }

  final Offset _position;
  final Offset _velocity;
  final double _ballisticSimulationInitialVelocityMultiplier;
  final double _dragMultiplier;
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

/// A ballistic simulation that uses a first order drag and a static friction term to model
/// the motion of the viewport after the user lifts their finger.
///
/// [position] is the initial position of the simulated object in pixels.
///
/// [velocity] is the initial velocity of the simulated object in pixels per second.
///
/// [friction] is the static friction coefficient in units of velocity per second.
///
/// [drag] is the first order drag coefficient in units of mass per second.
///
/// [mass] is the mass of the simulated object in units of mass.
///
/// [initialVelocityMultiplier] is a number, by which to multiply the initial velocity at
/// the start of the simulation.
/// [positionMultiplier] is a number, by which to multiply all the positional results, useful
///
/// to find projections on an axis. Simulation projected on a vecor which is an
/// andle alpha to the simulation can be obtained by setting this multiplier
/// to cos(alpha).
///
/// [maxInitialScrollingVelocity] is the maximal velocity at which the simulation can start.
/// All initial velocities above this value will be capped at this value.
///
/// The kinematic model for position at time t is:
/// ``` {LaTeX}
/// x = \frac{\left(k_{1}m\ e^{\frac{-c\ t}{m}}-m\ n\ t\right)}{c}+k_{2}
/// where k_{1} = -\left(w+\frac{mn}{c}\right)
/// and k_{2} = \frac{\left(w+\frac{mn}{c}\right)m}{c}
/// ```
/// where c is the drag coefficient, n is the static friction coefficient, m is the mass,
/// w is the initial velocity, and t is time.
class FrictionAndFirstOrderDragBallisticSimulation extends Simulation {
  FrictionAndFirstOrderDragBallisticSimulation(
    double friction,
    double drag,
    double mass,
    double position,
    double velocity,
    double positionMultiplier, {
    super.tolerance,
    double initialVelocityMultiplier = 1,
    double maxInitialScrollingVelocity = 100000,
  })  : _c = drag,
        _n = friction,
        _m = mass,
        _x = position,
        _w = velocity.abs() * initialVelocityMultiplier,
        _sign = velocity.sign,
        _positionMultiplier = positionMultiplier {
    _finalTime = _m * math.log(1 + _w * _c / (_m * _n)) / _c;
    if (_w > maxInitialScrollingVelocity) {
      _w = maxInitialScrollingVelocity;
    }
  }

  final double _c; // Fluid drag first order
  final double _n; // Static friction
  final double _x; // Initial position
  final double _m; // Mass
  double _w; // Absolute value of the initial velocity
  final double _sign; // Sign of the initial velocity
  // Number, by which to multiply all the positional results.
  // Needed to calculate projection onto an arbitrary simulation axis.
  final double _positionMultiplier;
  double _finalTime = double.infinity; // Total time for the simulation, initialized upon build

  /// Computes the position `x` at time `t`:
  ///
  /// x = \frac{\left(k_{1}m\ e^{\frac{-c\ t}{m}}-m\ n\ t\right)}{c}+k_{2}
  /// where k_{1} = -\left(w+\frac{mn}{c}\right)
  /// and k_{2} = \frac{\left(w+\frac{mn}{c}\right)m}{c}
  /// Note that k_{1} = p1+p2
  @override
  double x(double time) {
    if (time > _finalTime) {
      return finalX;
    }
    double p1 = -(_w + _m * _n / _c) * _m * math.pow(math.e, -_c * time / _m);
    double p2 = -_m * _n * time;
    double k2 = (_w + _m * _n / _c) * _m / _c;
    late double position;
    position = _x + (_sign * ((p1 - p2) / _c + k2)) * _positionMultiplier;

    return position;
  }

  /// The velocity at time [time].
  ///
  /// Is a derivative of the position x(time) with respect to time.
  /// Not used, but required for a simulation object.
  @override
  double dx(double time) {
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
    return velo * _positionMultiplier;
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
