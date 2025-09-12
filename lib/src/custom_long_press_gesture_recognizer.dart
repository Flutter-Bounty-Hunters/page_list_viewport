import 'package:flutter/gestures.dart';

const Duration _kLongPressTimeout = Duration(milliseconds: 250);

const double _kTouchSlop = 5.0;

class CustomLongPressGestureRecognizer extends LongPressGestureRecognizer {
  CustomLongPressGestureRecognizer({
    Duration? duration,
    super.postAcceptSlopTolerance,
    super.supportedDevices,
    super.debugOwner,
    AllowedButtonsFilter? allowedButtonsFilter,
  }) : super(
          duration: duration ?? _kLongPressTimeout,
          allowedButtonsFilter: allowedButtonsFilter,
        );

  @override
  // TODO: implement preAcceptSlopTolerance
  double? get preAcceptSlopTolerance => _kTouchSlop;
}
