import 'package:flutter/material.dart';

void main() {
  runApp(
    const MaterialApp(
      home: _InteractiveViewerDemo(),
    ),
  );
}

class _InteractiveViewerDemo extends StatefulWidget {
  const _InteractiveViewerDemo({super.key});

  @override
  State<_InteractiveViewerDemo> createState() => _InteractiveViewerDemoState();
}

class _InteractiveViewerDemoState extends State<_InteractiveViewerDemo> with TickerProviderStateMixin {
  late final TransformationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
  }

  final _verticalAnimationDistance = 800;
  AnimationController? _verticalPanningAnimation;
  double? _previousFrameVerticalOffset;
  void _toggleVerticalPanningAnimation() {
    if (_verticalPanningAnimation == null) {
      // Start the animation
      _previousFrameVerticalOffset = 0;
      _verticalPanningAnimation = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )
        ..addListener(() {
          final offsetAtTime =
              _verticalAnimationDistance * Curves.easeInOut.transform(_verticalPanningAnimation!.value);
          _controller.value.translate(0.0, _previousFrameVerticalOffset! - offsetAtTime);
          _controller.notifyListeners();
          _previousFrameVerticalOffset = offsetAtTime;
        })
        ..addStatusListener((status) {
          switch (status) {
            case AnimationStatus.dismissed:
              _verticalPanningAnimation!.forward();
              break;
            case AnimationStatus.completed:
              _verticalPanningAnimation!.reverse();
              break;
            case AnimationStatus.forward:
            case AnimationStatus.reverse:
              // TODO: Handle this case.
              break;
          }
        })
        ..forward();
    } else {
      // Stop the animation
      _verticalPanningAnimation!.dispose();
      _verticalPanningAnimation = null;
    }
  }

  final _horizontalAnimationDistance = 400;
  AnimationController? _horizontalPanningAnimation;
  double? _previousFrameHorizontalOffset;
  void _toggleHorizontalPanningAnimation() {
    if (_horizontalPanningAnimation == null) {
      // Start the animation
      _previousFrameHorizontalOffset = 0;
      _horizontalPanningAnimation = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )
        ..addListener(() {
          final offsetAtTime =
              _horizontalAnimationDistance * Curves.easeInOut.transform(_horizontalPanningAnimation!.value);
          _controller.value.translate(_previousFrameHorizontalOffset! - offsetAtTime, 0);
          _controller.notifyListeners();
          _previousFrameHorizontalOffset = offsetAtTime;
        })
        ..addStatusListener((status) {
          switch (status) {
            case AnimationStatus.dismissed:
              _horizontalPanningAnimation!.forward();
              break;
            case AnimationStatus.completed:
              _horizontalPanningAnimation!.reverse();
              break;
            case AnimationStatus.forward:
            case AnimationStatus.reverse:
              // TODO: Handle this case.
              break;
          }
        })
        ..forward();
    } else {
      // Stop the animation
      _horizontalPanningAnimation!.dispose();
      _horizontalPanningAnimation = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: InteractiveViewer(
        transformationController: _controller,
        constrained: false,
        alignment: Alignment.center,
        child: _buildImageGrid(),
      ),
      floatingActionButton: _buildAnimationButtons(),
    );
  }

  Widget _buildImageGrid() {
    return Column(
      children: [
        _buildImageRow(),
        _buildImageRow(),
        _buildImageRow(),
      ],
    );
  }

  Widget _buildImageRow() {
    return Row(
      children: [
        _buildImage(),
        _buildImage(),
        _buildImage(),
      ],
    );
  }

  Widget _buildImage() {
    return Image.asset(
      "assets/image-4_small.jpeg",
    );
  }

  Widget _buildAnimationButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          onPressed: _toggleHorizontalPanningAnimation,
          child: const Icon(Icons.compare_arrows),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          onPressed: _toggleVerticalPanningAnimation,
          child: const Icon(Icons.arrow_downward_sharp),
        ),
      ],
    );
  }
}
