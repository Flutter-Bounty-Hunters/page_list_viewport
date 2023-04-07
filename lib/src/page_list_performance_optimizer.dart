import 'dart:async';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'logging.dart';
import 'page_list_viewport.dart';

@immutable
class PageListPerformanceOptimizer extends StatefulWidget {
  const PageListPerformanceOptimizer({
    super.key,
    required this.controller,
    this.enabled = true,
    required this.child,
  });

  final PageListViewportController controller;
  final bool enabled;
  final Widget child;

  @override
  State<PageListPerformanceOptimizer> createState() => _PageListPerformanceOptimizerState();
}

class _PageListPerformanceOptimizerState extends State<PageListPerformanceOptimizer> {
  Offset _lastOrigin = Offset.zero;
  bool _optimizing = false;
  Timer? _cancelTimer;

  @override
  void initState() {
    super.initState();
    _lastOrigin = widget.controller.origin;
    widget.controller.addListener(_onControllerUpdated);
  }

  @override
  void didUpdateWidget(covariant PageListPerformanceOptimizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_onControllerUpdated);
      _lastOrigin = widget.controller.origin;
      widget.controller.addListener(_onControllerUpdated);
    }

    if (!widget.enabled) {
      _stopOptimizing();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdated);
    _cancelTimer?.cancel();
    _stopOptimizing();
    super.dispose();
  }

  void _onControllerUpdated() {
    final newOrigin = widget.controller.origin;
    if (newOrigin != _lastOrigin) {
      _lastOrigin = newOrigin;
      _startOptimizing();
    }
  }

  void _startOptimizing() {
    if (!widget.enabled) {
      return;
    }

    if (!_optimizing) {
      _optimizing = true;
      PageListViewportLogs.pagesListOptimizer.info('Entering GC "Low Latency Mode"');
      SchedulerBinding.instance.requestPerformanceMode(DartPerformanceMode.latency);
    }
    _cancelTimer?.cancel();
    _cancelTimer = Timer(const Duration(seconds: 3), _stopOptimizing);
  }

  void _stopOptimizing() {
    if (_optimizing) {
      _optimizing = false;
      PageListViewportLogs.pagesListOptimizer.info('Exiting GC "Low Latency Mode" back to "Balanced Mode".');
      SchedulerBinding.instance.requestPerformanceMode(DartPerformanceMode.balanced);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
