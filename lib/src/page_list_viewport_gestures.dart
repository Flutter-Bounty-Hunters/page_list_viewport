import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
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
  late Ticker _ticker;
  PanningFrictionSimulation? _frictionSimulation;

  @override
  void initState() {
    super.initState();
    _panAndScaleVelocityTracker = DeprecatedPanAndScaleVelocityTracker(clock: widget.clock);
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
    _panAndScaleFocalPoint = details.localFocalPoint;
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
        .finer("New origin: ${widget.controller.origin}, scale: ${widget.controller.scale}");
  }

  void _lockPanningAxisIfDesired(Offset translation, int pointerCount) {
    if (_hasChosenWhetherToLock) {
      // We've already made our locking decision. Fizzle.
      return;
    }

    if (translation.distance < 0.000001) {
      // This means a distance of zero. We can't make a decision with zero translation.
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
    if (((2 / 6) * pi < movementAnglePositive) && (movementAnglePositive < (4 / 6) * pi)) {
      PageListViewportLogs.pagesListGestures.finer("Locking panning into vertical-only movement.");
      _isLockedVertical = true;
    } else if (movementAnglePositive < (1 / 6) * pi || movementAnglePositive > (5 / 6) * pi) {
      PageListViewportLogs.pagesListGestures.finer("Locking panning into horizontal-only movement.");
      _isLockedHorizontal = true;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    PageListViewportLogs.pagesListGestures.finer("onScaleEnd()");
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

  Duration? lastDuration;

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

class DeprecatedPanAndScaleVelocityTracker {
  static double kViewportMinFlingVelocity = 600;
  static double kViewportMinFlingDistance = 60;

  DeprecatedPanAndScaleVelocityTracker({
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
  Offset _startPosition = Offset.zero;
  Offset _lastFocalPosition = Offset.zero;

  void onScaleStart(ScaleStartDetails details) {
    PageListViewportLogs.pagesListGestures.fine(
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
    _startPosition = details.localFocalPoint;
  }

  void onScaleUpdate(Offset localFocalPoint, int pointerCount) {
    PageListViewportLogs.pagesListGestures.fine("Scale update: $localFocalPoint");

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
      _previousGesturePointerCount = pointerCount;
      _launchVelocity = Offset.zero;

      _isPossibleGestureContinuation = false;
    }

    _lastFocalPosition = localFocalPoint;
  }

  void onScaleEnd(Offset velocity, int pointerCount) {
    final gestureDuration = Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);
    PageListViewportLogs.pagesListGestures.fine("onScaleEnd() - gesture duration: ${gestureDuration.inMilliseconds}");

    _previousGestureEndTimeInMillis = _clock.millis;
    _previousPointerCount = pointerCount;
    _currentGestureStartAction = null;
    _currentGestureStartTimeInMillis = null;

    if (_isPossibleGestureContinuation) {
      PageListViewportLogs.pagesListGestures.fine(" - this gesture is a continuation of a previous gesture.");
      if (pointerCount > 0) {
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

    final translationDistance = (_lastFocalPosition - _startPosition).distance;
    if (translationDistance > kViewportMinFlingDistance && velocity.distance < kViewportMinFlingVelocity) {
      // The user was readjusting the viewport by dragging it to the
      // new position.
      return;
    }

    if (pointerCount > 0) {
      PageListViewportLogs.pagesListGestures
          .fine(" - the user removed a finger, but is still interacting. Storing velocity for later.");
      PageListViewportLogs.pagesListGestures
          .fine(" - stored velocity: $_launchVelocity, magnitude: ${_launchVelocity.distance}");
      return;
    }

    _launchVelocity = velocity;
    PageListViewportLogs.pagesListGestures
        .fine(" - the user has completely stopped interacting. Launch velocity is: $_launchVelocity");
  }

  Duration get _timeSinceStartOfGesture => Duration(milliseconds: _clock.millis - _currentGestureStartTimeInMillis!);

  Duration? get _timeSinceLastGesture => _previousGestureEndTimeInMillis != null
      ? Duration(milliseconds: _clock.millis - _previousGestureEndTimeInMillis!)
      : null;
}

class PanningFrictionSimulation {
  static const kVerticalDrag = 0.095;
  static const kHorizontalDrag = 0.0425;

  PanningFrictionSimulation({
    required Offset position,
    required Offset velocity,
  })  : _position = position,
        _velocity = velocity {
    // Clamping bounds determines how long the simulation will run. Larger numbers slide for longer,
    // smaller numbers end more quickly.
    _xSimulation = ClampedSimulation(
      FrictionSimulation(
        kHorizontalDrag,
        _position.dx,
        _velocity.dx,
        // Horizontal friction simulation uses the default constantDeceleration.
        //
        // constantDeceleration impacts how smoothly the simulation comes to a stop
        // near the end (when it smoothly slides to zero).
      ),
      dxMin: -3000,
      dxMax: 3000,
    );
    _ySimulation = ClampedSimulation(
      FrictionSimulation(
        kVerticalDrag,
        _position.dy,
        _velocity.dy,
        // Vertical friction is intentionally different from horizontal friction,
        // based on empirical results.
        //
        // constantDeceleration impacts how smoothly the simulation comes to a stop
        // near the end (when it smoothly slides to zero).
        constantDeceleration: 2.35,
      ),
      dxMin: -2000, // Scroll up more slowly than scrolling down. A config found in some other scrolling systems.
      dxMax: 3000,
    );
  }

  final Offset _position;
  final Offset _velocity;
  late final ClampedSimulation _xSimulation;
  late final ClampedSimulation _ySimulation;

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
