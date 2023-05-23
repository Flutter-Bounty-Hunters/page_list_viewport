import 'package:flutter/material.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  runApp(
    MaterialApp(
      home: _MinimalViewportDemo(),
    ),
  );
}

class _MinimalViewportDemo extends StatefulWidget {
  const _MinimalViewportDemo({Key? key}) : super(key: key);

  @override
  State<_MinimalViewportDemo> createState() => _MinimalViewportDemoState();
}

class _MinimalViewportDemoState extends State<_MinimalViewportDemo> with TickerProviderStateMixin {
  late final PageListViewportController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageListViewportController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageListViewportGestures(
        controller: _controller,
        child: PageListViewport(
          controller: _controller,
          pageCount: 10,
          naturalPageSize: const Size(8.5, 11) * 72,
          builder: (context, index) {
            return DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.grey),
              ),
            );
          },
        ),
      ),
    );
  }
}
