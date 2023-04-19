import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:page_list_viewport/page_list_viewport.dart';

void main() {
  PageListViewportLogs.initLoggers(Level.ALL, {
    // PageListViewportLogs.pagesList,
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Page List Viewport Demo',
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
  });

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with SingleTickerProviderStateMixin {
  late final PageListViewportController _controller;
  final _layerLink = LayerLink();

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
      body: Stack(
        children: [
          PageListViewportGestures(
            controller: _controller,
            child: PageListViewport(
              controller: _controller,
              pageCount: 1,
              naturalPageSize: const Size(8.5, 11) * 72 * MediaQuery.of(context).devicePixelRatio,
              // naturalPageSize: const Size(11, 8.5) * 72 * MediaQuery.of(context).devicePixelRatio,
              builder: (BuildContext context, int pageIndex) {
                return Stack(
                  children: [
                    Container(
                      width: double.infinity,
                      height: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.red, Colors.blue],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
                    Center(
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, child) {
                          return CompositedTransformTarget(
                            link: _layerLink,
                            child: Container(
                              width: 50 * _controller.scale,
                              height: 50 * _controller.scale,
                              color: Colors.purpleAccent,
                            ),
                          );
                        },
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, child) {
                          return Container(
                            width: 25 * _controller.scale,
                            height: 25 * _controller.scale,
                            color: Colors.greenAccent,
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            child: Container(
              width: 25,
              height: 25,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.yellow,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
