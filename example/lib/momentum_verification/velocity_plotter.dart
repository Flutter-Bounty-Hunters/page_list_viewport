import 'package:flutter/material.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

class VelocityPlotter extends StatefulWidget {
  const VelocityPlotter({
    super.key,
    required this.controller,
    required this.max,
  });

  final PageListViewportController controller;
  final Offset max;

  @override
  State<VelocityPlotter> createState() => _VelocityPlotterState();
}

class _VelocityPlotterState extends State<VelocityPlotter> {
  // Lists of points that we collect so that we can print out all the points and play
  // them back for bug reproductions.
  final _velocityPointPlayback = <Offset>[];
  final _accelerationPointPlayback = <Offset>[];

  final _velocityLogicalPoint = <Offset>[];
  final _velocityVisiblePoints = <Offset>[];
  final _accelerationLogicalPoints = <Offset>[];
  final _accelerationVisiblePoints = <Offset>[];
  final _sampleCount = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant VelocityPlotter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    super.dispose();
    widget.controller.removeListener(_onControllerChanged);
  }

  Offset? _lastVelocity;
  final _stopwatch = Stopwatch();

  void _onControllerChanged() {
    if (_stopwatch.isRunning == false) {
      _stopwatch.start();
    }
    if (_stopwatch.elapsedMilliseconds == 0) {
      // No time has passed. We don't want to divide things by zero.
      return;
    }
    final velocity = widget.controller.velocity;
    _velocityLogicalPoint.add(velocity);
    _velocityPointPlayback.add(velocity);
    if (_lastVelocity != null) {
      // final acceleration = (velocity - _lastVelocity!) / (_stopwatch.elapsedMilliseconds / 1000);
      final acceleration = widget.controller.acceleration * 100;
      _accelerationLogicalPoints.add(acceleration);
      _accelerationPointPlayback.add(acceleration);
    }

    // Increment sample count so that we cause a repaint in the CustomPainter
    _sampleCount.value = _velocityLogicalPoint.length;

    _lastVelocity = velocity;
    _stopwatch.reset();
  }

  void _clearPlot() {
    _velocityLogicalPoint.clear();
    _velocityVisiblePoints.clear();
    _accelerationLogicalPoints.clear();
    _accelerationVisiblePoints.clear();
    _sampleCount.value = 0;
  }

  // ignore: unused_element
  void _printPointPlayback() {
    print("Velocity points:");
    print("const velocityPoints = [");
    for (final point in _velocityPointPlayback) {
      print("  Offset(${point.dx}, ${point.dy}),");
    }
    print("];");

    print("");
    print("");

    print("Acceleration points:");
    print("const accelerationPoints = [");
    for (final point in _accelerationPointPlayback) {
      print("  Offset(${point.dx}, ${point.dy}),");
    }
    print("];");
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: _clearPlot,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _PlotterPainter(
                logicalPoints: _accelerationLogicalPoints,
                visiblePoints: _accelerationVisiblePoints,
                max: widget.max,
                color: Colors.red.withOpacity(0.5),
                repaint: _sampleCount,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _PlotterPainter(
                logicalPoints: _velocityLogicalPoint,
                visiblePoints: _velocityVisiblePoints,
                max: widget.max,
                color: Colors.greenAccent,
                repaint: _sampleCount,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlotterPainter extends CustomPainter {
  static const _maxSampleDisplayCount = 300;

  _PlotterPainter({
    required this.max,
    required this.logicalPoints,
    required this.visiblePoints,
    required this.color,
    super.repaint,
  }) {
    pointPainter.color = color;
    linePaint
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
  }

  final Offset max;
  final List<Offset> logicalPoints;
  final List<Offset> visiblePoints;
  final Color color;

  final pointPainter = Paint();
  final linePaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    _convertLogicalPointsToPlotPoints(size);

    canvas.clipRect(Offset.zero & size);

    final horizontalStepSize = size.width / _maxSampleDisplayCount;
    for (var i = 0; i < visiblePoints.length; i += 1) {
      final plotPoint = visiblePoints[i].translate(i * horizontalStepSize, 0);
      final previousPlotPoint = i > 0 ? visiblePoints[i - 1].translate((i - 1) * horizontalStepSize, 0) : null;

      // Draw a line connecting previous and current plot point.
      if (previousPlotPoint != null) {
        canvas.drawLine(previousPlotPoint, plotPoint, linePaint);
      }

      // Draw the current plot point.
      canvas.drawCircle(plotPoint, 2, pointPainter);
    }
  }

  void _convertLogicalPointsToPlotPoints(Size size) {
    final scaleY = size.height / (max.dy * 2);

    for (var i = 0; i < logicalPoints.length; i += 1) {
      final logicalPoint = logicalPoints[i];

      final plotPoint = Offset(
        0,
        size.height - ((logicalPoint.dy + max.dy) * scaleY),
      );

      visiblePoints.add(plotPoint);
    }

    if (visiblePoints.length > _maxSampleDisplayCount) {
      visiblePoints.removeRange(0, visiblePoints.length - _maxSampleDisplayCount);
    }

    logicalPoints.clear();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
